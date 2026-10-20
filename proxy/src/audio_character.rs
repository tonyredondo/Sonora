//! Offline music tagging. A single bounded worker keeps TensorFlow off the phone
//! and prevents concurrent model copies from multiplying its ~1.4 GiB peak RAM.
use crate::{
    cache::{Cache, CacheEntry, ResponseHeaders, unix_time},
    config::AudioCharacterConfig,
};
use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use bytes::Bytes;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, process::Stdio, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::Command,
    sync::Semaphore,
};

pub const VERSION: &str = "essentia-discogs-v1";
pub const MAX_BYTES: usize = 90 * 32_000 + 44;
const MODELS: &str = include_str!("../analysis/models.json");
const WORKER: &str = include_str!("../analysis/analyze.py");

#[derive(Clone, Deserialize, Serialize)]
pub struct Style {
    pub label: String,
    pub score: f64,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Character {
    pub version: String,
    pub silent: bool,
    pub styles: Vec<Style>,
    pub moods: BTreeMap<String, f64>,
}
impl Character {
    fn valid(&self) -> bool {
        self.version == VERSION
            && self.styles.len() <= 8
            && (self.silent == self.styles.is_empty())
            && self.styles.iter().all(|s| {
                !s.label.trim().is_empty()
                    && s.label.len() <= 200
                    && !s.label.chars().any(char::is_control)
                    && score(s.score)
            })
            && self
                .styles
                .iter()
                .enumerate()
                .all(|(i, s)| self.styles[..i].iter().all(|other| s.label != other.label))
            && self.moods.len() == 4
            && ["happy", "sad", "relaxed", "aggressive"]
                .iter()
                .all(|name| self.moods.get(*name).is_some_and(|value| score(*value)))
    }
}
fn score(value: f64) -> bool {
    value.is_finite() && (0.0..=1.0).contains(&value)
}

#[derive(Debug, thiserror::Error)]
pub enum CharacterError {
    #[error("enable the local music analysis runtime on the Sonora server")]
    Disabled,
    #[error("music analysis queue is full")]
    Busy,
    #[error("music analysis took too long")]
    Timeout,
    #[error("music analysis runtime or models are unavailable")]
    Unavailable,
    #[error("music analysis returned invalid data")]
    InvalidResponse,
    #[error("music analysis cache is unavailable")]
    Cache,
    #[error("expected 1-90 seconds of mono 16 kHz PCM16 WAV")]
    InvalidInput,
}
impl IntoResponse for CharacterError {
    fn into_response(self) -> Response {
        let (status, code) = match self {
            Self::Disabled => (StatusCode::SERVICE_UNAVAILABLE, "audio_character_disabled"),
            Self::Busy => (StatusCode::TOO_MANY_REQUESTS, "audio_character_busy"),
            Self::Timeout => (StatusCode::GATEWAY_TIMEOUT, "audio_character_timeout"),
            Self::Unavailable => (
                StatusCode::SERVICE_UNAVAILABLE,
                "audio_character_unavailable",
            ),
            Self::InvalidResponse => (StatusCode::BAD_GATEWAY, "audio_character_invalid_response"),
            Self::Cache => (StatusCode::SERVICE_UNAVAILABLE, "audio_character_cache"),
            Self::InvalidInput => (StatusCode::BAD_REQUEST, "audio_character_input"),
        };
        tracing::warn!(error_code = code, "local music analysis failed");
        (
            status,
            Json(serde_json::json!({"error":code,"message":self.to_string()})),
        )
            .into_response()
    }
}

#[derive(Clone)]
pub struct CharacterService {
    config: AudioCharacterConfig,
    cache: Cache,
    queue: Arc<Semaphore>,
    worker: Arc<Semaphore>,
}
impl CharacterService {
    pub fn new(config: AudioCharacterConfig, cache: Cache) -> Self {
        Self {
            config,
            cache,
            queue: Arc::new(Semaphore::new(8)),
            worker: Arc::new(Semaphore::new(1)),
        }
    }
    async fn cached(&self, key: &str) -> Result<Option<Character>, CharacterError> {
        Ok(self
            .cache
            .get(key)
            .await
            .map_err(|_| CharacterError::Cache)?
            .and_then(|entry| serde_json::from_slice::<Character>(&entry.body).ok())
            .filter(Character::valid))
    }
    pub async fn analyze(&self, audio: Bytes, refresh: bool) -> Result<Character, CharacterError> {
        if audio.len() > MAX_BYTES || crate::audio_job::pcm_duration(&audio).is_err() {
            return Err(CharacterError::InvalidInput);
        }
        let mut hash = Sha256::new();
        hash.update(VERSION);
        hash.update(MODELS);
        hash.update(&audio);
        let key = format!("{VERSION}:{:x}", hash.finalize());
        if !refresh {
            if let Some(saved) = self.cached(&key).await? {
                return Ok(saved);
            }
        }
        if !self.config.enabled {
            return Err(CharacterError::Disabled);
        }
        let _place = self.queue.try_acquire().map_err(|_| CharacterError::Busy)?;
        tokio::time::timeout(Duration::from_secs(90), async {
            let _worker = self
                .worker
                .acquire()
                .await
                .map_err(|_| CharacterError::Unavailable)?;
            // Queued duplicates reuse the first completion without starting a process.
            if !refresh {
                if let Some(saved) = self.cached(&key).await? {
                    return Ok(saved);
                }
            }
            let value = self.run(&audio).await?;
            let body = serde_json::to_vec(&value).map_err(|_| CharacterError::InvalidResponse)?;
            let now = unix_time();
            self.cache
                .put(
                    &key,
                    CacheEntry {
                        status: 200,
                        headers: ResponseHeaders::default(),
                        body: body.into(),
                        stored_at: now,
                        expires_at: now + 365 * 86400,
                    },
                )
                .await
                .map_err(|_| CharacterError::Cache)?;
            Ok(value)
        })
        .await
        .map_err(|_| CharacterError::Timeout)?
    }
    async fn run(&self, audio: &[u8]) -> Result<Character, CharacterError> {
        tokio::time::timeout(Duration::from_secs(60), async {
            let mut child = Command::new(&self.config.python)
                .arg("-I")
                .arg("-c")
                .arg(WORKER)
                .arg(&self.config.models)
                .arg(MODELS)
                .env_remove("PYTHONPATH")
                .env_remove("PYTHONHOME")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .kill_on_drop(true)
                .spawn()
                .map_err(|_| CharacterError::Unavailable)?;
            let mut input = child.stdin.take().ok_or(CharacterError::Unavailable)?;
            let output = child.stdout.take().ok_or(CharacterError::Unavailable)?;
            let write = async move {
                input.write_all(audio).await?;
                // ChildStdin::shutdown does not close the pipe. The worker reads
                // until EOF, so release ownership before waiting for stdout.
                drop(input);
                Ok::<_, std::io::Error>(())
            };
            let read = async {
                let mut bytes = Vec::new();
                output
                    .take(32_769)
                    .read_to_end(&mut bytes)
                    .await
                    .map(|_| bytes)
            };
            let (_, bytes) =
                tokio::try_join!(write, read).map_err(|_| CharacterError::Unavailable)?;
            if bytes.len() > 32_768 {
                return Err(CharacterError::InvalidResponse);
            }
            if !child
                .wait()
                .await
                .map_err(|_| CharacterError::Unavailable)?
                .success()
            {
                return Err(CharacterError::Unavailable);
            }
            let value: Character =
                serde_json::from_slice(&bytes).map_err(|_| CharacterError::InvalidResponse)?;
            if !value.valid() {
                return Err(CharacterError::InvalidResponse);
            }
            Ok(value)
        })
        .await
        .map_err(|_| CharacterError::Timeout)?
    }
}
