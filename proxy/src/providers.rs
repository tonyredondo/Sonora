//! Validated provider operations and a common response envelope with provenance.

use crate::{
    config::{Config, Provider},
    scheduler::{FetchResult, RequestSpec, Scheduler},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, thiserror::Error)]
pub enum Error {
    #[error("invalid input: {0}")]
    InvalidInput(&'static str),
    #[error("proxy configuration is invalid")]
    Configuration,
    #[error("cache read or write failed")]
    Cache,
    #[error("provider is disabled: {0:?}")]
    Disabled(Provider),
    #[error("provider needs a client key: {0:?}")]
    NotConfigured(Provider),
    #[error("provider queue is full")]
    QueueFull,
    #[error("lookup deadline exceeded")]
    Deadline,
    #[error("lookup worker is unavailable")]
    Unavailable,
    #[error("no result from provider: {0:?}")]
    NotFound(Provider),
    #[error("provider request failed: {provider:?}, HTTP {status:?}")]
    Upstream {
        provider: Provider,
        status: Option<u16>,
    },
    #[error("provider returned an invalid response: {0:?}")]
    InvalidResponse(Provider),
    #[error("provider response exceeds the configured size limit")]
    TooLarge,
}

#[derive(Clone, Copy, Default, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Priority {
    Interactive,
    #[default]
    Background,
}

fn yes() -> bool {
    true
}
/// Tags and a locally computed fingerprint only; never an audio file or filesystem path.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TrackInput {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration: Option<u32>,
    pub fingerprint: Option<String>,
    #[serde(default = "yes")]
    pub lyrics: bool,
}
impl TrackInput {
    pub fn validate(&self) -> Result<(), Error> {
        for text in [&self.title, &self.artist, &self.album]
            .into_iter()
            .flatten()
        {
            if text.len() > 1024 || text.contains('\0') {
                return Err(Error::InvalidInput(
                    "tag exceeds 1024 bytes or contains NUL",
                ));
            }
        }
        if self.duration.is_some_and(|d| d == 0 || d > 604800) {
            return Err(Error::InvalidInput("duration must be 1-604800 seconds"));
        }
        if self.fingerprint.as_ref().is_some_and(|s| {
            s.is_empty()
                || s.len() > 32768
                || !s
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_=".contains(&b))
        }) {
            return Err(Error::InvalidInput(
                "fingerprint must be an encoded Chromaprint value",
            ));
        }
        Ok(())
    }
    pub fn has_title(&self) -> bool {
        self.title.as_ref().is_some_and(|s| !s.trim().is_empty())
    }
    pub fn has_lyrics_signature(&self) -> bool {
        [&self.title, &self.artist, &self.album]
            .into_iter()
            .all(|v| v.as_ref().is_some_and(|s| !s.trim().is_empty()))
            && self.duration.is_some()
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct Reply<T> {
    pub provider: Provider,
    pub sources: Vec<String>,
    pub cache: String,
    pub fetched_at: u64,
    pub data: T,
}
#[derive(Clone, Debug, Serialize)]
pub struct ReleaseSummary {
    pub id: String,
    pub title: String,
    pub date: Option<String>,
    pub country: Option<String>,
    pub disambiguation: Option<String>,
    pub artwork_path: String,
}
#[derive(Clone, Debug, Serialize)]
pub struct RecordingCandidate {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub duration_ms: Option<u64>,
    pub disambiguation: Option<String>,
    /// MusicBrainz search relevance; this is not a probability or an automatic match decision.
    pub score: Option<u64>,
    pub releases: Vec<ReleaseSummary>,
    pub genres: Vec<String>,
}

#[derive(Clone)]
pub struct Client {
    scheduler: Scheduler,
    config: Config,
}
impl Client {
    pub fn new(config: Config) -> Result<Self, Error> {
        Ok(Self {
            scheduler: Scheduler::new(config.clone())?,
            config,
        })
    }
    pub(crate) fn config(&self) -> &Config {
        &self.config
    }
    fn request(
        &self,
        provider: Provider,
        path: &str,
        parameters: &[(&str, String)],
    ) -> Result<RequestSpec, Error> {
        let base = self
            .config
            .provider(provider)
            .base_url
            .as_deref()
            .unwrap_or_else(|| provider.base_url());
        let mut url = url::Url::parse(base)
            .and_then(|u| u.join(path))
            .map_err(|_| Error::Configuration)?;
        if !parameters.is_empty() {
            url.query_pairs_mut()
                .extend_pairs(parameters.iter().map(|(k, v)| (*k, v)));
        }
        Ok(RequestSpec {
            provider,
            url,
            form: None,
            image: false,
        })
    }
    async fn json(&self, spec: RequestSpec, priority: Priority) -> Result<Reply<Value>, Error> {
        let provider = spec.provider;
        let source = spec.url.to_string();
        let result = self.scheduler.fetch(spec, priority).await?;
        if result.entry.status == 404 {
            return Err(Error::NotFound(provider));
        }
        let data = serde_json::from_slice(&result.entry.body)
            .map_err(|_| Error::InvalidResponse(provider))?;
        Ok(Reply {
            provider,
            sources: vec![source],
            cache: result.cache.into(),
            fetched_at: result.entry.stored_at,
            data,
        })
    }
    pub async fn search(
        &self,
        input: &TrackInput,
        priority: Priority,
    ) -> Result<Reply<Vec<RecordingCandidate>>, Error> {
        input.validate()?;
        let title = input
            .title
            .as_deref()
            .filter(|s| !s.trim().is_empty())
            .ok_or(Error::InvalidInput("title is required for metadata search"))?;
        let mut query = format!("recording:\"{}\"", escape_lucene(title.trim()));
        for (field, value) in [("artist", &input.artist), ("release", &input.album)] {
            if let Some(value) = value.as_ref().filter(|s| !s.trim().is_empty()) {
                query.push_str(&format!(" AND {field}:\"{}\"", escape_lucene(value.trim())));
            }
        }
        let reply = self
            .json(
                self.request(
                    Provider::Musicbrainz,
                    "/ws/2/recording/",
                    &[
                        ("fmt", "json".into()),
                        ("limit", "20".into()),
                        ("query", query),
                    ],
                )?,
                priority,
            )
            .await?;
        let records = reply
            .data
            .get("recordings")
            .and_then(Value::as_array)
            .ok_or(Error::InvalidResponse(Provider::Musicbrainz))?;
        let data = records.iter().map(candidate).collect::<Result<_, _>>()?;
        Ok(Reply {
            provider: reply.provider,
            sources: reply.sources,
            cache: reply.cache,
            fetched_at: reply.fetched_at,
            data,
        })
    }
    pub async fn recording(
        &self,
        id: &str,
        priority: Priority,
    ) -> Result<Reply<RecordingCandidate>, Error> {
        validate_id(id)?;
        let reply = self
            .json(
                self.request(
                    Provider::Musicbrainz,
                    &format!("/ws/2/recording/{id}"),
                    &[
                        ("fmt", "json".into()),
                        ("inc", "artist-credits+releases+genres".into()),
                    ],
                )?,
                priority,
            )
            .await?;
        let data = candidate(&reply.data)?;
        Ok(Reply {
            provider: reply.provider,
            sources: reply.sources,
            cache: reply.cache,
            fetched_at: reply.fetched_at,
            data,
        })
    }
    /// Complete release data includes medium positions, track numbers and edition details.
    pub async fn release(&self, id: &str, priority: Priority) -> Result<Reply<Value>, Error> {
        validate_id(id)?;
        self.json(
            self.request(
                Provider::Musicbrainz,
                &format!("/ws/2/release/{id}"),
                &[
                    ("fmt", "json".into()),
                    (
                        "inc",
                        "recordings+artist-credits+release-groups+genres".into(),
                    ),
                ],
            )?,
            priority,
        )
        .await
    }
    pub async fn lyrics(
        &self,
        input: &TrackInput,
        priority: Priority,
    ) -> Result<Reply<Value>, Error> {
        input.validate()?;
        if !input.has_lyrics_signature() {
            return Err(Error::InvalidInput(
                "lyrics require title, artist, album and duration",
            ));
        }
        let values = [
            (
                "track_name",
                input.title.as_deref().unwrap_or("").trim().into(),
            ),
            (
                "artist_name",
                input.artist.as_deref().unwrap_or("").trim().into(),
            ),
            (
                "album_name",
                input.album.as_deref().unwrap_or("").trim().into(),
            ),
            ("duration", input.duration.unwrap_or(0).to_string()),
        ];
        self.json(
            self.request(Provider::Lrclib, "/api/get", &values)?,
            priority,
        )
        .await
    }
    /// The client key is sent in a POST body, excluded from cache keys and diagnostics.
    pub async fn identify(
        &self,
        input: &TrackInput,
        priority: Priority,
    ) -> Result<Reply<Value>, Error> {
        input.validate()?;
        let fingerprint = input
            .fingerprint
            .as_deref()
            .ok_or(Error::InvalidInput("fingerprint is required"))?;
        let duration = input.duration.ok_or(Error::InvalidInput(
            "duration is required for fingerprint lookup",
        ))?;
        let client = self
            .config
            .acoustid
            .client_key
            .as_deref()
            .ok_or(Error::NotConfigured(Provider::Acoustid))?;
        let mut spec = self.request(Provider::Acoustid, "/v2/lookup", &[])?;
        spec.form = Some(vec![
            ("client".into(), client.into()),
            ("duration".into(), duration.to_string()),
            ("fingerprint".into(), fingerprint.into()),
            ("meta".into(), "recordingids".into()),
            ("format".into(), "json".into()),
        ]);
        self.json(spec, priority).await
    }
    pub(crate) async fn artwork_bytes(
        &self,
        id: &str,
        priority: Priority,
    ) -> Result<FetchResult, Error> {
        validate_id(id)?;
        let mut spec =
            self.request(Provider::CoverArt, &format!("/release/{id}/front-500"), &[])?;
        spec.image = true;
        let response = self.scheduler.fetch(spec, priority).await?;
        if response.entry.status == 404 {
            return Err(Error::NotFound(Provider::CoverArt));
        }
        Ok(response)
    }
}
pub(crate) fn validate_id(id: &str) -> Result<(), Error> {
    if id.len() != 36 || uuid::Uuid::parse_str(id).is_err() {
        return Err(Error::InvalidInput(
            "a canonical MusicBrainz UUID is required",
        ));
    }
    Ok(())
}
fn escape_lucene(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for ch in value.chars() {
        if "+-&|!(){}[]^\"~*?:\\/".contains(ch) {
            escaped.push('\\');
        }
        escaped.push(ch);
    }
    escaped
}
fn text(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}
fn candidate(record: &Value) -> Result<RecordingCandidate, Error> {
    let id = text(record, "id").ok_or(Error::InvalidResponse(Provider::Musicbrainz))?;
    validate_id(&id).map_err(|_| Error::InvalidResponse(Provider::Musicbrainz))?;
    let title = text(record, "title").ok_or(Error::InvalidResponse(Provider::Musicbrainz))?;
    let artist = record
        .get("artist-credit")
        .and_then(Value::as_array)
        .map(|credits| {
            credits
                .iter()
                .map(|credit| {
                    format!(
                        "{}{}",
                        credit
                            .get("name")
                            .or_else(|| credit.get("artist").and_then(|a| a.get("name")))
                            .and_then(Value::as_str)
                            .unwrap_or(""),
                        credit
                            .get("joinphrase")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                    )
                })
                .collect::<String>()
        })
        .unwrap_or_default();
    let releases = record
        .get("releases")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|release| {
            let id = text(release, "id")?;
            if validate_id(&id).is_err() {
                return None;
            }
            Some(ReleaseSummary {
                artwork_path: format!("/v1/artwork/{id}"),
                id,
                title: text(release, "title")?,
                date: text(release, "date"),
                country: text(release, "country"),
                disambiguation: text(release, "disambiguation"),
            })
        })
        .collect();
    let genres = record
        .get("genres")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|v| text(v, "name"))
        .collect();
    Ok(RecordingCandidate {
        id,
        title,
        artist,
        duration_ms: record.get("length").and_then(Value::as_u64),
        disambiguation: text(record, "disambiguation"),
        score: record.get("score").and_then(|v| {
            v.as_u64()
                .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
        }),
        releases,
        genres,
    })
}

/// Reject protocol errors before they can become long-lived successful cache entries.
pub(crate) fn validate_payload(provider: Provider, path: &str, value: &Value) -> Result<(), Error> {
    let invalid = || Error::InvalidResponse(provider);
    match provider {
        Provider::Musicbrainz => {
            if path.trim_end_matches('/') == "/ws/2/recording" {
                let records = value
                    .get("recordings")
                    .and_then(Value::as_array)
                    .ok_or_else(invalid)?;
                for record in records {
                    candidate(record)?;
                }
            } else if path.starts_with("/ws/2/recording/") {
                candidate(value)?;
            } else {
                let id = value
                    .get("id")
                    .and_then(Value::as_str)
                    .ok_or_else(invalid)?;
                validate_id(id).map_err(|_| invalid())?;
                if !value.get("title").is_some_and(Value::is_string)
                    || !value.get("media").is_some_and(Value::is_array)
                {
                    return Err(invalid());
                }
            }
        }
        Provider::Acoustid => {
            if value.get("status").and_then(Value::as_str) != Some("ok")
                || !value.get("results").is_some_and(Value::is_array)
            {
                return Err(invalid());
            }
        }
        Provider::Lrclib => {
            if value.get("id").and_then(Value::as_u64).is_none()
                || ["trackName", "artistName", "albumName"]
                    .iter()
                    .any(|key| !value.get(key).is_some_and(Value::is_string))
                || value
                    .get("duration")
                    .and_then(Value::as_f64)
                    .is_none_or(|d| !d.is_finite() || d < 0.0)
                || ["plainLyrics", "syncedLyrics"]
                    .iter()
                    .any(|key| !value.get(key).is_some_and(|v| v.is_string() || v.is_null()))
            {
                return Err(invalid());
            }
        }
        Provider::CoverArt => return Err(invalid()),
    }
    Ok(())
}
