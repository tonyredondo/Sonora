//! Bounded, ephemeral lookup jobs. Cached provider responses outlive jobs and restarts.

use crate::{
    cache::unix_time,
    config::Provider,
    providers::{Client, Error, Priority, RecordingCandidate, Reply, TrackInput},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex, Weak},
};
use tokio::{sync::Semaphore, task::AbortHandle};
use uuid::Uuid;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BatchInput {
    pub tracks: Vec<TrackInput>,
    #[serde(default)]
    pub priority: Priority,
}
#[derive(Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    Queued,
    Running,
    Completed,
    Cancelled,
    Failed,
}
impl JobState {
    fn terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Cancelled | Self::Failed)
    }
}

#[derive(Clone, Serialize)]
pub struct Warning {
    pub provider: Provider,
    pub message: String,
}
#[derive(Clone, Serialize)]
pub struct TrackResult {
    pub index: usize,
    pub metadata: Option<Reply<Vec<RecordingCandidate>>>,
    pub identification: Option<Reply<Value>>,
    pub lyrics: Option<Reply<Value>>,
    pub warnings: Vec<Warning>,
}
#[derive(Clone, Serialize)]
pub struct JobSnapshot {
    pub id: Uuid,
    pub state: JobState,
    pub total: usize,
    pub completed: usize,
    pub results: Vec<TrackResult>,
    pub error: Option<String>,
}
struct Job {
    snapshot: JobSnapshot,
    updated: u64,
    bytes: usize,
    task: Option<AbortHandle>,
}
struct Inner {
    state: Mutex<HashMap<Uuid, Job>>,
    client: Client,
    slots: Arc<Semaphore>,
}
impl Drop for Inner {
    fn drop(&mut self) {
        let state = self.state.get_mut().unwrap_or_else(|p| p.into_inner());
        for job in state.values() {
            if let Some(task) = &job.task {
                task.abort();
            }
        }
    }
}
#[derive(Clone)]
pub struct Jobs(Arc<Inner>);
impl Jobs {
    pub fn new(client: Client) -> Self {
        Self(Arc::new(Inner {
            state: Mutex::default(),
            client,
            slots: Arc::new(Semaphore::new(4)),
        }))
    }
    pub fn create(&self, input: BatchInput) -> Result<JobSnapshot, Error> {
        let config = &self.0.client.config().server;
        if input.tracks.is_empty() || input.tracks.len() > config.max_tracks_per_job {
            return Err(Error::InvalidInput(
                "batch track count exceeds its configured limit",
            ));
        }
        for track in &input.tracks {
            track.validate()?;
            if !track.has_title() && track.fingerprint.is_none() {
                return Err(Error::InvalidInput(
                    "each track needs a title or fingerprint",
                ));
            }
            if track.fingerprint.is_some() && track.duration.is_none() {
                return Err(Error::InvalidInput("fingerprints require duration"));
            }
        }
        let mut state = self.0.state.lock().map_err(|_| Error::Unavailable)?;
        let now = unix_time();
        state.retain(|_, j| {
            !j.snapshot.state.terminal()
                || now.saturating_sub(j.updated) < config.job_retention_seconds
        });
        if state.len() >= config.max_jobs {
            let oldest = state
                .iter()
                .filter(|(_, j)| j.snapshot.state.terminal())
                .min_by_key(|(_, j)| j.updated)
                .map(|(id, _)| *id);
            if let Some(id) = oldest {
                state.remove(&id);
            } else {
                return Err(Error::QueueFull);
            }
        }
        let snapshot = JobSnapshot {
            id: Uuid::new_v4(),
            state: JobState::Queued,
            total: input.tracks.len(),
            completed: 0,
            results: Vec::new(),
            error: None,
        };
        let id = snapshot.id;
        state.insert(
            id,
            Job {
                snapshot: snapshot.clone(),
                updated: now,
                bytes: 0,
                task: None,
            },
        );
        let weak = Arc::downgrade(&self.0);
        let client = self.0.client.clone();
        let slots = self.0.slots.clone();
        let task = tokio::spawn(run(weak, client, slots, id, input));
        if let Some(job) = state.get_mut(&id) {
            job.task = Some(task.abort_handle());
        }
        Ok(snapshot)
    }
    pub fn snapshot(&self, id: Uuid) -> Result<Option<JobSnapshot>, Error> {
        let mut state = self.0.state.lock().map_err(|_| Error::Unavailable)?;
        let retention = self.0.client.config().server.job_retention_seconds;
        if state.get(&id).is_some_and(|j| {
            j.snapshot.state.terminal() && unix_time().saturating_sub(j.updated) >= retention
        }) {
            state.remove(&id);
        }
        Ok(state.get(&id).map(|j| j.snapshot.clone()))
    }
    pub fn cancel(&self, id: Uuid) -> Result<Option<JobSnapshot>, Error> {
        let mut state = self.0.state.lock().map_err(|_| Error::Unavailable)?;
        let Some(job) = state.get_mut(&id) else {
            return Ok(None);
        };
        if !job.snapshot.state.terminal() {
            job.snapshot.state = JobState::Cancelled;
            job.updated = unix_time();
            if let Some(task) = &job.task {
                task.abort();
            }
        }
        Ok(Some(job.snapshot.clone()))
    }
}
fn update(weak: &Weak<Inner>, id: Uuid, f: impl FnOnce(&mut Job)) -> bool {
    let Some(inner) = weak.upgrade() else {
        return false;
    };
    let Ok(mut state) = inner.state.lock() else {
        return false;
    };
    let Some(job) = state.get_mut(&id).filter(|j| !j.snapshot.state.terminal()) else {
        return false;
    };
    f(job);
    job.updated = unix_time();
    true
}
async fn run(
    weak: Weak<Inner>,
    client: Client,
    slots: Arc<Semaphore>,
    id: Uuid,
    input: BatchInput,
) {
    let Ok(_permit) = slots.acquire_owned().await else {
        return;
    };
    if !update(&weak, id, |job| job.snapshot.state = JobState::Running) {
        return;
    }
    let limit = client.config().server.max_job_result_bytes;
    for (index, track) in input.tracks.iter().enumerate() {
        let result = lookup(&client, track, index, input.priority).await;
        let bytes = match serde_json::to_vec(&result) {
            Ok(bytes) => bytes.len(),
            Err(_) => {
                update(&weak, id, |job| {
                    job.snapshot.state = JobState::Failed;
                    job.snapshot.error = Some("result serialization failed".into());
                });
                return;
            }
        };
        let mut exceeded = false;
        if !update(&weak, id, |job| {
            if bytes > limit.saturating_sub(job.bytes) {
                job.snapshot.state = JobState::Failed;
                job.snapshot.error = Some(
                    "job result exceeds configured memory limit; submit a smaller batch".into(),
                );
                exceeded = true;
            } else {
                job.bytes += bytes;
                job.snapshot.results.push(result);
                job.snapshot.completed += 1;
            }
        }) || exceeded
        {
            return;
        }
    }
    update(&weak, id, |job| job.snapshot.state = JobState::Completed);
}
async fn lookup(
    client: &Client,
    input: &TrackInput,
    index: usize,
    priority: Priority,
) -> TrackResult {
    // Metadata and lyrics have independent queues and independent failures.
    let (metadata, lyrics) = tokio::join!(metadata(client, input, priority), async {
        if input.lyrics && input.has_lyrics_signature() {
            Some(client.lyrics(input, priority).await)
        } else {
            None
        }
    });
    let (metadata, identification, mut warnings) = metadata;
    let lyrics = match lyrics {
        Some(Ok(lyrics)) => Some(lyrics),
        Some(Err(e)) => {
            warnings.push(Warning {
                provider: Provider::Lrclib,
                message: e.to_string(),
            });
            None
        }
        None => {
            if input.lyrics {
                warnings.push(Warning {
                    provider: Provider::Lrclib,
                    message: "lyrics require title, artist, album and duration".into(),
                });
            }
            None
        }
    };
    TrackResult {
        index,
        metadata,
        identification,
        lyrics,
        warnings,
    }
}
async fn metadata(
    client: &Client,
    input: &TrackInput,
    priority: Priority,
) -> (
    Option<Reply<Vec<RecordingCandidate>>>,
    Option<Reply<Value>>,
    Vec<Warning>,
) {
    let mut warnings = Vec::new();
    let mut identification = None;
    if input.fingerprint.is_some() {
        match client.identify(input, priority).await {
            Ok(reply) => {
                let mut matches: Vec<_> = reply
                    .data
                    .get("results")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .collect();
                matches.sort_by(|a, b| {
                    b.get("score")
                        .and_then(Value::as_f64)
                        .unwrap_or(0.0)
                        .total_cmp(&a.get("score").and_then(Value::as_f64).unwrap_or(0.0))
                });
                let mut seen = HashSet::new();
                let ids: Vec<String> = matches
                    .into_iter()
                    .flat_map(|r| {
                        r.get("recordings")
                            .and_then(Value::as_array)
                            .into_iter()
                            .flatten()
                    })
                    .filter_map(|r| r.get("id").and_then(Value::as_str))
                    .filter(|id| seen.insert((*id).to_owned()))
                    .take(3)
                    .map(str::to_owned)
                    .collect();
                identification = Some(reply);
                let mut metadata: Option<Reply<Vec<RecordingCandidate>>> = None;
                for id in ids {
                    match client.recording(&id, priority).await {
                        Ok(reply) => {
                            if let Some(combined) = &mut metadata {
                                combined.data.push(reply.data);
                                combined.sources.extend(reply.sources);
                                if combined.cache != reply.cache {
                                    combined.cache = "mixed".into();
                                }
                                combined.fetched_at = combined.fetched_at.min(reply.fetched_at);
                            } else {
                                metadata = Some(Reply {
                                    provider: reply.provider,
                                    sources: reply.sources,
                                    cache: reply.cache,
                                    fetched_at: reply.fetched_at,
                                    data: vec![reply.data],
                                });
                            }
                        }
                        Err(e) => warnings.push(Warning {
                            provider: Provider::Musicbrainz,
                            message: e.to_string(),
                        }),
                    }
                }
                if metadata.is_some() {
                    return (metadata, identification, warnings);
                }
            }
            Err(e) => warnings.push(Warning {
                provider: Provider::Acoustid,
                message: e.to_string(),
            }),
        }
    }
    let metadata = if input.has_title() {
        match client.search(input, priority).await {
            Ok(reply) => Some(reply),
            Err(e) => {
                warnings.push(Warning {
                    provider: Provider::Musicbrainz,
                    message: e.to_string(),
                });
                None
            }
        }
    } else {
        None
    };
    (metadata, identification, warnings)
}
