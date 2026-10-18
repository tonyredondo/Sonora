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
}

/// Must be constructed inside a Tokio runtime. Dropping the last router cancels its jobs.
pub fn router(config: Config) -> Result<Router, Error> {
    let token = config
        .server
        .api_token
        .as_ref()
        .map(|token| Arc::from(format!("Bearer {token}").into_bytes()));
    let client = Client::new(config)?;
    let metadata =
        MetadataArchive::open(&client.config().metadata).map_err(|_| Error::Configuration)?;
    let state = App {
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
        .route("/v1/jobs", post(create_job))
        .route("/v1/jobs/{id}", get(job).delete(cancel_job))
        .layer(DefaultBodyLimit::max(256 * 1024))
        .layer(middleware::from_fn_with_state(state.clone(), authorize))
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
    Json(json!({"providers":providers,"metadata_archive_version":1}))
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
        let mut response = (
            status,
            Json(json!({"error":code,"message":self.0.to_string()})),
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
