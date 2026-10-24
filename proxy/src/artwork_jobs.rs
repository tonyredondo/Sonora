//! Restartable image jobs. HTTP connections never own the generation task.
use crate::{
    cache::{Cache, CacheEntry, ResponseHeaders, unix_time},
    generated_artwork::{ArtworkInput, CACHE_PREFIX},
    interpretation::{InterpretationError, InterpretationService, MAX_CONCURRENT_REQUESTS},
};
use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
use tokio::sync::{Mutex as AsyncMutex, Semaphore};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Queued,
    Running,
    Completed,
    Failed,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Snapshot {
    pub id: String,
    pub state: State,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}
#[derive(Clone, Deserialize, Serialize)]
struct Record {
    input: ArtworkInput,
    snapshot: Snapshot,
}

#[derive(Debug)]
pub enum JobError {
    Service(InterpretationError),
    NotFound,
    NotReady,
}
impl From<InterpretationError> for JobError {
    fn from(error: InterpretationError) -> Self {
        Self::Service(error)
    }
}
impl IntoResponse for JobError {
    fn into_response(self) -> Response {
        let (status, code) = match self {
            Self::Service(error) => return error.into_response(),
            Self::NotFound => (StatusCode::NOT_FOUND, "artwork_job_not_found"),
            Self::NotReady => (StatusCode::CONFLICT, "artwork_job_not_ready"),
        };
        (status, Json(serde_json::json!({"error":code}))).into_response()
    }
}
struct Inner {
    service: InterpretationService,
    cache: Cache,
    enabled: bool,
    limit: usize,
    admission: AsyncMutex<()>,
    states: Mutex<HashMap<String, Snapshot>>,
    workers: Arc<Semaphore>,
}
#[derive(Clone)]
pub struct ArtworkJobs(Arc<Inner>);
impl ArtworkJobs {
    pub fn new(service: InterpretationService, cache: Cache, enabled: bool, limit: usize) -> Self {
        Self(Arc::new(Inner {
            service,
            cache,
            enabled,
            limit,
            admission: AsyncMutex::new(()),
            states: Mutex::default(),
            workers: Arc::new(Semaphore::new(MAX_CONCURRENT_REQUESTS)),
        }))
    }
    pub async fn create(
        &self,
        input: ArtworkInput,
        retry_failed: bool,
    ) -> Result<Snapshot, JobError> {
        input.validate()?;
        let key = input.key()?;
        let id = key
            .strip_prefix(CACHE_PREFIX)
            .ok_or(InterpretationError::Invalid)?
            .to_owned();
        self.admit(&id, Some(input), retry_failed).await
    }
    pub async fn snapshot(&self, id: &str) -> Result<Snapshot, JobError> {
        self.admit(id, None, false).await
    }
    pub async fn image(&self, id: &str) -> Result<bytes::Bytes, JobError> {
        validate_id(id)?;
        self.0
            .service
            .cached_artwork(&format!("{CACHE_PREFIX}{id}"))
            .await?
            .ok_or(JobError::NotReady)
    }
    async fn admit(
        &self,
        id: &str,
        input: Option<ArtworkInput>,
        retry_failed: bool,
    ) -> Result<Snapshot, JobError> {
        validate_id(id)?;
        // Serialize admission, not generation. This also covers a lost POST response.
        let _admission = self.0.admission.lock().await;
        let current = self
            .0
            .states
            .lock()
            .map_err(|_| InterpretationError::Unavailable)?
            .get(id)
            .cloned();
        if let Some(current) = current {
            if !retry_failed || matches!(current.state, State::Queued | State::Running) {
                return Ok(current);
            }
        }
        if self
            .0
            .service
            .cached_artwork(&format!("{CACHE_PREFIX}{id}"))
            .await?
            .is_some()
        {
            return Ok(Snapshot {
                id: id.into(),
                state: State::Completed,
                error: None,
            });
        }
        let saved = self
            .0
            .cache
            .get(&record_key(id))
            .await
            .map_err(|_| InterpretationError::Cache)?;
        let record = saved
            .map(|entry| {
                if entry.body.len() > 128 * 1024 {
                    return Err(InterpretationError::Cache);
                }
                serde_json::from_slice::<Record>(&entry.body)
                    .map_err(|_| InterpretationError::Cache)
            })
            .transpose()?;
        if let Some(record) = &record {
            record.input.validate()?;
            // Accepted IDs outlive changes to the prompt used for new submissions.
            if record.snapshot.id != id {
                return Err(InterpretationError::Cache.into());
            }
            if !retry_failed && record.snapshot.state == State::Failed {
                return Ok(record.snapshot.clone());
            }
        }
        let input = input
            .or_else(|| record.map(|record| record.input))
            .ok_or(JobError::NotFound)?;
        if !self.0.enabled {
            return Err(InterpretationError::Disabled.into());
        }
        {
            let mut states = self
                .0
                .states
                .lock()
                .map_err(|_| InterpretationError::Unavailable)?;
            if states.len() >= self.0.limit {
                states.retain(|_, s| matches!(s.state, State::Queued | State::Running));
            }
            if states.len() >= self.0.limit {
                return Err(InterpretationError::Busy.into());
            }
        }
        let snapshot = Snapshot {
            id: id.into(),
            state: State::Queued,
            error: None,
        };
        let record = Record {
            input,
            snapshot: snapshot.clone(),
        };
        self.save(&record).await?;
        self.0
            .states
            .lock()
            .map_err(|_| InterpretationError::Unavailable)?
            .insert(id.into(), snapshot.clone());
        tracing::info!(job_id = id, "Artwork job accepted");
        let jobs = self.clone();
        tokio::spawn(async move {
            jobs.run(record).await;
        });
        Ok(snapshot)
    }
    async fn save(&self, record: &Record) -> Result<(), InterpretationError> {
        let key = record_key(&record.snapshot.id);
        let body =
            bytes::Bytes::from(serde_json::to_vec(record).map_err(|_| InterpretationError::Cache)?);
        let now = unix_time();
        self.0
            .cache
            .put(
                &key,
                CacheEntry {
                    status: 200,
                    headers: ResponseHeaders::default(),
                    body: body.clone(),
                    stored_at: now,
                    expires_at: now + 365 * 86400,
                },
            )
            .await
            .map_err(|_| InterpretationError::Cache)?;
        // A cache configured smaller than a record must reject admission explicitly.
        if self
            .0
            .cache
            .get(&key)
            .await
            .map_err(|_| InterpretationError::Cache)?
            .is_none_or(|entry| entry.body != body)
        {
            return Err(InterpretationError::Cache);
        }
        Ok(())
    }
    async fn run(&self, mut record: Record) {
        let started = std::time::Instant::now();
        let Ok(_worker) = self.0.workers.clone().acquire_owned().await else {
            return;
        };
        let jobs = self.clone();
        let id = record.snapshot.id.clone();
        let mut result = self
            .0
            .service
            .generate_artwork_notifying(record.input.clone(), move || {
                if let Ok(mut states) = jobs.0.states.lock() {
                    if let Some(state) = states.get_mut(&id) {
                        state.state = State::Running;
                        tracing::info!(job_id = %id, "Artwork generation started");
                    }
                }
            })
            .await
            .map(|_| ());
        if result.is_ok() {
            result = self.preserve_job_image(&record).await;
        }
        match result {
            Ok(_) => record.snapshot.state = State::Completed,
            Err(error) => {
                record.snapshot.state = State::Failed;
                record.snapshot.error = Some(error.code().into());
            }
        }
        if self.save(&record).await.is_err() {
            record.snapshot.state = State::Failed;
            record.snapshot.error = Some("codex_cache_unavailable".into());
        }
        if let Some(code) = &record.snapshot.error {
            tracing::warn!(job_id = %record.snapshot.id, error_code = code, elapsed_ms = started.elapsed().as_millis() as u64, "Artwork job failed");
        } else {
            tracing::info!(job_id = %record.snapshot.id, elapsed_ms = started.elapsed().as_millis() as u64, "Artwork job completed");
        }
        if let Ok(mut states) = self.0.states.lock() {
            states.insert(record.snapshot.id.clone(), record.snapshot);
        }
    }
    async fn preserve_job_image(&self, record: &Record) -> Result<(), InterpretationError> {
        let current_key = record.input.key()?;
        let accepted_key = format!("{CACHE_PREFIX}{}", record.snapshot.id);
        if current_key == accepted_key {
            return Ok(());
        }
        // A recovered job keeps its download URL even when a newer prompt supplied the image.
        let entry = self
            .0
            .cache
            .get(&current_key)
            .await
            .map_err(|_| InterpretationError::Cache)?
            .ok_or(InterpretationError::Cache)?;
        self.0
            .cache
            .put(&accepted_key, entry)
            .await
            .map_err(|_| InterpretationError::Cache)?;
        if self
            .0
            .service
            .cached_artwork(&accepted_key)
            .await?
            .is_none()
        {
            return Err(InterpretationError::Cache);
        }
        Ok(())
    }
}
fn validate_id(id: &str) -> Result<(), InterpretationError> {
    if id.len() != 64
        || !id
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    {
        return Err(InterpretationError::Invalid);
    }
    Ok(())
}
fn record_key(id: &str) -> String {
    format!("codex-artwork-job-v1:{id}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        config::{CodexConfig, Config},
        interpretation::TestImageGenerator,
    };
    use std::{
        sync::atomic::{AtomicUsize, Ordering},
        time::Duration,
    };
    use tokio::sync::Notify;

    fn input(title: &str) -> ArtworkInput {
        ArtworkInput {
            title: title.into(),
            artist: "Synthetic Artist".into(),
            album: "First Light".into(),
            album_description: "A record about beginnings".into(),
            genre: "Ambient".into(),
            styles: vec![],
            moods: vec![],
        }
    }
    fn png() -> bytes::Bytes {
        bytes::Bytes::from_static(&[
            137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1,
            8, 4, 0, 0, 0, 181, 28, 12, 2, 0, 0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 252, 255, 31,
            0, 3, 3, 2, 0, 239, 151, 218, 44, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
        ])
    }
    fn jobs(cache: Cache, generator: TestImageGenerator, limit: usize) -> ArtworkJobs {
        let mut service = InterpretationService::new(
            CodexConfig {
                enabled: true,
                ..CodexConfig::default()
            },
            cache.clone(),
        );
        service.image_generator = Some(generator);
        ArtworkJobs::new(service, cache, true, limit)
    }
    async fn until(jobs: &ArtworkJobs, id: &str, state: State) -> Snapshot {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let snapshot = jobs.snapshot(id).await.unwrap();
                if snapshot.state == state {
                    return snapshot;
                }
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        })
        .await
        .unwrap()
    }
    #[tokio::test]
    async fn accepted_job_survives_caller_disconnect_and_duplicate_submissions() {
        let tmp = tempfile::tempdir().unwrap();
        let cache = Cache::open(&tmp.path().join("cache.sqlite"), 1_000_000, 100).unwrap();
        let gate = Arc::new(Notify::new());
        let calls = Arc::new(AtomicUsize::new(0));
        let generator: TestImageGenerator = Arc::new({
            let gate = gate.clone();
            let calls = calls.clone();
            move || {
                let gate = gate.clone();
                calls.fetch_add(1, Ordering::SeqCst);
                Box::pin(async move {
                    gate.notified().await;
                    Ok(png())
                })
            }
        });
        let jobs = jobs(cache, generator, 1);
        let first =
            tokio::time::timeout(Duration::from_millis(200), jobs.create(input("One"), false))
                .await
                .unwrap()
                .unwrap();
        let id = first.id.clone();
        drop(first);
        until(&jobs, &id, State::Running).await;
        let duplicate = jobs.create(input("One"), false).await.unwrap();
        assert_eq!(duplicate.id, id);
        assert!(matches!(
            jobs.create(input("Two"), false).await,
            Err(JobError::Service(InterpretationError::Busy))
        ));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        gate.notify_one();
        until(&jobs, &id, State::Completed).await;
        assert_eq!(jobs.image(&id).await.unwrap(), png());
        assert_eq!(
            jobs.create(input("One"), false).await.unwrap().state,
            State::Completed
        );
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }
    #[tokio::test]
    async fn reopening_disk_recovers_unfinished_input_and_completed_image() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("cache.sqlite");
        let calls = Arc::new(AtomicUsize::new(0));
        let generator: TestImageGenerator = Arc::new({
            let calls = calls.clone();
            move || {
                calls.fetch_add(1, Ordering::SeqCst);
                Box::pin(async { Ok(png()) })
            }
        });
        let data = input("Restart");
        let id = data
            .key()
            .unwrap()
            .strip_prefix(CACHE_PREFIX)
            .unwrap()
            .to_owned();
        {
            let cache = Cache::open(&path, 1_000_000, 100).unwrap();
            let jobs = jobs(cache, generator.clone(), 4);
            // This is the durable boundary before an interrupted server starts its worker.
            jobs.save(&Record {
                input: data,
                snapshot: Snapshot {
                    id: id.clone(),
                    state: State::Queued,
                    error: None,
                },
            })
            .await
            .unwrap();
        }
        {
            let cache = Cache::open(&path, 1_000_000, 100).unwrap();
            let jobs = jobs(cache, generator.clone(), 4);
            until(&jobs, &id, State::Completed).await;
            assert_eq!(calls.load(Ordering::SeqCst), 1);
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
        let cache = Cache::open(&path, 1_000_000, 100).unwrap();
        let jobs = jobs(cache, generator, 4);
        assert_eq!(jobs.snapshot(&id).await.unwrap().state, State::Completed);
        assert_eq!(jobs.image(&id).await.unwrap(), png());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }
    #[tokio::test]
    async fn accepted_job_survives_a_prompt_policy_change() {
        let tmp = tempfile::tempdir().unwrap();
        let cache = Cache::open(&tmp.path().join("cache.sqlite"), 1_000_000, 100).unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let generator: TestImageGenerator = Arc::new({
            let calls = calls.clone();
            move || {
                calls.fetch_add(1, Ordering::SeqCst);
                Box::pin(async { Ok(png()) })
            }
        });
        let jobs = jobs(cache, generator, 4);
        let id = "a".repeat(64);
        let data = input("Older policy");
        assert_ne!(data.key().unwrap(), format!("{CACHE_PREFIX}{id}"));
        jobs.save(&Record {
            input: data,
            snapshot: Snapshot {
                id: id.clone(),
                state: State::Queued,
                error: None,
            },
        })
        .await
        .unwrap();
        until(&jobs, &id, State::Completed).await;
        assert_eq!(jobs.image(&id).await.unwrap(), png());
        let reopened = ArtworkJobs::new(jobs.0.service.clone(), jobs.0.cache.clone(), true, 4);
        assert_eq!(
            reopened.snapshot(&id).await.unwrap().state,
            State::Completed
        );
        assert_eq!(reopened.image(&id).await.unwrap(), png());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }
    #[tokio::test]
    async fn failures_are_queryable_and_do_not_retry_on_status_reads() {
        let tmp = tempfile::tempdir().unwrap();
        let cache = Cache::open(&tmp.path().join("cache.sqlite"), 1_000_000, 100).unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let generator: TestImageGenerator = Arc::new({
            let calls = calls.clone();
            move || {
                calls.fetch_add(1, Ordering::SeqCst);
                Box::pin(async { Err(InterpretationError::Limit) })
            }
        });
        let jobs = jobs(cache, generator, 4);
        let created = jobs.create(input("Failure"), false).await.unwrap();
        let failed = until(&jobs, &created.id, State::Failed).await;
        assert_eq!(failed.error.as_deref(), Some("codex_limit"));
        for _ in 0..3 {
            assert_eq!(
                jobs.snapshot(&created.id).await.unwrap().state,
                State::Failed
            );
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        let recovered = jobs.create(input("Failure"), false).await.unwrap();
        assert_eq!(
            recovered.state,
            State::Failed,
            "A lost acknowledgement must not retry a failed generation"
        );
        let reopened = ArtworkJobs::new(jobs.0.service.clone(), jobs.0.cache.clone(), true, 4);
        assert_eq!(
            reopened
                .snapshot(&created.id)
                .await
                .unwrap()
                .error
                .as_deref(),
            Some("codex_limit")
        );
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "Recovering a persisted failure must not retry it"
        );
        jobs.create(input("Failure"), true).await.unwrap();
        until(&jobs, &created.id, State::Failed).await;
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }
    #[tokio::test]
    async fn impossible_persistence_never_acknowledges_or_runs_the_job() {
        let tmp = tempfile::tempdir().unwrap();
        let cache = Cache::open(&tmp.path().join("cache.sqlite"), 1, 100).unwrap();
        let generator: TestImageGenerator = Arc::new(|| {
            Box::pin(async { panic!("Unpersisted input must not consume generation") })
        });
        let jobs = jobs(cache, generator, 4);
        assert!(matches!(
            jobs.create(input("Too large"), false).await,
            Err(JobError::Service(InterpretationError::Cache))
        ));
        assert!(matches!(
            jobs.snapshot("bad").await,
            Err(JobError::Service(InterpretationError::Invalid))
        ));
    }
    #[tokio::test]
    async fn cached_job_routes_require_auth_and_return_the_persisted_image() {
        use axum::{body::Body, http::Request};
        use http_body_util::BodyExt;
        use tower::ServiceExt;
        let tmp = tempfile::tempdir().unwrap();
        let mut config = Config::default();
        config.cache.path = tmp.path().join("cache.sqlite");
        config.metadata.path = tmp.path().join("metadata.sqlite");
        config.server.api_token = Some("synthetic-fixture".into());
        let data = input("Cached");
        let id = data
            .key()
            .unwrap()
            .strip_prefix(CACHE_PREFIX)
            .unwrap()
            .to_owned();
        {
            let cache = Cache::open(&config.cache.path, 1_000_000, 100).unwrap();
            let now = unix_time();
            cache
                .put(
                    &data.key().unwrap(),
                    CacheEntry {
                        status: 200,
                        headers: ResponseHeaders::default(),
                        body: png(),
                        stored_at: now,
                        expires_at: now + 86400,
                    },
                )
                .await
                .unwrap();
        }
        let app = crate::api::router(config).unwrap();
        let request = || {
            Request::builder()
                .method("POST")
                .uri("/v1/artwork/jobs")
                .header("content-type", "application/json")
        };
        let json = serde_json::to_vec(&data).unwrap();
        assert_eq!(
            app.clone()
                .oneshot(request().body(Body::from(json.clone())).unwrap())
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        let response = app
            .clone()
            .oneshot(
                request()
                    .header("authorization", "Bearer synthetic-fixture")
                    .body(Body::from(json))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::ACCEPTED);
        let snapshot: Snapshot =
            serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                .unwrap();
        assert_eq!(snapshot.id, id);
        assert_eq!(snapshot.state, State::Completed);
        for path in [
            format!("/v1/artwork/jobs/{id}"),
            format!("/v1/artwork/jobs/{id}/image"),
        ] {
            assert_eq!(
                app.clone()
                    .oneshot(Request::builder().uri(&path).body(Body::empty()).unwrap())
                    .await
                    .unwrap()
                    .status(),
                StatusCode::UNAUTHORIZED
            );
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .uri(&path)
                        .header("authorization", "Bearer synthetic-fixture")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let bytes = response.into_body().collect().await.unwrap().to_bytes();
            if path.ends_with("/image") {
                assert_eq!(bytes, png());
            } else {
                assert_eq!(
                    serde_json::from_slice::<Snapshot>(&bytes).unwrap().state,
                    State::Completed
                );
            }
        }
    }
}
