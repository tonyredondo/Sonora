//! Correlate failures without recording URLs, headers, request bodies or music tags.

use axum::{
    body::Body,
    extract::MatchedPath,
    http::{HeaderValue, Request},
    middleware::Next,
    response::Response,
};
use std::time::Instant;
use tracing::Instrument;
use uuid::Uuid;

pub(crate) async fn request(request: Request<Body>, next: Next) -> Response {
    let id = request
        .headers()
        .get("x-sonora-request-id")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| Uuid::parse_str(value).ok())
        .unwrap_or_else(Uuid::new_v4)
        .to_string();
    let route = request
        .extensions()
        .get::<MatchedPath>()
        .map(|path| path.as_str().to_owned())
        .unwrap_or_else(|| "unmatched".into());
    let method = match request.method().as_str() {
        "GET" => "GET",
        "POST" => "POST",
        "PUT" => "PUT",
        "DELETE" => "DELETE",
        "HEAD" => "HEAD",
        "OPTIONS" => "OPTIONS",
        "PATCH" => "PATCH",
        _ => "OTHER",
    };
    let span = tracing::info_span!("http_request", request_id = %id, method, route = %route);
    async move {
        let started = Instant::now();
        if matches!(route.as_str(), "/v1/lyrics/align" | "/v1/lyrics/transcribe") {
            tracing::info!("audio analysis request started");
        }
        let mut response = next.run(request).await;
        if let Ok(value) = HeaderValue::from_str(&id) {
            response.headers_mut().insert("x-sonora-request-id", value);
        }
        if response.status().is_client_error() || response.status().is_server_error() {
            tracing::warn!(
                http_status = response.status().as_u16(),
                elapsed_ms = started.elapsed().as_millis() as u64,
                "HTTP request failed"
            );
        }
        response
    }
    .instrument(span)
    .await
}
