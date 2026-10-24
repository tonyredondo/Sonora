//! Versioned provider and opt-in alignment API and asynchronous lookup jobs.

use crate::{
    config::{Config, Provider},
    jobs::{BatchInput, Jobs},
    metadata_archive::{ArchiveError, MetadataArchive, MetadataRecord},
    providers::{Client, Error, Priority, TrackInput},
};
use axum::{
    Json, Router,
    body::Body,
    extract::{DefaultBodyLimit, Multipart, Path, Query, State},
    http::{Request, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde_json::json;
use std::sync::Arc;
use subtle::ConstantTimeEq;
use uuid::Uuid;

#[derive(Clone)]
struct App {
    client: Client,
    jobs: Jobs,
    token: Option<Arc<[u8]>>,
    uploads: Arc<tokio::sync::Semaphore>,
    metadata: MetadataArchive,
    interpretation: crate::interpretation::InterpretationService,
    artwork_jobs: crate::artwork_jobs::ArtworkJobs,
    character: crate::audio_character::CharacterService,
    character_uploads: Arc<tokio::sync::Semaphore>,
}

/// Must be constructed inside a Tokio runtime. Accepted artwork tasks outlive HTTP callers;
/// unfinished artwork can be recovered from disk after a server restart.
pub fn router(config: Config) -> Result<Router, Error> {
    let token = config
        .server
        .api_token
        .as_ref()
        .map(|token| Arc::from(format!("Bearer {token}").into_bytes()));
    let client = Client::new(config)?;
    let metadata =
        MetadataArchive::open(&client.config().metadata).map_err(|_| Error::Configuration)?;
    let interpretation = crate::interpretation::InterpretationService::new(
        client.config().codex.clone(),
        client.scheduler.cache(),
    );
    let state = App {
        character_uploads: Arc::new(tokio::sync::Semaphore::new(8)),
        character: crate::audio_character::CharacterService::new(
            client.config().audio_character.clone(),
            client.scheduler.cache(),
        ),
        artwork_jobs: crate::artwork_jobs::ArtworkJobs::new(
            interpretation.clone(),
            client.scheduler.cache(),
            client.config().codex.enabled,
            client.config().server.max_jobs,
        ),
        interpretation,
        metadata,
        jobs: Jobs::new(client.clone()),
        uploads: Arc::new(tokio::sync::Semaphore::new(4)),
        client,
        token,
    };
    Ok(Router::new()
        .route(
            "/health",
            get(|| async { Json(json!({"status":"ok","version":env!("CARGO_PKG_VERSION")})) }),
        )
        .route("/v1/recordings", get(search))
        .route("/v1/status", get(status))
        .route(
            "/v1/audio/character",
            post(analyze_character)
                .layer(DefaultBodyLimit::max(crate::audio_character::MAX_BYTES))
                .layer(middleware::from_fn_with_state(
                    state.clone(),
                    character_admission,
                )),
        )
        .route("/v1/audio/{audio_id}/metadata", get(metadata_copies))
        .route(
            "/v1/metadata-records/{id}",
            get(metadata_copy)
                .put(save_metadata_copy)
                .layer(DefaultBodyLimit::max(
                    crate::metadata_archive::MAX_RECORD_BYTES,
                )),
        )
        .route("/v1/recordings/{id}", get(recording))
        .route("/v1/releases/{id}", get(release))
        .route("/v1/lyrics", get(lyrics))
        .route(
            "/v1/albums/interpret",
            post(interpret_album).layer(DefaultBodyLimit::max(2 * 1024 * 1024)),
        )
        .route(
            "/v1/lyrics/interpret",
            post(interpret).layer(DefaultBodyLimit::max(128 * 1024)),
        )
        .route(
            "/v1/lyrics/translate",
            post(translate).layer(DefaultBodyLimit::max(256 * 1024)),
        )
        .route(
            "/v1/lyrics/align",
            post(align).layer(DefaultBodyLimit::max(
                crate::alignment::MAX_AUDIO_BYTES + crate::alignment::MAX_TEXT_BYTES + 4096,
            )),
        )
        .route(
            "/v1/lyrics/transcribe",
            post(transcribe).layer(DefaultBodyLimit::max(
                crate::alignment::MAX_AUDIO_BYTES + 4096,
            )),
        )
        .route("/v1/identify", post(identify))
        .route("/v1/artwork/{id}", get(artwork))
        .route(
            "/v1/artwork/jobs",
            post(create_artwork_job).layer(DefaultBodyLimit::max(64 * 1024)),
        )
        .route("/v1/artwork/jobs/{id}", get(artwork_job))
        .route("/v1/artwork/jobs/{id}/image", get(artwork_job_image))
        .route(
            "/v1/artwork/generate",
            post(generate_artwork).layer(DefaultBodyLimit::max(64 * 1024)),
        )
        .route("/v1/jobs", post(create_job))
        .route("/v1/jobs/{id}", get(job).delete(cancel_job))
        .layer(DefaultBodyLimit::max(256 * 1024))
        .layer(middleware::from_fn_with_state(state.clone(), authorize))
        .layer(middleware::from_fn(crate::diagnostics::request))
        .with_state(state))
}

async fn status(State(app): State<App>) -> Json<serde_json::Value> {
    let providers: serde_json::Map<String, serde_json::Value> = Provider::ALL
        .into_iter()
        .map(|provider| {
            let settings = app.client.config().provider(provider);
            let configured = match provider {
                Provider::Acoustid => settings.client_key.is_some(),
                Provider::Elevenlabs => settings.api_key.is_some(),
                _ => true,
            };
            (
                provider.name().to_owned(),
                json!({"enabled":settings.enabled,"configured":configured}),
            )
        })
        .collect();
    Json(json!({"providers":providers,"metadata_archive_version":1,
        "generated_artwork":{"enabled":app.client.config().codex.enabled,"version":1,"jobs_version":1},
        "audio_character":{"enabled":app.client.config().audio_character.enabled,"version":crate::audio_character::VERSION},
        "lyric_translation":{"enabled":app.client.config().codex.enabled,"version":1,"model":crate::translation::MODEL,"effort":crate::translation::EFFORT},
        "album_interpretation":{"enabled":app.client.config().codex.enabled,"version":crate::album_interpretation::VERSION},
        "lyric_interpretation":{"enabled":app.client.config().codex.enabled,"model":crate::interpretation::MODEL,"effort":crate::interpretation::EFFORT}}))
}

async fn generate_artwork(
    State(app): State<App>,
    Json(input): Json<crate::generated_artwork::ArtworkInput>,
) -> Result<Response, crate::interpretation::InterpretationError> {
    let image = app.interpretation.generate_artwork(input).await?;
    Ok((
        [
            (header::CONTENT_TYPE, "image/png"),
            (header::CACHE_CONTROL, "private, no-store"),
        ],
        image,
    )
        .into_response())
}

#[derive(Default, serde::Deserialize)]
struct ArtworkJobOptions {
    #[serde(default)]
    retry_failed: bool,
}
async fn create_artwork_job(
    State(app): State<App>,
    Query(options): Query<ArtworkJobOptions>,
    Json(input): Json<crate::generated_artwork::ArtworkInput>,
) -> Result<impl IntoResponse, crate::artwork_jobs::JobError> {
    Ok((
        StatusCode::ACCEPTED,
        Json(app.artwork_jobs.create(input, options.retry_failed).await?),
    ))
}
async fn artwork_job(
    State(app): State<App>,
    Path(id): Path<String>,
) -> Result<impl IntoResponse, crate::artwork_jobs::JobError> {
    Ok(Json(app.artwork_jobs.snapshot(&id).await?))
}
async fn artwork_job_image(
    State(app): State<App>,
    Path(id): Path<String>,
) -> Result<impl IntoResponse, crate::artwork_jobs::JobError> {
    Ok((
        [
            (header::CONTENT_TYPE, "image/png"),
            (header::CACHE_CONTROL, "private, no-store"),
        ],
        app.artwork_jobs.image(&id).await?,
    ))
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct CharacterParams {
    #[serde(default)]
    refresh: bool,
}
async fn character_admission(
    State(app): State<App>,
    request: Request<Body>,
    next: Next,
) -> Response {
    // Reserve before extracting a body, so slow or concurrent uploads cannot
    // allocate unbounded 3 MB buffers while the model is busy.
    let Ok(_permit) = app.character_uploads.try_acquire() else {
        return crate::audio_character::CharacterError::Busy.into_response();
    };
    match tokio::time::timeout(std::time::Duration::from_secs(110), next.run(request)).await {
        Ok(response) => response,
        Err(_) => crate::audio_character::CharacterError::Timeout.into_response(),
    }
}
async fn analyze_character(
    State(app): State<App>,
    Query(params): Query<CharacterParams>,
    audio: bytes::Bytes,
) -> Result<Json<crate::audio_character::Character>, crate::audio_character::CharacterError> {
    Ok(Json(app.character.analyze(audio, params.refresh).await?))
}

async fn translate(
    State(app): State<App>,
    Json(input): Json<crate::translation::TranslationInput>,
) -> Result<Json<crate::translation::Translation>, crate::interpretation::InterpretationError> {
    Ok(Json(app.interpretation.translate(input).await?))
}

async fn interpret_album(
    State(app): State<App>,
    Json(input): Json<crate::album_interpretation::AlbumInput>,
) -> Result<Json<crate::interpretation::Interpretation>, crate::interpretation::InterpretationError>
{
    Ok(Json(app.interpretation.interpret_album(input).await?))
}

async fn interpret(
    State(app): State<App>,
    Json(input): Json<crate::interpretation::InterpretationInput>,
) -> Result<Json<crate::interpretation::Interpretation>, crate::interpretation::InterpretationError>
{
    Ok(Json(app.interpretation.interpret(input).await?))
}

impl IntoResponse for ArchiveError {
    fn into_response(self) -> Response {
        let (status, code) = match self {
            Self::Invalid => (StatusCode::BAD_REQUEST, "invalid_metadata"),
            Self::Conflict => (StatusCode::CONFLICT, "metadata_conflict"),
            Self::Full => (StatusCode::INSUFFICIENT_STORAGE, "metadata_storage_full"),
            Self::Storage => (
                StatusCode::SERVICE_UNAVAILABLE,
                "metadata_storage_unavailable",
            ),
        };
        tracing::warn!(
            error_code = code,
            http_status = status.as_u16(),
            "metadata archive request failed"
        );
        (
            status,
            Json(json!({"error":code,"message":self.to_string()})),
        )
            .into_response()
    }
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct MetadataPageInput {
    before: Option<i64>,
}
async fn metadata_copies(
    State(app): State<App>,
    Path(audio_id): Path<String>,
    Query(query): Query<MetadataPageInput>,
) -> Result<impl IntoResponse, ArchiveError> {
    Ok(Json(app.metadata.list(audio_id, query.before).await?))
}
async fn metadata_copy(
    State(app): State<App>,
    Path(id): Path<Uuid>,
) -> Result<Response, ArchiveError> {
    Ok(match app.metadata.get(id).await? {
        Some(record) => Json(record).into_response(),
        None => (
            StatusCode::NOT_FOUND,
            Json(json!({"error":"metadata_not_found"})),
        )
            .into_response(),
    })
}
async fn save_metadata_copy(
    State(app): State<App>,
    Path(id): Path<Uuid>,
    Json(record): Json<MetadataRecord>,
) -> Result<impl IntoResponse, ArchiveError> {
    if id != record.id {
        return Err(ArchiveError::Invalid);
    }
    let created = app.metadata.put(record).await?;
    Ok((
        if created {
            StatusCode::CREATED
        } else {
            StatusCode::OK
        },
        Json(json!({"id":id})),
    ))
}
async fn authorize(State(app): State<App>, request: Request<Body>, next: Next) -> Response {
    if request.uri().path() != "/health" {
        if let Some(expected) = &app.token {
            let supplied = request
                .headers()
                .get(header::AUTHORIZATION)
                .map(|h| h.as_bytes())
                .unwrap_or_default();
            if !bool::from(supplied.ct_eq(expected)) {
                return (
                    StatusCode::UNAUTHORIZED,
                    [(header::WWW_AUTHENTICATE, "Bearer")],
                    Json(json!({"error":"unauthorized"})),
                )
                    .into_response();
            }
        }
    }
    let mut response = next.run(request).await;
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("no-store"),
    );
    response
}
pub struct ApiError(Error);
impl From<Error> for ApiError {
    fn from(e: Error) -> Self {
        Self(e)
    }
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, code) = match self.0 {
            Error::InvalidInput(_) => (StatusCode::BAD_REQUEST, "invalid_input"),
            Error::UploadTooLarge => (StatusCode::PAYLOAD_TOO_LARGE, "too_large"),
            Error::QueueFull => (StatusCode::TOO_MANY_REQUESTS, "queue_full"),
            Error::Deadline => (StatusCode::GATEWAY_TIMEOUT, "deadline_exceeded"),
            Error::NotFound(_) => (StatusCode::NOT_FOUND, "not_found"),
            Error::Disabled(_) | Error::NotConfigured(_) => {
                (StatusCode::SERVICE_UNAVAILABLE, "provider_unavailable")
            }
            Error::Cache | Error::Configuration | Error::Unavailable => {
                (StatusCode::SERVICE_UNAVAILABLE, "service_unavailable")
            }
            _ => (StatusCode::BAD_GATEWAY, "upstream_error"),
        };
        let (provider, upstream_status, reason) = self.0.diagnostic();
        tracing::warn!(error_code = code, provider, upstream_status, reason, error = %self.0, "provider operation failed");
        let mut response = (
            status,
            Json(json!({"error":code,"message":self.0.to_string(),"provider":provider,"upstream_status":upstream_status,"reason":reason})),
        )
            .into_response();
        if status == StatusCode::TOO_MANY_REQUESTS {
            response.headers_mut().insert(
                header::RETRY_AFTER,
                axum::http::HeaderValue::from_static("1"),
            );
        }
        response
    }
}
async fn search(
    State(app): State<App>,
    Query(input): Query<TrackInput>,
) -> Result<impl IntoResponse, ApiError> {
    Ok(Json(
        app.client.search(&input, Priority::Interactive).await?,
    ))
}
async fn recording(
    State(app): State<App>,
    Path(id): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    Ok(Json(
        app.client.recording(&id, Priority::Interactive).await?,
    ))
}
async fn release(
    State(app): State<App>,
    Path(id): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    Ok(Json(app.client.release(&id, Priority::Interactive).await?))
}
async fn lyrics(
    State(app): State<App>,
    Query(input): Query<TrackInput>,
) -> Result<impl IntoResponse, ApiError> {
    Ok(Json(
        app.client.lyrics(&input, Priority::Interactive).await?,
    ))
}
async fn identify(
    State(app): State<App>,
    Json(input): Json<TrackInput>,
) -> Result<impl IntoResponse, ApiError> {
    Ok(Json(
        app.client.identify(&input, Priority::Interactive).await?,
    ))
}
async fn artwork(
    State(app): State<App>,
    Path(id): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    let reply = app.client.artwork_bytes(&id, Priority::Interactive).await?;
    let mime = reply
        .entry
        .headers
        .content_type
        .as_deref()
        .unwrap_or("application/octet-stream");
    Ok((
        [
            ("Content-Type", mime.to_owned()),
            ("X-Sonora-Cache", reply.cache.to_owned()),
        ],
        reply.entry.body.clone(),
    ))
}
async fn create_job(
    State(app): State<App>,
    Json(input): Json<BatchInput>,
) -> Result<impl IntoResponse, ApiError> {
    let snapshot = app.jobs.create(input)?;
    Ok((
        StatusCode::ACCEPTED,
        [(header::LOCATION, format!("/v1/jobs/{}", snapshot.id))],
        Json(snapshot),
    ))
}
async fn job(State(app): State<App>, Path(id): Path<Uuid>) -> Result<Response, ApiError> {
    Ok(match app.jobs.snapshot(id)? {
        Some(snapshot) => Json(snapshot).into_response(),
        None => (
            StatusCode::NOT_FOUND,
            Json(json!({"error":"job_not_found"})),
        )
            .into_response(),
    })
}
async fn cancel_job(State(app): State<App>, Path(id): Path<Uuid>) -> Result<Response, ApiError> {
    Ok(match app.jobs.cancel(id)? {
        Some(snapshot) => Json(snapshot).into_response(),
        None => (
            StatusCode::NOT_FOUND,
            Json(json!({"error":"job_not_found"})),
        )
            .into_response(),
    })
}

/// Authentication runs before extraction; limit concurrent buffered audio uploads as well as the provider queue.
async fn align(
    State(app): State<App>,
    multipart: Multipart,
) -> Result<impl IntoResponse, ApiError> {
    let _permit = app.uploads.try_acquire().map_err(|_| Error::QueueFull)?;
    let (audio, text) = read_audio_upload(multipart, true).await?;
    Ok(Json(
        app.client
            .align(
                audio,
                text.ok_or(Error::InvalidInput("text is required"))?,
                Priority::Interactive,
            )
            .await?,
    ))
}
async fn transcribe(
    State(app): State<App>,
    multipart: Multipart,
) -> Result<impl IntoResponse, ApiError> {
    let _permit = app.uploads.try_acquire().map_err(|_| Error::QueueFull)?;
    let (audio, _) = read_audio_upload(multipart, false).await?;
    Ok(Json(
        app.client.transcribe(audio, Priority::Interactive).await?,
    ))
}
async fn read_audio_upload(
    mut multipart: Multipart,
    require_text: bool,
) -> Result<(bytes::Bytes, Option<String>), ApiError> {
    let mut audio = None;
    let mut text = None;
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|_| Error::InvalidInput("invalid multipart upload"))?
    {
        let name = field.name().unwrap_or("").to_owned();
        let limit = match name.as_str() {
            "file" if audio.is_none() => crate::alignment::MAX_AUDIO_BYTES,
            "text" if require_text && text.is_none() => crate::alignment::MAX_TEXT_BYTES,
            _ => return Err(Error::InvalidInput("unexpected or duplicate multipart field").into()),
        };
        let data = field.bytes().await.map_err(|_| Error::UploadTooLarge)?;
        if data.len() > limit {
            return Err(Error::UploadTooLarge.into());
        }
        if name == "file" {
            audio = Some(data);
        } else {
            text = Some(
                String::from_utf8(data.to_vec())
                    .map_err(|_| Error::InvalidInput("text must be UTF-8"))?,
            );
        }
    }
    Ok((audio.ok_or(Error::InvalidInput("file is required"))?, text))
}
