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
        "failure" => (StatusCode::SERVICE_UNAVAILABLE, "{}"),
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
#[tokio::test]
async fn invalid_word_times_are_rejected_and_unicode_text_is_preserved() {
    for (mode, want) in [
        ("invalid", None),
        ("invalid_start", None),
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
