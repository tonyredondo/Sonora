//! Immutable copies of user-confirmed tags. This is personal data, not an expiring cache.

use crate::config::MetadataConfig;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    sync::{Arc, Mutex},
};
use uuid::Uuid;

pub const MAX_RECORD_BYTES: usize = 22_000_000;

#[derive(Debug, thiserror::Error)]
pub enum ArchiveError {
    #[error("invalid confirmed metadata")]
    Invalid,
    #[error("this copy already exists with different content")]
    Conflict,
    #[error("confirmed metadata storage is full; existing copies were kept")]
    Full,
    #[error("confirmed metadata storage is unavailable")]
    Storage,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MetadataRecord {
    pub id: Uuid,
    pub audio_id: String,
    pub confirmed_at: u64,
    pub values: BTreeMap<String, String>,
    pub artwork: Option<String>,
}
impl MetadataRecord {
    pub fn validate(&self) -> Result<(), ArchiveError> {
        validate_audio_id(&self.audio_id)?;
        if self.confirmed_at > 4_102_444_800_000 || self.values.len() > 14 {
            return Err(ArchiveError::Invalid);
        }
        for (field, value) in &self.values {
            let numeric = matches!(
                field.as_str(),
                "trackNumber" | "trackTotal" | "discNumber" | "discTotal"
            );
            if !matches!(
                field.as_str(),
                "title"
                    | "artist"
                    | "album"
                    | "albumArtist"
                    | "composer"
                    | "genre"
                    | "date"
                    | "trackNumber"
                    | "trackTotal"
                    | "discNumber"
                    | "discTotal"
                    | "comment"
                    | "lyrics"
            ) || value.contains('\0')
                || value.len() > if field == "lyrics" { 1_000_000 } else { 16_384 }
                || (numeric
                    && !value.is_empty()
                    && value.parse::<u16>().ok().is_none_or(|n| n == 0))
            {
                return Err(ArchiveError::Invalid);
            }
        }
        // Artwork is transported as JSON's base64 Data representation. Do not persist
        // unbounded or malformed encodings even when the caller is authenticated.
        if let Some(art) = &self.artwork {
            let padding = art.len() - art.trim_end_matches('=').len();
            let bytes = art.len() / 4 * 3 - padding.min(art.len() / 4 * 3);
            if art.is_empty()
                || art.len() % 4 != 0
                || padding > 2
                || bytes > 10_000_000
                || !art[..art.len() - padding]
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
            {
                return Err(ArchiveError::Invalid);
            }
        }
        Ok(())
    }
    fn summary(&self) -> RecordSummary {
        let text = |key: &str| {
            self.values
                .get(key)
                .map(|v| v.chars().take(200).collect())
                .unwrap_or_default()
        };
        RecordSummary {
            id: self.id,
            title: text("title"),
            artist: text("artist"),
            album: text("album"),
            album_artist: text("albumArtist"),
            confirmed_at: self.confirmed_at,
            has_artwork: self.artwork.is_some(),
            has_lyrics: self.values.get("lyrics").is_some_and(|s| !s.is_empty()),
        }
    }
}

pub fn validate_audio_id(value: &str) -> Result<(), ArchiveError> {
    let valid = value.strip_prefix("pcm64-v1:").is_some_and(|s| {
        s.len() == 64
            && s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    });
    if valid {
        Ok(())
    } else {
        Err(ArchiveError::Invalid)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RecordSummary {
    pub id: Uuid,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub confirmed_at: u64,
    pub has_artwork: bool,
    pub has_lyrics: bool,
}
#[derive(Serialize)]
pub struct RecordPage {
    pub records: Vec<RecordSummary>,
    pub next_cursor: Option<i64>,
}
struct Storage {
    connection: Mutex<Connection>,
    _lock: File,
    max_bytes: u64,
}
#[derive(Clone)]
pub struct MetadataArchive(Arc<Storage>);
impl MetadataArchive {
    pub fn open(config: &MetadataConfig) -> Result<Self, ArchiveError> {
        let fail = |_| ArchiveError::Storage;
        if let Some(parent) = config.path.parent() {
            std::fs::create_dir_all(parent).map_err(fail)?;
        }
        let open = |path: &std::path::Path| {
            let mut options = OpenOptions::new();
            options.read(true).write(true).create(true).truncate(false);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            options.open(path)
        };
        let lock = open(&config.path.with_extension("lockfile")).map_err(fail)?;
        fs2::FileExt::try_lock_exclusive(&lock).map_err(fail)?;
        drop(open(&config.path).map_err(fail)?);
        let connection = Connection::open(&config.path).map_err(|_| ArchiveError::Storage)?;
        connection
            .busy_timeout(std::time::Duration::from_secs(2))
            .map_err(|_| ArchiveError::Storage)?;
        connection.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS metadata_records (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, audio_id TEXT NOT NULL,
                body BLOB NOT NULL, summary TEXT NOT NULL, size INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS metadata_by_audio ON metadata_records(audio_id, sequence);")
            .map_err(|_| ArchiveError::Storage)?;
        Ok(Self(Arc::new(Storage {
            connection: Mutex::new(connection),
            _lock: lock,
            max_bytes: config.max_bytes,
        })))
    }
    /// Identical retries succeed. An ID can never be rebound to different audio or tags.
    pub async fn put(&self, record: MetadataRecord) -> Result<bool, ArchiveError> {
        record.validate()?;
        let body = serde_json::to_vec(&record).map_err(|_| ArchiveError::Invalid)?;
        if body.len() > MAX_RECORD_BYTES {
            return Err(ArchiveError::Invalid);
        }
        let summary =
            serde_json::to_string(&record.summary()).map_err(|_| ArchiveError::Invalid)?;
        let storage = self.0.clone();
        tokio::task::spawn_blocking(move || {
            let mut connection = storage.connection.lock().map_err(|_|ArchiveError::Storage)?;
            let tx = connection.transaction().map_err(|_|ArchiveError::Storage)?;
            let existing: Option<Vec<u8>> = tx.query_row("SELECT body FROM metadata_records WHERE id=?1", [record.id.to_string()], |r|r.get(0)).optional().map_err(|_|ArchiveError::Storage)?;
            if let Some(existing) = existing {
                return if existing == body { Ok(false) } else { Err(ArchiveError::Conflict) };
            }
            let used:u64 = tx.query_row("SELECT COALESCE(SUM(size),0) FROM metadata_records", [], |r|r.get(0)).map_err(|_|ArchiveError::Storage)?;
            if used.saturating_add(body.len() as u64 + summary.len() as u64) > storage.max_bytes { return Err(ArchiveError::Full); }
            tx.execute("INSERT INTO metadata_records(id,audio_id,body,summary,size) VALUES(?1,?2,?3,?4,?5)", params![record.id.to_string(),record.audio_id,body,summary,body.len()+summary.len()]).map_err(|_|ArchiveError::Storage)?;
            tx.commit().map_err(|_|ArchiveError::Storage)?;
            Ok(true)
        }).await.map_err(|_|ArchiveError::Storage)?
    }
    pub async fn get(&self, id: Uuid) -> Result<Option<MetadataRecord>, ArchiveError> {
        let storage = self.0.clone();
        tokio::task::spawn_blocking(move || {
            let connection = storage
                .connection
                .lock()
                .map_err(|_| ArchiveError::Storage)?;
            let body: Option<Vec<u8>> = connection
                .query_row(
                    "SELECT body FROM metadata_records WHERE id=?1",
                    [id.to_string()],
                    |r| r.get(0),
                )
                .optional()
                .map_err(|_| ArchiveError::Storage)?;
            body.map(|b| serde_json::from_slice(&b).map_err(|_| ArchiveError::Storage))
                .transpose()
        })
        .await
        .map_err(|_| ArchiveError::Storage)?
    }
    pub async fn list(
        &self,
        audio_id: String,
        before: Option<i64>,
    ) -> Result<RecordPage, ArchiveError> {
        validate_audio_id(&audio_id)?;
        if before.is_some_and(|v| v <= 0) {
            return Err(ArchiveError::Invalid);
        }
        let storage = self.0.clone();
        tokio::task::spawn_blocking(move || {
            let connection = storage.connection.lock().map_err(|_|ArchiveError::Storage)?;
            let mut statement = connection.prepare("SELECT sequence,summary FROM metadata_records WHERE audio_id=?1 AND sequence < ?2 ORDER BY sequence DESC LIMIT 51").map_err(|_|ArchiveError::Storage)?;
            let rows = statement.query_map(params![audio_id, before.unwrap_or(i64::MAX)], |r|Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?))).map_err(|_|ArchiveError::Storage)?;
            let rows = rows.collect::<Result<Vec<_>,_>>().map_err(|_|ArchiveError::Storage)?;
            let next_cursor = (rows.len() > 50).then(||rows[49].0);
            let records = rows.into_iter().take(50).map(|(_,s)|serde_json::from_str(&s).map_err(|_|ArchiveError::Storage)).collect::<Result<_,_>>()?;
            Ok(RecordPage { records, next_cursor })
        }).await.map_err(|_|ArchiveError::Storage)?
    }
}
