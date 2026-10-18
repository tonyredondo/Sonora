use axum::{
    Router,
    body::Body,
    extract::{Multipart, State},
    http::StatusCode,
    routing::post,
};
use sonora_proxy::{
    config::Config,
    providers::{Client, Priority},
};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use tempfile::TempDir;
use tokio::net::TcpListener;

fn wav(seconds: usize) -> Vec<u8> {
    let size = seconds * 32000;
    let mut out = Vec::new();
    out.extend(b"RIFF");
    out.extend(((size + 36) as u32).to_le_bytes());
    out.extend(b"WAVEfmt ");
    out.extend(16u32.to_le_bytes());
    out.extend(1u16.to_le_bytes());
    out.extend(1u16.to_le_bytes());
    out.extend(16000u32.to_le_bytes());
    out.extend(32000u32.to_le_bytes());
    out.extend(2u16.to_le_bytes());
    out.extend(16u16.to_le_bytes());
    out.extend(b"data");
    out.extend((size as u32).to_le_bytes());
    out.resize(44 + size, 0);
    out
}

#[derive(Clone)]
struct Fixture {
    hits: Arc<AtomicUsize>,
    fail: bool,
}
async fn respond(
    State(s): State<Fixture>,
    headers: axum::http::HeaderMap,
    mut body: Multipart,
) -> (StatusCode, Body) {
    s.hits.fetch_add(1, Ordering::SeqCst);
    assert_eq!(headers["xi-api-key"], "synthetic-eleven-key");
    let mut names = Vec::new();
    while let Some(field) = body.next_field().await.unwrap() {
        let name = field.name().unwrap().to_owned();
        let data = field.bytes().await.unwrap();
        if name == "file" {
            assert!(data.starts_with(b"RIFF"));
        }
        if name == "text" {
            assert_eq!(data, "Árbol, luz!\nÁrbol, luz!");
        }
        names.push(name);
    }
    names.sort();
    assert_eq!(names, ["file", "text"]);
    if s.fail {
        return (StatusCode::SERVICE_UNAVAILABLE, Body::empty());
    }
    (
        StatusCode::OK,
        Body::from(
            r#"{"words":[{"text":"Árbol,","start":0.1,"end":0.3},{"text":"luz!","start":0.4,"end":0.5},{"text":"Árbol,","start":1.1,"end":1.3},{"text":"luz!","start":1.4,"end":1.5}],"loss":0.2}"#,
        ),
    )
}

#[tokio::test]
async fn aligns_preserving_unicode_and_repeated_lines_deduplicates_and_reuses_disk_cache() {
    let root = TempDir::new().unwrap();
    let state = Fixture {
        hits: Arc::default(),
        fail: false,
    };
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut config = Config::default();
    config.cache.path = root.path().join("cache.sqlite");
    config.metadata.path = root.path().join("metadata.sqlite");
    config.elevenlabs.base_url = Some(format!("http://{}", listener.local_addr().unwrap()));
    config.elevenlabs.api_key = Some("synthetic-eleven-key".into());
    let app = Router::new()
        .route("/v1/forced-alignment", post(respond))
        .with_state(state.clone());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let client = Client::new(config.clone()).unwrap();
    let (a, b) = tokio::join!(
        client.align(
            wav(2).into(),
            "Árbol, luz!\nÁrbol, luz!".into(),
            Priority::Interactive
        ),
        client.align(
            wav(2).into(),
            "Árbol, luz!\nÁrbol, luz!".into(),
            Priority::Interactive
        )
    );
    let a = a.unwrap();
    let b = b.unwrap();
    assert_eq!(
        a.data.synced_lyrics,
        "[00:00.10]Árbol, luz!\n[00:01.10]Árbol, luz!"
    );
    assert_eq!(a.data, b.data);
    assert_eq!(state.hits.load(Ordering::SeqCst), 1);
    drop(client);
    // A new process/client must reuse persistent results without provider availability.
    server.abort();
    let next = Client::new(config)
        .unwrap()
        .align(
            wav(2).into(),
            "Árbol, luz!\nÁrbol, luz!".into(),
            Priority::Interactive,
        )
        .await
        .unwrap();
    assert_eq!(next.cache, "hit");
    assert_eq!(next.data, a.data);
}

#[tokio::test]
async fn ambiguous_paid_errors_are_not_automatically_retried_and_invalid_audio_is_rejected() {
    let root = TempDir::new().unwrap();
    let state = Fixture {
        hits: Arc::default(),
        fail: true,
    };
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut config = Config::default();
    config.cache.path = root.path().join("cache.sqlite");
    config.metadata.path = root.path().join("metadata.sqlite");
    config.elevenlabs.base_url = Some(format!("http://{}", listener.local_addr().unwrap()));
    config.elevenlabs.api_key = Some("synthetic-eleven-key".into());
    config.network.max_retries = 5;
    let app = Router::new()
        .route("/v1/forced-alignment", post(respond))
        .with_state(state.clone());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let client = Client::new(config).unwrap();
    assert!(
        client
            .align(
                Vec::new().into(),
                "Árbol, luz!\nÁrbol, luz!".into(),
                Priority::Interactive
            )
            .await
            .is_err()
    );
    assert_eq!(state.hits.load(Ordering::SeqCst), 0);
    assert!(
        client
            .align(
                wav(2).into(),
                "Árbol, luz!\nÁrbol, luz!".into(),
                Priority::Interactive
            )
            .await
            .is_err()
    );
    assert_eq!(state.hits.load(Ordering::SeqCst), 1);
    server.abort();
}

#[tokio::test]
async fn route_requires_authentication_and_valid_complete_multipart_without_using_provider() {
    use axum::http::Request;
    use tower::ServiceExt;
    let root = TempDir::new().unwrap();
    let mut config = Config::default();
    config.cache.path = root.path().join("cache.sqlite");
    config.metadata.path = root.path().join("metadata.sqlite");
    config.server.api_token = Some("synthetic-proxy-token".into());
    let app = sonora_proxy::api::router(config).unwrap();
    let response = app
        .clone()
        .oneshot(
            Request::post("/v1/lyrics/align")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let response = app
        .clone()
        .oneshot(
            Request::get("/v1/status")
                .header("Authorization", "Bearer synthetic-proxy-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let body = axum::body::to_bytes(response.into_body(), 10000)
        .await
        .unwrap();
    let status: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(status["providers"]["elevenlabs"]["configured"], false);
    let response = app.oneshot(Request::post("/v1/lyrics/align").header("Authorization", "Bearer synthetic-proxy-token").header("Content-Type", "multipart/form-data; boundary=synthetic").body(Body::from("--synthetic\r\nContent-Disposition: form-data; name=\"text\"\r\n\r\nHello\r\n--synthetic--\r\n")).unwrap()).await.unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn disconnect_during_paid_work_still_caches_and_reconnect_shares_request() {
    use tokio::sync::Notify;
    #[derive(Clone)]
    struct Slow {
        started: Arc<Notify>,
        finish: Arc<Notify>,
        hits: Arc<AtomicUsize>,
    }
    async fn slow(State(s): State<Slow>) -> &'static str {
        s.hits.fetch_add(1, Ordering::SeqCst);
        s.started.notify_one();
        s.finish.notified().await;
        r#"{"words":[{"text":"Hello","start":0.1,"end":0.5}]}"#
    }
    let root = TempDir::new().unwrap();
    let state = Slow {
        started: Arc::default(),
        finish: Arc::default(),
        hits: Arc::default(),
    };
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut config = Config::default();
    config.cache.path = root.path().join("cache.sqlite");
    config.metadata.path = root.path().join("metadata.sqlite");
    config.elevenlabs.api_key = Some("synthetic".into());
    config.elevenlabs.base_url = Some(format!("http://{}", listener.local_addr().unwrap()));
    let app = Router::new()
        .route("/v1/forced-alignment", post(slow))
        .with_state(state.clone());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let client = Client::new(config).unwrap();
    let first = client.clone();
    let task = tokio::spawn(async move {
        first
            .align(wav(2).into(), "Hello".into(), Priority::Interactive)
            .await
    });
    tokio::time::timeout(std::time::Duration::from_secs(2), state.started.notified())
        .await
        .unwrap();
    task.abort();
    let _ = task.await;
    let second = client.clone();
    let reconnect = tokio::spawn(async move {
        second
            .align(wav(2).into(), "Hello".into(), Priority::Interactive)
            .await
    });
    state.finish.notify_one();
    let result = tokio::time::timeout(std::time::Duration::from_secs(2), reconnect)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(result.data.plain_lyrics, "Hello");
    assert_eq!(state.hits.load(Ordering::SeqCst), 1);
    let cached = client
        .align(wav(2).into(), "Hello".into(), Priority::Interactive)
        .await
        .unwrap();
    assert_eq!(cached.cache, "hit");
    server.abort();
}

#[tokio::test]
async fn missing_key_and_oversized_upload_are_explicit_and_never_start_paid_work() {
    use axum::http::Request;
    use sonora_proxy::config::Provider;
    use sonora_proxy::providers::Error;
    use tower::ServiceExt;
    let root = TempDir::new().unwrap();
    let mut config = Config::default();
    config.cache.path = root.path().join("cache.sqlite");
    config.metadata.path = root.path().join("metadata.sqlite");
    let client = Client::new(config.clone()).unwrap();
    assert!(matches!(
        client
            .align(wav(2).into(), "Hello".into(), Priority::Interactive)
            .await,
        Err(Error::NotConfigured(Provider::Elevenlabs))
    ));
    drop(client);
    let app = sonora_proxy::api::router(config).unwrap();
    let mut body =
        b"--test\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n\r\n"
            .to_vec();
    body.resize(body.len() + sonora_proxy::alignment::MAX_AUDIO_BYTES + 1, 0);
    body.extend(b"\r\n--test--\r\n");
    let response = app
        .oneshot(
            Request::post("/v1/lyrics/align")
                .header("Content-Type", "multipart/form-data; boundary=test")
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
}

#[tokio::test]
async fn oversized_provider_response_keeps_existing_bad_gateway_contract() {
    use axum::{http::Request, routing::get};
    use tower::ServiceExt;
    let root = TempDir::new().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut config = Config::default();
    config.cache.path = root.path().join("cache.sqlite");
    config.metadata.path = root.path().join("metadata.sqlite");
    config.cover_art.base_url = Some(format!("http://{}", listener.local_addr().unwrap()));
    config.network.max_response_bytes = 1024;
    let upstream = Router::new().fallback(get(|| async { vec![0u8; 2048] }));
    let server = tokio::spawn(async move { axum::serve(listener, upstream).await.unwrap() });
    let app = sonora_proxy::api::router(config).unwrap();
    let response = app
        .oneshot(
            Request::get("/v1/artwork/11111111-1111-4111-8111-111111111111")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::BAD_GATEWAY,
        "413 is reserved for client uploads, not oversized upstream replies"
    );
    server.abort();
}
