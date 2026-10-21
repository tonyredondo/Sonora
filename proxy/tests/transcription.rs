use axum::{
    Router,
    body::Body,
    extract::{Multipart, State},
    http::{Request, StatusCode},
    routing::post,
};
use sonora_proxy::config::Config;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use tempfile::TempDir;
use tokio::net::TcpListener;
use tower::ServiceExt;

fn wav(marker: u8) -> Vec<u8> {
    let mut out = b"RIFF".to_vec();
    out.extend(64036u32.to_le_bytes());
    out.extend(b"WAVEfmt ");
    out.extend(16u32.to_le_bytes());
    out.extend(1u16.to_le_bytes());
    out.extend(1u16.to_le_bytes());
    out.extend(16000u32.to_le_bytes());
    out.extend(32000u32.to_le_bytes());
    out.extend(2u16.to_le_bytes());
    out.extend(16u16.to_le_bytes());
    out.extend(b"data");
    out.extend(64000u32.to_le_bytes());
    out.resize(64044, marker);
    out
}
fn upload(audio: &[u8]) -> Request<Body> {
    let mut body = b"--test\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".to_vec();
    body.extend(audio);
    body.extend(b"\r\n--test--\r\n");
    Request::post("/v1/lyrics/transcribe")
        .header("Authorization", "Bearer fixture-token")
        .header("Content-Type", "multipart/form-data; boundary=test")
        .body(Body::from(body))
        .unwrap()
}
#[derive(Clone)]
struct Fixture {
    hits: Arc<AtomicUsize>,
    started: Arc<tokio::sync::Notify>,
    mode: &'static str,
}
async fn upstream(
    State(s): State<Fixture>,
    headers: axum::http::HeaderMap,
    mut body: Multipart,
) -> (StatusCode, &'static str) {
    let previous_hits = s.hits.fetch_add(1, Ordering::SeqCst);
    s.started.notify_one();
    assert_eq!(headers["xi-api-key"], "synthetic-eleven-key");
    let mut fields = std::collections::BTreeMap::new();
    while let Some(field) = body.next_field().await.unwrap() {
        let name = field.name().unwrap().to_owned();
        let bytes = field.bytes().await.unwrap();
        if name == "file" {
            assert!(bytes.starts_with(b"RIFF"));
        } else {
            fields.insert(name, String::from_utf8(bytes.to_vec()).unwrap());
        }
    }
    assert_eq!(
        fields,
        [
            ("model_id".into(), "scribe_v2".into()),
            ("timestamps_granularity".into(), "word".into()),
            ("tag_audio_events".into(), "false".into()),
            ("diarize".into(), "false".into())
        ]
        .into_iter()
        .collect()
    );
    tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    match s.mode {
        "not_found_once" if previous_hits == 0 => (StatusCode::NOT_FOUND, "{}"),
        "invalid_word_once" if previous_hits == 0 => (
            StatusCode::OK,
            r#"{"text":"Hello","words":[{"text":"\u0000Hello","type":"word","start":0.1,"end":0.5}]}"#,
        ),
        "failure" => (StatusCode::SERVICE_UNAVAILABLE, "{}"),
        "quota" => (
            StatusCode::TOO_MANY_REQUESTS,
            r#"{"detail":{"status":"quota_exceeded","message":"private-lyrics synthetic-eleven-key"}}"#,
        ),
        "empty" => (
            StatusCode::OK,
            r#"{"text":"","words":[],"language_code":"en"}"#,
        ),
        "invalid" => (
            StatusCode::OK,
            r#"{"text":"Hello","words":[{"text":"Hello","type":"word","start":0.1,"end":4.0}]}"#,
        ),
        "invalid_start" => (
            StatusCode::OK,
            r#"{"text":"Hello","words":[{"text":"Hello","type":"word","start":2.01,"end":2.02}]}"#,
        ),
        "reversed" => (
            StatusCode::OK,
            r#"{"text":"Hello","words":[{"text":"Hello","type":"word","start":0.5,"end":0.4}]}"#,
        ),
        "instant_words" => (
            StatusCode::OK,
            r#"{"text":"Hello. Again!","language_code":"en","words":[{"text":"Hello.","type":"word","start":0.1,"end":0.1},{"text":"Again!","type":"word","start":1.1,"end":1.1}]}"#,
        ),
        "unicode" => (
            StatusCode::OK,
            r#"{"text":"Árbol, luz! Árbol, luz!","language_code":"es","words":[{"text":"Árbol,","type":"word","start":0.1,"end":0.3},{"text":" ","type":"spacing","start":0.3,"end":0.4},{"text":"luz!","type":"word","start":0.4,"end":0.6},{"text":"Árbol,","type":"word","start":1.1,"end":1.3},{"text":"luz!","type":"word","start":1.4,"end":1.6}]}"#,
        ),
        "cjk" => (
            StatusCode::OK,
            r#"{"text":"你好世界。你好世界。","language_code":"zho","words":[{"text":"你好","type":"word","start":0.1,"end":0.3},{"text":"世界。","type":"word","start":0.4,"end":0.6},{"text":"你好","type":"word","start":1.1,"end":1.3},{"text":"世界。","type":"word","start":1.4,"end":1.6}]}"#,
        ),
        _ => (
            StatusCode::OK,
            r#"{"text":"Hello. Again!","language_code":"en","words":[{"text":"Hello.","type":"word","start":0.1,"end":0.5},{"text":" ","type":"spacing","start":0.5,"end":1.1},{"text":"Again!","type":"word","start":1.1,"end":1.5}]}"#,
        ),
    }
}
async fn setup(
    root: &TempDir,
    mode: &'static str,
) -> (Router, Config, Fixture, tokio::task::JoinHandle<()>) {
    let state = Fixture {
        hits: Arc::default(),
        started: Arc::default(),
        mode,
    };
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut config = Config::default();
    config.cache.path = root.path().join("cache.sqlite");
    config.metadata.path = root.path().join("metadata.sqlite");
    config.server.api_token = Some("fixture-token".into());
    config.elevenlabs.api_key = Some("synthetic-eleven-key".into());
    config.elevenlabs.base_url = Some(format!("http://{}", listener.local_addr().unwrap()));
    config.network.max_retries = 5;
    let upstream = Router::new()
        .route("/v1/speech-to-text", post(upstream))
        .with_state(state.clone());
    let server = tokio::spawn(async move { axum::serve(listener, upstream).await.unwrap() });
    (
        sonora_proxy::api::router(config.clone()).unwrap(),
        config,
        state,
        server,
    )
}
async fn json(response: axum::response::Response) -> serde_json::Value {
    serde_json::from_slice(
        &axum::body::to_bytes(response.into_body(), 1_000_000)
            .await
            .unwrap(),
    )
    .unwrap()
}

#[tokio::test]
async fn transcription_is_deduplicated_persisted_and_reused_after_proxy_restart() {
    let root = TempDir::new().unwrap();
    let (app, config, state, server) = setup(&root, "normal").await;
    let (a, b) = tokio::join!(
        app.clone().oneshot(upload(&wav(0))),
        app.clone().oneshot(upload(&wav(0)))
    );
    let (a, b) = (a.unwrap(), b.unwrap());
    assert_eq!(a.status(), StatusCode::OK);
    assert_eq!(b.status(), StatusCode::OK);
    let a = json(a).await;
    let b = json(b).await;
    assert_eq!(a["data"], b["data"]);
    assert_eq!(
        a["data"]["synced_lyrics"],
        "[00:00.10]Hello.\n[00:01.10]Again!"
    );
    assert_eq!(a["data"]["model_id"], "scribe_v2");
    assert_eq!(a["data"]["words"][0]["start"], 0.1);
    assert_eq!(state.hits.load(Ordering::SeqCst), 1);
    drop(app);
    server.abort();
    let app = sonora_proxy::api::router(config).unwrap();
    let cached = app.oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(cached.status(), StatusCode::OK);
    let cached = json(cached).await;
    assert_eq!(cached["cache"], "hit");
    assert_eq!(cached["data"], a["data"]);
    let bytes = std::fs::read(root.path().join("cache.sqlite")).unwrap();
    assert!(
        !bytes.windows(44).any(|w| w == &wav(0)[..44]),
        "Raw audio must not be persisted"
    );
}
#[tokio::test]
async fn zero_duration_words_are_preserved_and_cached() {
    let root = TempDir::new().unwrap();
    let (app, _, state, server) = setup(&root, "instant_words").await;
    let response = app.clone().oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let first = json(response).await;
    assert_eq!(first["data"]["plain_lyrics"], "Hello.\nAgain!");
    assert_eq!(
        first["data"]["synced_lyrics"],
        "[00:00.10]Hello.\n[00:01.10]Again!"
    );
    assert_eq!(
        first["data"]["words"],
        serde_json::json!([
            {"text":"Hello.","start":0.1,"end":0.1},
            {"text":"Again!","start":1.1,"end":1.1}
        ])
    );
    let cached = json(app.oneshot(upload(&wav(0))).await.unwrap()).await;
    assert_eq!(cached["cache"], "hit");
    assert_eq!(cached["data"], first["data"]);
    assert_eq!(state.hits.load(Ordering::SeqCst), 1);
    server.abort();
}
#[tokio::test]
async fn a_positive_legacy_transcription_cache_is_reused_without_word_details_or_payment() {
    let root = TempDir::new().unwrap();
    let (app, config, state, server) = setup(&root, "normal").await;
    assert_eq!(
        app.clone().oneshot(upload(&wav(0))).await.unwrap().status(),
        StatusCode::OK
    );
    drop(app);
    {
        let db = rusqlite::Connection::open(&config.cache.path).unwrap();
        let body: Vec<u8> = db
            .query_row("SELECT body FROM responses", [], |r| r.get(0))
            .unwrap();
        let mut legacy: serde_json::Value = serde_json::from_slice(&body).unwrap();
        legacy.as_object_mut().unwrap().remove("words");
        let encoded = serde_json::to_vec(&legacy).unwrap();
        assert_eq!(
            db.execute(
                "UPDATE responses SET body=?1, size=?2",
                rusqlite::params![encoded, encoded.len()]
            )
            .unwrap(),
            1
        );
    }
    let app = sonora_proxy::api::router(config).unwrap();
    let response = json(app.oneshot(upload(&wav(0))).await.unwrap()).await;
    assert_eq!(response["cache"], "hit");
    assert!(response["data"]["words"].is_null());
    assert_eq!(state.hits.load(Ordering::SeqCst), 1);
    server.abort();
}
#[tokio::test]
async fn silent_audio_result_is_cached_and_changed_audio_has_an_independent_key() {
    let root = TempDir::new().unwrap();
    let (app, _, state, server) = setup(&root, "empty").await;
    for marker in [0, 0, 1] {
        let response = app.clone().oneshot(upload(&wav(marker))).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(json(response).await["data"]["synced_lyrics"], "");
    }
    assert_eq!(state.hits.load(Ordering::SeqCst), 2);
    server.abort();
}
#[tokio::test]
async fn paid_not_found_is_not_cached_and_manual_retry_recovers() {
    let root = TempDir::new().unwrap();
    let (app, config, state, server) = setup(&root, "not_found_once").await;
    let failed = app.clone().oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(failed.status(), StatusCode::BAD_GATEWAY);
    assert_eq!(
        state.hits.load(Ordering::SeqCst),
        1,
        "No automatic paid retry"
    );
    let db = rusqlite::Connection::open(&config.cache.path).unwrap();
    let count: u64 = db
        .query_row("SELECT COUNT(*) FROM responses", [], |r| r.get(0))
        .unwrap();
    assert_eq!(
        count, 0,
        "Only validated audio analyses may enter the cache"
    );
    let recovered = app.clone().oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(recovered.status(), StatusCode::OK);
    let cached = app.oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(json(cached).await["cache"], "hit");
    assert_eq!(state.hits.load(Ordering::SeqCst), 2);
    server.abort();
}
#[tokio::test]
async fn legacy_negative_audio_cache_is_ignored_after_restart() {
    let root = TempDir::new().unwrap();
    let (app, config, state, server) = setup(&root, "normal").await;
    let first = app.clone().oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    drop(app);
    // Simulate a still-fresh negative record produced by the older scheduler,
    // retaining its opaque key rather than duplicating the key algorithm in this test.
    {
        let db = rusqlite::Connection::open(&config.cache.path).unwrap();
        assert_eq!(
            db.execute("UPDATE responses SET status=404, body=X'7B7D', size=2", [])
                .unwrap(),
            1
        );
    }
    let app = sonora_proxy::api::router(config).unwrap();
    let recovered = app.clone().oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(recovered.status(), StatusCode::OK);
    let cached = app.oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(json(cached).await["cache"], "hit");
    assert_eq!(state.hits.load(Ordering::SeqCst), 2);
    server.abort();
}
#[tokio::test]
async fn disconnect_after_paid_work_starts_preserves_the_flight_and_cache() {
    let root = TempDir::new().unwrap();
    let (app, _, state, server) = setup(&root, "normal").await;
    let request = tokio::spawn(app.clone().oneshot(upload(&wav(0))));
    tokio::time::timeout(std::time::Duration::from_secs(2), state.started.notified())
        .await
        .unwrap();
    request.abort();
    let result = app.clone().oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(result.status(), StatusCode::OK);
    let cached = app.oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(json(cached).await["cache"], "hit");
    assert_eq!(state.hits.load(Ordering::SeqCst), 1);
    server.abort();
}
#[tokio::test]
async fn malformed_audio_authentication_and_paid_errors_do_not_start_or_repeat_work() {
    let root = TempDir::new().unwrap();
    let (app, _, state, server) = setup(&root, "failure").await;
    let denied = app
        .clone()
        .oneshot(
            Request::post("/v1/lyrics/transcribe")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(denied.status(), StatusCode::UNAUTHORIZED);
    let bad = app.clone().oneshot(upload(&[])).await.unwrap();
    assert_eq!(bad.status(), StatusCode::BAD_REQUEST);
    assert_eq!(state.hits.load(Ordering::SeqCst), 0);
    let failed = app.oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(failed.status(), StatusCode::BAD_GATEWAY);
    assert_eq!(state.hits.load(Ordering::SeqCst), 1);
    server.abort();
}

#[derive(Clone)]
struct DiagnosticCapture(Arc<std::sync::Mutex<Vec<u8>>>);
impl std::io::Write for DiagnosticCapture {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[tokio::test]
async fn failed_transcription_logs_correlated_safe_provider_details_without_a_paid_retry() {
    let bytes = Arc::new(std::sync::Mutex::new(Vec::new()));
    let writer = DiagnosticCapture(bytes.clone());
    let subscriber = tracing_subscriber::fmt()
        .with_ansi(false)
        .without_time()
        .with_env_filter("sonora_proxy=info")
        .with_writer(move || writer.clone())
        .finish();
    tracing::subscriber::set_global_default(subscriber).unwrap();
    let root = TempDir::new().unwrap();
    let (app, _, state, server) = setup(&root, "quota").await;
    let id = "b0b3276b-6850-49c2-858a-8f1ae4976b25";
    let mut request = upload(&wav(0));
    request
        .headers_mut()
        .insert("x-sonora-request-id", id.parse().unwrap());
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
    assert_eq!(response.headers().get("x-sonora-request-id").unwrap(), id);
    let body = json(response).await;
    assert_eq!(body["provider"], "elevenlabs");
    assert_eq!(body["upstream_status"], 429);
    assert_eq!(body["reason"], "quota_exceeded");
    assert_eq!(state.hits.load(Ordering::SeqCst), 1);
    let invalid_root = TempDir::new().unwrap();
    let (invalid_app, _, _, invalid_server) = setup(&invalid_root, "invalid").await;
    let invalid_result = invalid_app.oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(invalid_result.status(), StatusCode::BAD_GATEWAY);
    invalid_server.abort();
    let log = String::from_utf8(bytes.lock().unwrap().clone()).unwrap();
    assert!(
        log.contains("transcription_word_timing") && log.contains("word_index=0"),
        "{log}"
    );
    assert!(
        log.contains(id) && log.contains("quota_exceeded") && log.contains("429"),
        "{log}"
    );
    for private in [
        "private-lyrics",
        "synthetic-eleven-key",
        "fixture-token",
        "RIFF",
        "Hello",
    ] {
        assert!(!log.contains(private), "{log}");
        assert!(!body.to_string().contains(private));
    }
    server.abort();
}

#[tokio::test]
async fn rejected_authentication_also_has_a_safe_request_reference() {
    let root = TempDir::new().unwrap();
    let (app, _, state, server) = setup(&root, "failure").await;
    let request = Request::get("/v1/status?token=private-query")
        .header("x-sonora-request-id", "private-invalid-reference")
        .body(Body::empty())
        .unwrap();
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let id = response
        .headers()
        .get("x-sonora-request-id")
        .unwrap()
        .to_str()
        .unwrap();
    assert!(uuid::Uuid::parse_str(id).is_ok());
    assert_ne!(id, "private-invalid-reference");
    assert_eq!(state.hits.load(Ordering::SeqCst), 0);
    server.abort();
}

#[tokio::test]
async fn connection_failure_keeps_its_transport_cause_without_disclosing_the_url() {
    let root = TempDir::new().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    let mut config = Config::default();
    config.cache.path = root.path().join("cache.sqlite");
    config.metadata.path = root.path().join("metadata.sqlite");
    config.server.api_token = Some("fixture-token".into());
    config.elevenlabs.api_key = Some("synthetic-eleven-key".into());
    config.elevenlabs.base_url = Some(format!("http://{address}"));
    let app = sonora_proxy::api::router(config).unwrap();
    let response = app.oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
    let body = json(response).await;
    assert_eq!(body["reason"], "upstream_connect");
    assert_eq!(body["provider"], "elevenlabs");
    assert!(body["upstream_status"].is_null());
    for private in [
        address.to_string(),
        "synthetic-eleven-key".into(),
        "fixture-token".into(),
    ] {
        assert!(!body.to_string().contains(&private));
    }
}
#[tokio::test]
async fn invalid_word_times_are_rejected_and_unicode_text_is_preserved() {
    for (mode, want) in [
        ("invalid", None),
        ("invalid_start", None),
        ("reversed", None),
        (
            "unicode",
            Some("[00:00.10]Árbol, luz!\n[00:01.10]Árbol, luz!"),
        ),
        ("cjk", Some("[00:00.10]你好世界。\n[00:01.10]你好世界。")),
    ] {
        let root = TempDir::new().unwrap();
        let (app, _, _, server) = setup(&root, mode).await;
        let response = app.oneshot(upload(&wav(0))).await.unwrap();
        if let Some(want) = want {
            assert_eq!(response.status(), StatusCode::OK);
            assert_eq!(json(response).await["data"]["synced_lyrics"], want);
        } else {
            assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
        }
        server.abort();
    }
}

#[tokio::test]
async fn invalid_retained_words_are_not_cached_and_explicit_retry_recovers() {
    let root = TempDir::new().unwrap();
    let (app, _, state, server) = setup(&root, "invalid_word_once").await;
    let first = app.clone().oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(first.status(), StatusCode::BAD_GATEWAY);
    assert_eq!(state.hits.load(Ordering::SeqCst), 1);
    let recovered = app.clone().oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(recovered.status(), StatusCode::OK);
    let saved = app.oneshot(upload(&wav(0))).await.unwrap();
    assert_eq!(saved.status(), StatusCode::OK);
    assert_eq!(
        state.hits.load(Ordering::SeqCst),
        2,
        "One explicit retry, then a reusable cache hit"
    );
    server.abort();
}
