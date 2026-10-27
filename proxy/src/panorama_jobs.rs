//! Durable inputs and results are retained until the client acknowledges its local copy.
use crate::{
    artwork_jobs::{Snapshot, State},
    cache::unix_time,
    generated_artwork::MAX_IMAGE_BYTES,
    interpretation::{InterpretationError as E, InterpretationService},
    panoramic_artwork::{Aspect, Source},
};
use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use bytes::Bytes;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs::{File, OpenOptions},
    path::Path,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::{Mutex as AsyncMutex, Semaphore};

#[derive(Debug)]
pub enum Error {
    Service(E),
    Invalid,
    Missing,
    NotReady,
    Full,
    Store,
}
impl From<E> for Error {
    fn from(value: E) -> Self {
        Self::Service(value)
    }
}
impl IntoResponse for Error {
    fn into_response(self) -> Response {
        let (status, code) = match self {
            Self::Service(error) => return error.into_response(),
            Self::Invalid => (StatusCode::BAD_REQUEST, "artwork_expansion_input"),
            Self::Missing => (StatusCode::NOT_FOUND, "artwork_expansion_not_found"),
            Self::NotReady => (StatusCode::CONFLICT, "artwork_expansion_not_ready"),
            Self::Full => (
                StatusCode::TOO_MANY_REQUESTS,
                "artwork_expansion_storage_full",
            ),
            Self::Store => (StatusCode::SERVICE_UNAVAILABLE, "artwork_expansion_store"),
        };
        (status, Json(serde_json::json!({"error":code}))).into_response()
    }
}
#[derive(Clone, Serialize, Deserialize)]
struct Record {
    snapshot: Snapshot,
    aspect: Aspect,
    source_sha: String,
    attempts: u8,
    retry_at: Option<u64>,
    result_sha: Option<String>,
    acknowledged: bool,
}
struct Storage {
    db: Mutex<Connection>,
    _lock: File,
    max_bytes: u64,
    limit: usize,
}
#[derive(Clone)]
struct Store(Arc<Storage>);
impl Store {
    fn open(path: &Path, max_bytes: u64, limit: usize) -> Result<Self, Error> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|_| Error::Store)?;
        }
        let open = |path: &Path| {
            let mut options = OpenOptions::new();
            options.read(true).write(true).create(true).truncate(false);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            options.open(path).map_err(|_| Error::Store)
        };
        let lock = open(&path.with_extension("lockfile"))?;
        fs2::FileExt::try_lock_exclusive(&lock).map_err(|_| Error::Store)?;
        drop(open(path)?);
        let db = Connection::open(path).map_err(|_| Error::Store)?;
        db.busy_timeout(Duration::from_secs(2))
            .map_err(|_| Error::Store)?;
        db.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA auto_vacuum=INCREMENTAL;
            CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,body TEXT NOT NULL,source BLOB,image BLOB,reserved INTEGER NOT NULL,acknowledged INTEGER NOT NULL,created INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS jobs_acknowledged ON jobs(acknowledged,created);").map_err(|_|Error::Store)?;
        Ok(Self(Arc::new(Storage {
            db: Mutex::new(db),
            _lock: lock,
            max_bytes,
            limit,
        })))
    }
    async fn execute<T: Send + 'static>(
        &self,
        action: impl FnOnce(&mut Connection, u64, usize) -> Result<T, Error> + Send + 'static,
    ) -> Result<T, Error> {
        let storage = self.0.clone();
        tokio::task::spawn_blocking(move || {
            let mut db = storage.db.lock().map_err(|_| Error::Store)?;
            action(&mut db, storage.max_bytes, storage.limit)
        })
        .await
        .map_err(|_| Error::Store)?
    }
    async fn read(&self, id: &str) -> Result<Record, Error> {
        let id = id.to_owned();
        self.execute(move |db, _, _| read(db, &id)?.ok_or(Error::Missing))
            .await
    }
    async fn pending(&self) -> Result<Vec<Record>, Error> {
        self.execute(|db, _, _| {
            let mut query = db
                .prepare("SELECT id FROM jobs WHERE acknowledged=0")
                .map_err(|_| Error::Store)?;
            let ids = query
                .query_map([], |row| row.get::<_, String>(0))
                .map_err(|_| Error::Store)?;
            let mut pending = Vec::new();
            for id in ids {
                if let Some(record) = read(db, &id.map_err(|_| Error::Store)?)? {
                    if matches!(record.snapshot.state, State::Queued | State::Running) {
                        pending.push(record);
                    }
                }
            }
            Ok(pending)
        })
        .await
    }
    async fn admit(&self, source: Source, retry_failed: bool) -> Result<Record, Error> {
        self.execute(move |db,max_bytes,limit| {
            let id=source.key();
            let transaction=db.transaction().map_err(|_|Error::Store)?;
            if let Some(mut old)=read(&transaction,&id)? {
                if retry_failed && old.snapshot.state==State::Failed {
                    old.snapshot.state=State::Queued;old.snapshot.error=None;old.attempts=0;old.retry_at=None;
                    transaction.execute("UPDATE jobs SET body=?2 WHERE id=?1",params![id,serialize(&old)?]).map_err(|_|Error::Store)?;
                }
                transaction.commit().map_err(|_|Error::Store)?;return Ok(old);
            }
            let reserve=(source.bytes.len()+MAX_IMAGE_BYTES+4096) as u64;
            if reserve>max_bytes { return Err(Error::Full); }
            loop {
                let (used,count):(u64,usize)=transaction.query_row("SELECT COALESCE(SUM(reserved),0),COUNT(*) FROM jobs",[],|row|Ok((row.get(0)?,row.get(1)?))).map_err(|_|Error::Store)?;
                if used.saturating_add(reserve)<=max_bytes && count<limit { break; }
                // Undelivered work and images are never candidates for cache eviction.
                if transaction.execute("DELETE FROM jobs WHERE id=(SELECT id FROM jobs WHERE acknowledged=1 ORDER BY created LIMIT 1)",[]).map_err(|_|Error::Store)?==0 { return Err(Error::Full); }
            }
            let record=Record { snapshot:Snapshot { id:id.clone(),state:State::Queued,error:None },aspect:source.aspect,source_sha:format!("{:x}",Sha256::digest(&source.bytes)),attempts:0,retry_at:None,result_sha:None,acknowledged:false };
            transaction.execute("INSERT INTO jobs VALUES (?1,?2,?3,NULL,?4,0,?5)",params![id,serialize(&record)?,source.bytes.as_ref(),reserve,unix_time()]).map_err(|_|Error::Store)?;
            transaction.commit().map_err(|_|Error::Store)?;Ok(record)
        }).await
    }
    async fn update(&self, record: Record) -> Result<(), Error> {
        self.execute(move |db, _, _| {
            db.execute(
                "UPDATE jobs SET body=?2 WHERE id=?1",
                params![record.snapshot.id, serialize(&record)?],
            )
            .map_err(|_| Error::Store)?;
            Ok(())
        })
        .await
    }
    async fn source(&self, id: &str) -> Result<Source, Error> {
        let id = id.to_owned();
        self.execute(move |db, _, _| {
            let record = read(db, &id)?.ok_or(Error::Missing)?;
            let bytes: Vec<u8> = db
                .query_row("SELECT source FROM jobs WHERE id=?1", [&id], |row| {
                    row.get(0)
                })
                .map_err(|_| Error::Store)?;
            if format!("{:x}", Sha256::digest(&bytes)) != record.source_sha {
                return Err(Error::Store);
            }
            Source::new(bytes.into(), record.aspect).map_err(|_| Error::Store)
        })
        .await
    }
    async fn start(&self, id: &str) -> Result<(), E> {
        let id = id.to_owned();
        self.execute(move |db, _, _| {
            let mut record = read(db, &id)?.ok_or(Error::Missing)?;
            if record.attempts >= 3 {
                return Err(Error::Store);
            }
            record.attempts += 1;
            record.retry_at = None;
            record.snapshot.state = State::Running;
            record.snapshot.error = None;
            db.execute(
                "UPDATE jobs SET body=?2 WHERE id=?1",
                params![id, serialize(&record)?],
            )
            .map_err(|_| Error::Store)?;
            Ok(())
        })
        .await
        .map_err(|_| E::Cache)
    }
    async fn complete(&self, id: &str, image: Bytes) -> Result<(), Error> {
        let id = id.to_owned();
        self.execute(move |db, _, _| {
            let mut record = read(db, &id)?.ok_or(Error::Missing)?;
            record.snapshot.state = State::Completed;
            record.snapshot.error = None;
            record.retry_at = None;
            record.result_sha = Some(format!("{:x}", Sha256::digest(&image)));
            db.execute(
                "UPDATE jobs SET body=?2,image=?3 WHERE id=?1",
                params![id, serialize(&record)?, image.as_ref()],
            )
            .map_err(|_| Error::Store)?;
            Ok(())
        })
        .await
    }
    async fn image(&self, id: &str) -> Result<(Bytes, String), Error> {
        let id = id.to_owned();
        self.execute(move |db, _, _| {
            let record = read(db, &id)?.ok_or(Error::Missing)?;
            if record.snapshot.state != State::Completed {
                return Err(Error::NotReady);
            }
            let bytes: Vec<u8> = db
                .query_row("SELECT image FROM jobs WHERE id=?1", [&id], |row| {
                    row.get(0)
                })
                .map_err(|_| Error::Store)?;
            let digest = format!("{:x}", Sha256::digest(&bytes));
            if record.result_sha.as_deref() != Some(&digest) {
                return Err(Error::Store);
            }
            Ok((bytes.into(), digest))
        })
        .await
    }
    async fn acknowledge(&self, id: &str, digest: &str) -> Result<(), Error> {
        let id = id.to_owned();
        let digest = digest.to_owned();
        self.execute(move |db,_,_|{
            let mut record=read(db,&id)?.ok_or(Error::Missing)?;
            if record.snapshot.state!=State::Completed || record.result_sha.as_deref()!=Some(&digest) { return Err(Error::Invalid); }
            record.acknowledged=true;
            db.execute("UPDATE jobs SET body=?2,source=NULL,reserved=length(image)+4096,acknowledged=1 WHERE id=?1",params![id,serialize(&record)?]).map_err(|_|Error::Store)?;Ok(())
        }).await
    }
}
fn read(db: &Connection, id: &str) -> Result<Option<Record>, Error> {
    let body: Option<String> = db
        .query_row("SELECT body FROM jobs WHERE id=?1", [id], |row| row.get(0))
        .optional()
        .map_err(|_| Error::Store)?;
    body.map(|body| {
        if body.len() > 4096 {
            return Err(Error::Store);
        }
        let record: Record = serde_json::from_str(&body).map_err(|_| Error::Store)?;
        if record.snapshot.id != id {
            return Err(Error::Store);
        }
        Ok(record)
    })
    .transpose()
}
fn serialize(record: &Record) -> Result<String, Error> {
    serde_json::to_string(record).map_err(|_| Error::Store)
}
fn valid_id(id: &str) -> Result<(), Error> {
    if id.len() == 64
        && id
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(())
    } else {
        Err(Error::Invalid)
    }
}

struct Inner {
    service: InterpretationService,
    store: Store,
    enabled: bool,
    admission: AsyncMutex<()>,
    active: Mutex<HashSet<String>>,
    workers: Semaphore,
    retries: [Duration; 2],
}
#[derive(Clone)]
pub struct ExpansionJobs(Arc<Inner>);
impl ExpansionJobs {
    pub fn open(
        service: InterpretationService,
        path: &Path,
        enabled: bool,
        max_bytes: u64,
        limit: usize,
    ) -> Result<Self, Error> {
        Self::open_with_delays(
            service,
            path,
            enabled,
            max_bytes,
            limit,
            [Duration::from_secs(30), Duration::from_secs(90)],
        )
    }
    fn open_with_delays(
        service: InterpretationService,
        path: &Path,
        enabled: bool,
        max_bytes: u64,
        limit: usize,
        retries: [Duration; 2],
    ) -> Result<Self, Error> {
        let jobs = Self(Arc::new(Inner {
            service,
            store: Store::open(path, max_bytes, limit)?,
            enabled,
            admission: AsyncMutex::new(()),
            active: Mutex::new(HashSet::new()),
            workers: Semaphore::new(4),
            retries,
        }));
        // Restart recovery does not depend on an iPhone/Android poll reaching the server.
        if enabled {
            let recovery = jobs.clone();
            tokio::spawn(async move {
                let Ok(records) = recovery.0.store.pending().await else {
                    return;
                };
                for record in records {
                    let _admission = recovery.0.admission.lock().await;
                    let _ = recovery.wake(&record.snapshot.id, record.snapshot.state);
                }
            });
        }
        Ok(jobs)
    }
    pub async fn create(&self, source: Source, retry_failed: bool) -> Result<Snapshot, Error> {
        let _admission = self.0.admission.lock().await;
        if !self.0.enabled {
            return match self.0.store.read(&source.key()).await {
                Ok(record) if record.snapshot.state == State::Completed => Ok(record.snapshot),
                Ok(_) | Err(Error::Missing) => Err(E::Disabled.into()),
                Err(error) => Err(error),
            };
        }
        let record = self.0.store.admit(source, retry_failed).await?;
        self.wake(&record.snapshot.id, record.snapshot.state)?;
        Ok(record.snapshot)
    }
    pub async fn snapshot(&self, id: &str) -> Result<Snapshot, Error> {
        valid_id(id)?;
        let _admission = self.0.admission.lock().await;
        let mut record = self.0.store.read(id).await?;
        if matches!(record.snapshot.state, State::Queued | State::Running)
            && !self.0.active.lock().map_err(|_| Error::Store)?.contains(id)
        {
            record.snapshot.state = State::Queued;
            if !self.0.enabled {
                record.snapshot.error = Some("codex_disabled".into());
            } else {
                self.0.store.update(record.clone()).await?;
                self.wake(id, State::Queued)?;
            }
        }
        Ok(record.snapshot)
    }
    pub async fn image(&self, id: &str) -> Result<(Bytes, String), Error> {
        valid_id(id)?;
        self.0.store.image(id).await
    }
    pub async fn acknowledge(&self, id: &str, digest: &str) -> Result<(), Error> {
        valid_id(id)?;
        valid_id(digest)?;
        self.0.store.acknowledge(id, digest).await
    }
    fn wake(&self, id: &str, state: State) -> Result<(), Error> {
        if !self.0.enabled || !matches!(state, State::Queued | State::Running) {
            return Ok(());
        }
        if !self
            .0
            .active
            .lock()
            .map_err(|_| Error::Store)?
            .insert(id.to_owned())
        {
            return Ok(());
        }
        let jobs = self.clone();
        let id = id.to_owned();
        tokio::spawn(async move {
            jobs.run(&id).await;
            if let Ok(mut active) = jobs.0.active.lock() {
                active.remove(&id);
            }
        });
        Ok(())
    }
    async fn run(&self, id: &str) {
        loop {
            let Ok(record) = self.0.store.read(id).await else {
                return;
            };
            if !matches!(record.snapshot.state, State::Queued | State::Running) {
                return;
            }
            if let Some(at) = record.retry_at {
                tokio::time::sleep(Duration::from_secs(at.saturating_sub(unix_time()))).await;
            }
            if record.attempts >= 3 {
                let mut failed = record;
                failed.snapshot.state = State::Failed;
                failed.snapshot.error = Some("codex_unavailable".into());
                failed.retry_at = None;
                let _ = self.0.store.update(failed).await;
                return;
            }
            let result = {
                let Ok(_slot) = self.0.workers.acquire().await else {
                    return;
                };
                match self.0.store.source(id).await {
                    Ok(source) => {
                        let store = self.0.store.clone();
                        let owned = id.to_owned();
                        self.0
                            .service
                            .expand_artwork(
                                &source,
                                move || async move { store.start(&owned).await },
                            )
                            .await
                    }
                    Err(_) => Err(E::Cache),
                }
            };
            match result {
                Ok(image) => {
                    if self.0.store.complete(id, image).await.is_err() {
                        if let Ok(mut failed) = self.0.store.read(id).await {
                            failed.snapshot.state = State::Failed;
                            failed.snapshot.error = Some("codex_cache_unavailable".into());
                            let _ = self.0.store.update(failed).await;
                        }
                    }
                    return;
                }
                Err(error) => {
                    let Ok(mut current) = self.0.store.read(id).await else {
                        return;
                    };
                    if matches!(
                        error,
                        E::Timeout | E::Unavailable | E::InvalidResponse | E::Busy
                    ) && current.attempts < 3
                    {
                        let delay =
                            self.0.retries[usize::from(current.attempts.saturating_sub(1)).min(1)];
                        current.snapshot.state = State::Queued;
                        current.snapshot.error = None;
                        current.retry_at = Some(unix_time() + delay.as_secs());
                        if self.0.store.update(current).await.is_err() {
                            return;
                        }
                        tokio::time::sleep(delay).await;
                    } else {
                        current.snapshot.state = State::Failed;
                        current.snapshot.error = Some(error.code().into());
                        current.retry_at = None;
                        let _ = self.0.store.update(current).await;
                        return;
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{cache::Cache, config::CodexConfig, interpretation::TestImageGenerator};
    use std::{
        io::Cursor,
        sync::atomic::{AtomicUsize, Ordering},
    };
    use tokio::sync::Notify;

    fn png(seed: u8, wide: bool) -> Bytes {
        let image = image::RgbaImage::from_pixel(
            if wide { 72 } else { 32 },
            32,
            image::Rgba([seed, 4, 8, 255]),
        );
        let mut out = Cursor::new(Vec::new());
        image.write_to(&mut out, image::ImageFormat::Png).unwrap();
        out.into_inner().into()
    }
    fn source(seed: u8) -> Source {
        Source::new(png(seed, false), Aspect::Carbox).unwrap()
    }
    fn jobs(tmp: &Path, generator: TestImageGenerator) -> ExpansionJobs {
        let cache = Cache::open(&tmp.join("cache.sqlite"), 1_000_000, 100).unwrap();
        let mut service = InterpretationService::new(
            CodexConfig {
                enabled: true,
                ..Default::default()
            },
            cache,
        );
        service.image_generator = Some(generator);
        ExpansionJobs::open_with_delays(
            service,
            &tmp.join("jobs.sqlite"),
            true,
            32_000_000,
            10,
            [Duration::from_millis(40), Duration::from_millis(90)],
        )
        .unwrap()
    }
    async fn until(jobs: &ExpansionJobs, id: &str, state: State) {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if jobs.snapshot(id).await.unwrap().state == state {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(3)).await;
            }
        })
        .await
        .unwrap();
    }
    #[tokio::test]
    async fn undelivered_work_survives_reopen_and_cannot_be_evicted() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("jobs.sqlite");
        let id;
        {
            let store = Store::open(&path, 11_000_000, 1).unwrap();
            id = store.admit(source(1), false).await.unwrap().snapshot.id;
            assert!(matches!(
                store.admit(source(2), false).await,
                Err(Error::Full)
            ));
            store.complete(&id, png(5, true)).await.unwrap();
            assert!(matches!(
                store.admit(source(2), false).await,
                Err(Error::Full)
            ));
        }
        let store = Store::open(&path, 11_000_000, 1).unwrap();
        assert_eq!(store.source(&id).await.unwrap().bytes, png(1, false));
        let (image, digest) = store.image(&id).await.unwrap();
        assert_eq!(image, png(5, true));
        assert!(matches!(
            store.acknowledge(&id, &"0".repeat(64)).await,
            Err(Error::Invalid)
        ));
        assert!(matches!(
            store.admit(source(2), false).await,
            Err(Error::Full)
        ));
        store.acknowledge(&id, &digest).await.unwrap();
        store.acknowledge(&id, &digest).await.unwrap();
        assert_eq!(
            store.admit(source(1), false).await.unwrap().snapshot.state,
            State::Completed
        );
        store.admit(source(2), false).await.unwrap();
        assert!(matches!(store.read(&id).await, Err(Error::Missing)));
    }
    #[tokio::test]
    async fn disabled_generator_serves_existing_results_but_never_accepts_new_work() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("jobs.sqlite");
        let id;
        {
            let store = Store::open(&path, 32_000_000, 10).unwrap();
            id = store.admit(source(1), false).await.unwrap().snapshot.id;
            store.complete(&id, png(5, true)).await.unwrap();
        }
        let cache = Cache::open(&tmp.path().join("cache.sqlite"), 1_000_000, 100).unwrap();
        let service = InterpretationService::new(CodexConfig::default(), cache);
        let jobs = ExpansionJobs::open(service, &path, false, 32_000_000, 10).unwrap();
        assert_eq!(
            jobs.create(source(1), false).await.unwrap().state,
            State::Completed
        );
        assert_eq!(jobs.image(&id).await.unwrap().0, png(5, true));
        assert!(matches!(
            jobs.create(source(2), false).await,
            Err(Error::Service(E::Disabled))
        ));
    }
    #[tokio::test]
    async fn accepted_and_duplicate_requests_share_one_durable_result() {
        let tmp = tempfile::tempdir().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let gate = Arc::new(Notify::new());
        let generator: TestImageGenerator = Arc::new({
            let calls = calls.clone();
            let gate = gate.clone();
            move || {
                calls.fetch_add(1, Ordering::SeqCst);
                let gate = gate.clone();
                Box::pin(async move {
                    gate.notified().await;
                    Ok(png(9, true))
                })
            }
        });
        let jobs = jobs(tmp.path(), generator);
        let first = jobs.create(source(1), false).await.unwrap();
        let id = first.id;
        until(&jobs, &id, State::Running).await;
        assert_eq!(jobs.create(source(1), false).await.unwrap().id, id);
        gate.notify_one();
        until(&jobs, &id, State::Completed).await;
        let (result, digest) = jobs.image(&id).await.unwrap();
        assert!(crate::panoramic_artwork::valid_generated_png(&result));
        jobs.acknowledge(&id, &digest).await.unwrap();
        assert_eq!(
            jobs.create(source(1), false).await.unwrap().state,
            State::Completed
        );
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }
    #[tokio::test]
    async fn transient_failures_stop_at_three_without_new_submission() {
        let tmp = tempfile::tempdir().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let generator: TestImageGenerator = Arc::new({
            let calls = calls.clone();
            move || {
                calls.fetch_add(1, Ordering::SeqCst);
                Box::pin(async { Err(E::Unavailable) })
            }
        });
        let jobs = jobs(tmp.path(), generator);
        let id = jobs.create(source(1), false).await.unwrap().id;
        until(&jobs, &id, State::Failed).await;
        let record = jobs.0.store.read(&id).await.unwrap();
        assert_eq!(record.attempts, 3);
        assert!(record.retry_at.is_none());
        assert_eq!(calls.load(Ordering::SeqCst), 3);
        jobs.snapshot(&id).await.unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 3);
    }
    #[tokio::test]
    async fn recovered_attempt_budget_is_not_reset() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("jobs.sqlite");
        let id;
        {
            let store = Store::open(&path, 32_000_000, 10).unwrap();
            let mut record = store.admit(source(1), false).await.unwrap();
            id = record.snapshot.id.clone();
            record.attempts = 3;
            record.retry_at = Some(unix_time());
            record.snapshot.state = State::Running;
            store.update(record).await.unwrap();
        }
        let calls = Arc::new(AtomicUsize::new(0));
        let generator: TestImageGenerator = Arc::new({
            let calls = calls.clone();
            move || {
                calls.fetch_add(1, Ordering::SeqCst);
                Box::pin(async { Ok(png(9, true)) })
            }
        });
        let jobs = jobs(tmp.path(), generator);
        until(&jobs, &id, State::Failed).await;
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        let record = jobs.0.store.read(&id).await.unwrap();
        assert_eq!(record.attempts, 3);
        assert!(record.retry_at.is_none());
    }
    #[tokio::test]
    async fn startup_resumes_pending_work_after_its_persisted_delay_without_a_client_poll() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("jobs.sqlite");
        let id;
        {
            let store = Store::open(&path, 32_000_000, 10).unwrap();
            let mut record = store.admit(source(1), false).await.unwrap();
            id = record.snapshot.id.clone();
            record.attempts = 2;
            record.retry_at = Some(unix_time() + 2);
            store.update(record).await.unwrap();
        }
        let calls = Arc::new(AtomicUsize::new(0));
        let generator: TestImageGenerator = Arc::new({
            let calls = calls.clone();
            move || {
                calls.fetch_add(1, Ordering::SeqCst);
                Box::pin(async { Ok(png(9, true)) })
            }
        });
        let jobs = jobs(tmp.path(), generator);
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert_eq!(jobs.0.workers.available_permits(), 4);
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if jobs.0.store.read(&id).await.unwrap().snapshot.state == State::Completed {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(jobs.0.store.read(&id).await.unwrap().attempts, 3);
    }
}
