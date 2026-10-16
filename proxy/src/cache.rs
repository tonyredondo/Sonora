//! Persistent HTTP response cache.

use bytes::Bytes;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::{
    fs::{File, OpenOptions},
    path::Path,
    sync::{Arc, Mutex},
};

#[derive(Debug, thiserror::Error)]
pub enum CacheError {
    #[error("cache could not be opened or is already in use")]
    Open,
    #[error("cache read or write failed")]
    Storage,
}

/// Only representation and caching headers are persisted; authentication headers never are.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ResponseHeaders {
    pub content_type: Option<String>,
    pub etag: Option<String>,
    pub last_modified: Option<String>,
    pub cache_control: Option<String>,
    pub expires: Option<String>,
    pub date: Option<String>,
    pub vary: Option<String>,
    pub age: Option<String>,
}

#[derive(Clone, Debug)]
pub struct CacheEntry {
    pub status: u16,
    pub headers: ResponseHeaders,
    pub body: Bytes,
    pub stored_at: u64,
    pub expires_at: u64,
}
impl CacheEntry {
    pub fn is_fresh(&self, now: u64) -> bool {
        now < self.expires_at
    }
}

struct Storage {
    connection: Mutex<Connection>,
    _lock: File,
    max_bytes: u64,
    max_entries: usize,
}

/// SQLite operations run on the blocking pool. One process owns a cache file at a time.
#[derive(Clone)]
pub struct Cache(Arc<Storage>);

pub(crate) struct WeakCache(std::sync::Weak<Storage>);
impl WeakCache {
    pub fn upgrade(&self) -> Option<Cache> {
        self.0.upgrade().map(Cache)
    }
}

impl Cache {
    pub(crate) fn downgrade(&self) -> WeakCache {
        WeakCache(Arc::downgrade(&self.0))
    }
    pub fn open(path: &Path, max_bytes: u64, max_entries: usize) -> Result<Self, CacheError> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent).map_err(|_| CacheError::Open)?;
        }
        let options = || {
            let mut o = OpenOptions::new();
            o.read(true).write(true).create(true).truncate(false);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                o.mode(0o600);
            }
            o
        };
        let lock = options()
            .open(path.with_extension("lockfile"))
            .map_err(|_| CacheError::Open)?;
        fs2::FileExt::try_lock_exclusive(&lock).map_err(|_| CacheError::Open)?;
        let db_file = options().open(path).map_err(|_| CacheError::Open)?;
        drop(db_file);
        let connection = Connection::open(path).map_err(|_| CacheError::Open)?;
        connection
            .busy_timeout(std::time::Duration::from_secs(2))
            .map_err(|_| CacheError::Open)?;
        connection
            .execute_batch(
                "PRAGMA auto_vacuum=INCREMENTAL; PRAGMA journal_mode=DELETE;
            CREATE TABLE IF NOT EXISTS responses (
                key TEXT PRIMARY KEY, status INTEGER NOT NULL, headers TEXT NOT NULL,
                body BLOB NOT NULL, stored_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
                size INTEGER NOT NULL, used INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS responses_used ON responses(used);",
            )
            .map_err(|_| CacheError::Open)?;
        enforce_limits(&connection, max_bytes, max_entries).map_err(|_| CacheError::Open)?;
        connection
            .execute_batch("PRAGMA incremental_vacuum;")
            .map_err(|_| CacheError::Open)?;
        Ok(Self(Arc::new(Storage {
            connection: Mutex::new(connection),
            _lock: lock,
            max_bytes,
            max_entries,
        })))
    }
    pub async fn get(&self, key: &str) -> Result<Option<CacheEntry>, CacheError> {
        let storage = self.0.clone();
        let key = key.to_owned();
        tokio::task::spawn_blocking(move || {
            let connection = storage.connection.lock().map_err(|_|CacheError::Storage)?;
            let row = connection.query_row("SELECT status, headers, body, stored_at, expires_at FROM responses WHERE key=?1", [&key], |row| {
                Ok((row.get::<_, u16>(0)?, row.get::<_, String>(1)?, row.get::<_, Vec<u8>>(2)?, row.get::<_, u64>(3)?, row.get::<_, u64>(4)?))
            }).optional().map_err(|_|CacheError::Storage)?;
            let Some((status, headers, body, stored_at, expires_at)) = row else { return Ok(None); };
            connection.execute("UPDATE responses SET used=(SELECT COALESCE(MAX(used),0)+1 FROM responses) WHERE key=?1", [&key]).map_err(|_|CacheError::Storage)?;
            Ok(Some(CacheEntry { status, headers: serde_json::from_str(&headers).map_err(|_|CacheError::Storage)?, body: Bytes::from(body), stored_at, expires_at }))
        }).await.map_err(|_|CacheError::Storage)?
    }
    pub async fn put(&self, key: &str, entry: CacheEntry) -> Result<(), CacheError> {
        let storage = self.0.clone();
        let key = key.to_owned();
        tokio::task::spawn_blocking(move || {
            let mut connection = storage.connection.lock().map_err(|_|CacheError::Storage)?;
            let transaction = connection.transaction().map_err(|_|CacheError::Storage)?;
            transaction.execute("DELETE FROM responses WHERE key=?1", [&key]).map_err(|_|CacheError::Storage)?;
            if entry.body.len() as u64 <= storage.max_bytes {
                let headers = serde_json::to_string(&entry.headers).map_err(|_|CacheError::Storage)?;
                transaction.execute("INSERT INTO responses VALUES (?1,?2,?3,?4,?5,?6,?7,(SELECT COALESCE(MAX(used),0)+1 FROM responses))", params![key,entry.status,headers,entry.body.as_ref(),entry.stored_at,entry.expires_at,entry.body.len() as u64]).map_err(|_|CacheError::Storage)?;
            }
            enforce_limits(&transaction,storage.max_bytes,storage.max_entries).map_err(|_|CacheError::Storage)?;
            transaction.commit().map_err(|_|CacheError::Storage)?;
            // Reclaim pages left by eviction instead of letting an old large cache pin disk space.
            connection.execute_batch("PRAGMA incremental_vacuum;").map_err(|_|CacheError::Storage)?;
            Ok(())
        }).await.map_err(|_|CacheError::Storage)?
    }
    pub async fn remove(&self, key: &str) -> Result<(), CacheError> {
        let storage = self.0.clone();
        let key = key.to_owned();
        tokio::task::spawn_blocking(move || {
            let connection = storage.connection.lock().map_err(|_| CacheError::Storage)?;
            connection
                .execute("DELETE FROM responses WHERE key=?1", [&key])
                .map_err(|_| CacheError::Storage)?;
            Ok(())
        })
        .await
        .map_err(|_| CacheError::Storage)?
    }
}

fn enforce_limits(
    connection: &Connection,
    max_bytes: u64,
    max_entries: usize,
) -> rusqlite::Result<()> {
    loop {
        let (bytes, count): (u64, usize) = connection.query_row(
            "SELECT COALESCE(SUM(size),0), COUNT(*) FROM responses",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        if bytes <= max_bytes && count <= max_entries {
            return Ok(());
        }
        connection.execute(
            "DELETE FROM responses WHERE key=(SELECT key FROM responses ORDER BY used LIMIT 1)",
            [],
        )?;
    }
}

pub(crate) fn unix_time() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
