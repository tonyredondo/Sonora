use axum::{Router, body::Body, extract::State, http::HeaderMap, response::Response};
use serde_json::json;
use sonora_proxy::{
    config::Config,
    providers::{Client, Priority, TrackInput},
};
use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};
use tempfile::TempDir;
use tokio::{net::TcpListener, task::JoinHandle};

#[derive(Clone)]
struct Upstream {
    hits: Arc<AtomicUsize>,
    requests: Arc<Mutex<Vec<(Instant, String, HeaderMap)>>>,
    mode: &'static str,
}

async fn respond(State(state): State<Upstream>, request: axum::extract::Request) -> Response {
    let index = state.hits.fetch_add(1, Ordering::SeqCst);
    state.requests.lock().unwrap().push((
        Instant::now(),
        request.uri().to_string(),
        request.headers().clone(),
    ));
    if state.mode == "slow" {
        tokio::time::sleep(Duration::from_millis(150)).await;
    }
    if state.mode == "hang" {
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
    if state.mode == "oversized" {
        return Response::builder()
            .header("Content-Type", "application/json")
            .body(Body::from("a".repeat(2048)))
            .unwrap();
    }
    if state.mode == "throttle" && index == 0 {
        return Response::builder()
            .status(503)
            .header("Retry-After", "1")
            .body(Body::empty())
            .unwrap();
    }
    if state.mode == "not_found" {
        return Response::builder().status(404).body(Body::empty()).unwrap();
    }
    if state.mode == "error" {
        return Response::builder().status(500).body(Body::empty()).unwrap();
    }
    if state.mode == "unauthorized" {
        return Response::builder().status(401).body(Body::empty()).unwrap();
    }
    if state.mode == "conditional" && index > 0 {
        assert_eq!(
            request.headers().get("if-none-match").unwrap(),
            "\"fixture-v1\""
        );
        return Response::builder()
            .status(304)
            .header("Cache-Control", "max-age=3600")
            .body(Body::empty())
            .unwrap();
    }
    let body = if state.mode == "wrong_schema" {
        json!({"error":"not a provider record"})
    } else if request.uri().path().contains("/v2/lookup") {
        assert!(
            request.uri().query().is_none(),
            "client keys and fingerprints must not be in URLs"
        );
        let bytes = axum::body::to_bytes(request.into_body(), 65536)
            .await
            .unwrap();
        let form: std::collections::HashMap<_, _> =
            url::form_urlencoded::parse(&bytes).into_owned().collect();
        assert_eq!(form["client"], "synthetic-client-key");
        assert_eq!(form["fingerprint"], "AQABfixture");
        assert_eq!(form["duration"], "123");
        json!({"status":"ok","results":[{"id":"fixture","score":0.99,"recordings":[{"id":"11111111-1111-4111-8111-111111111111"}]}]})
    } else if request.uri().path().contains("recording") {
        json!({"recordings":[{"id":"11111111-1111-4111-8111-111111111111","title":"Fixture","score":99,"length":123000,"artist-credit":[{"name":"Test Artist"}],"releases":[{"id":"22222222-2222-4222-8222-222222222222","title":"Fixture Album","date":"2020-01-02"}]}]})
    } else {
        json!({"id":1,"trackName":"Fixture","artistName":"Test Artist","albumName":"Fixture Album","duration":123,"plainLyrics":"Synthetic test lyric","syncedLyrics":"[00:01.00] Synthetic test lyric"})
    };
    let mut response = Response::builder()
        .header("Content-Type", "application/json")
        .header("ETag", "\"fixture-v1\"");
    match state.mode {
        "conditional" => response = response.header("Cache-Control", "max-age=0"),
        "no_store" => response = response.header("Cache-Control", "no-store"),
        "private" => response = response.header("Cache-Control", "private, max-age=3600"),
        "vary" => response = response.header("Vary", "*"),
        "vary_user_agent" => response = response.header("Vary", "User-Agent"),
        _ => {}
    }
    response
        .body(Body::from(if state.mode == "malformed" {
            b"not JSON".to_vec()
        } else {
            serde_json::to_vec(&body).unwrap()
        }))
        .unwrap()
}

struct Fixture {
    directory: TempDir,
    upstream: Upstream,
    server: JoinHandle<()>,
    config: Config,
}

impl Fixture {
    async fn new(mode: &'static str) -> Self {
        let directory = TempDir::new().unwrap();
        let upstream = Upstream {
            hits: Arc::default(),
            requests: Arc::default(),
            mode,
        };
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let router = Router::new()
            .fallback(axum::routing::any(respond))
            .with_state(upstream.clone());
        let server = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        let mut config = Config::default();
        config.cache.path = directory.path().join("cache.sqlite");
        config.musicbrainz.base_url = Some(base.clone());
        config.lrclib.base_url = Some(base.clone());
        config.cover_art.base_url = Some(base.clone());
        config.acoustid.base_url = Some(base);
        config.network.deadline_seconds = 8;
        config.network.max_retries = 1;
        Self {
            directory,
            upstream,
            server,
            config,
        }
    }
    fn hits(&self) -> usize {
        self.upstream.hits.load(Ordering::SeqCst)
    }
    fn client(&self) -> Client {
        Client::new(self.config.clone()).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.server.abort();
    }
}

fn track(title: &str) -> TrackInput {
    serde_json::from_value(
        json!({"title":title,"artist":"Test Artist","album":"Fixture Album","duration":123}),
    )
    .unwrap()
}

#[tokio::test]
async fn identical_inflight_queries_share_one_request_and_persist_across_restart() {
    let fixture = Fixture::new("slow").await;
    let input = track("Fixture");
    {
        let client = fixture.client();
        let (a, b, c) = tokio::join!(
            client.lyrics(&input, Priority::Interactive),
            client.lyrics(&input, Priority::Background),
            client.lyrics(&input, Priority::Interactive)
        );
        assert_eq!(a.unwrap().data["plainLyrics"], "Synthetic test lyric");
        b.unwrap();
        c.unwrap();
        assert_eq!(fixture.hits(), 1);
    }
    let client = fixture.client();
    let reply = client.lyrics(&input, Priority::Interactive).await.unwrap();
    assert_eq!(reply.cache, "hit");
    assert_eq!(fixture.hits(), 1);
    assert!(fixture.directory.path().join("cache.sqlite").exists());
}

#[tokio::test]
async fn expired_response_is_conditionally_revalidated_then_reused() {
    let fixture = Fixture::new("conditional").await;
    let client = fixture.client();
    let input = track("Fixture");
    client.lyrics(&input, Priority::Interactive).await.unwrap();
    let revalidated = client.lyrics(&input, Priority::Interactive).await.unwrap();
    assert_eq!(revalidated.cache, "revalidated");
    assert_eq!(revalidated.data["id"], 1);
    assert_eq!(
        client
            .lyrics(&input, Priority::Interactive)
            .await
            .unwrap()
            .cache,
        "hit"
    );
    assert_eq!(fixture.hits(), 2);
}

#[tokio::test]
async fn noncacheable_responses_are_never_reused() {
    for mode in ["no_store", "private", "vary"] {
        let fixture = Fixture::new(mode).await;
        let client = fixture.client();
        let input = track("Fixture");
        client.lyrics(&input, Priority::Interactive).await.unwrap();
        client.lyrics(&input, Priority::Interactive).await.unwrap();
        assert_eq!(fixture.hits(), 2, "{mode}");
    }
}

#[tokio::test]
async fn negative_results_are_cached_but_transient_and_authentication_errors_are_not() {
    for (mode, expected_hits) in [
        ("not_found", 1),
        ("unauthorized", 2),
        ("error", 4),
        ("malformed", 2),
        ("wrong_schema", 2),
    ] {
        let fixture = Fixture::new(mode).await;
        let client = fixture.client();
        for _ in 0..2 {
            assert!(
                client
                    .lyrics(&track("Fixture"), Priority::Interactive)
                    .await
                    .is_err()
            );
        }
        assert_eq!(fixture.hits(), expected_hits, "{mode}");
    }
}

#[tokio::test]
async fn acoustid_uses_form_authentication_and_caches_public_lookup_results() {
    let mut fixture = Fixture::new("ok").await;
    fixture.config.acoustid.client_key = Some("synthetic-client-key".into());
    let client = fixture.client();
    let input: TrackInput =
        serde_json::from_value(json!({"fingerprint":"AQABfixture","duration":123})).unwrap();
    assert_eq!(
        client
            .identify(&input, Priority::Interactive)
            .await
            .unwrap()
            .data["results"][0]["score"],
        0.99
    );
    assert_eq!(
        client
            .identify(&input, Priority::Interactive)
            .await
            .unwrap()
            .cache,
        "hit"
    );
    assert_eq!(fixture.hits(), 1);
    assert!(
        !std::fs::read(fixture.config.cache.path.clone())
            .unwrap()
            .windows(20)
            .any(|w| w == b"synthetic-client-key")
    );
}

#[tokio::test]
async fn queue_capacity_rejects_new_work_while_duplicates_can_join() {
    let mut fixture = Fixture::new("slow").await;
    fixture.config.network.queue_capacity = 1;
    let client = fixture.client();
    let first = client.clone();
    let running =
        tokio::spawn(async move { first.lyrics(&track("First"), Priority::Background).await });
    tokio::time::timeout(Duration::from_secs(2), async {
        while fixture.hits() == 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let error = client
        .lyrics(&track("Second"), Priority::Interactive)
        .await
        .unwrap_err();
    assert!(matches!(error, sonora_proxy::providers::Error::QueueFull));
    let duplicate = client
        .lyrics(&track("First"), Priority::Interactive)
        .await
        .unwrap();
    assert_eq!(duplicate.data["id"], 1);
    running.await.unwrap().unwrap();
    assert_eq!(fixture.hits(), 1);
}

#[tokio::test]
async fn cancelling_one_consumer_keeps_shared_work_alive() {
    let fixture = Fixture::new("slow").await;
    let client = fixture.client();
    let first = client.clone();
    let second = client.clone();
    let a = tokio::spawn(async move { first.lyrics(&track("Shared"), Priority::Background).await });
    let b =
        tokio::spawn(async move { second.lyrics(&track("Shared"), Priority::Interactive).await });
    tokio::time::timeout(Duration::from_secs(2), async {
        while fixture.hits() == 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    a.abort();
    let _ = a.await;
    assert!(b.await.unwrap().is_ok());
    assert_eq!(fixture.hits(), 1);
}

#[tokio::test]
async fn deadlines_and_response_size_limits_bound_provider_work() {
    let mut fixture = Fixture::new("hang").await;
    fixture.config.network.deadline_seconds = 1;
    let client = fixture.client();
    let result = client
        .lyrics(&track("Fixture"), Priority::Interactive)
        .await;
    assert!(matches!(
        result,
        Err(sonora_proxy::providers::Error::Deadline)
    ));
    drop(client);
    let mut fixture = Fixture::new("oversized").await;
    fixture.config.network.max_response_bytes = 1024;
    let client = fixture.client();
    assert!(matches!(
        client
            .lyrics(&track("Fixture"), Priority::Interactive)
            .await,
        Err(sonora_proxy::providers::Error::TooLarge)
    ));
}

#[tokio::test]
async fn interactive_priority_still_allows_background_work_to_progress() {
    let mut fixture = Fixture::new("ok").await;
    fixture.config.lrclib.min_interval_ms = Some(200);
    let client = fixture.client();
    client
        .lyrics(&track("Gate"), Priority::Interactive)
        .await
        .unwrap();
    let mut tasks = Vec::new();
    for (name, priority) in [
        ("Background", Priority::Background),
        ("A", Priority::Interactive),
        ("B", Priority::Interactive),
        ("C", Priority::Interactive),
        ("D", Priority::Interactive),
    ] {
        let client = client.clone();
        tasks.push(tokio::spawn(async move {
            client.lyrics(&track(name), priority).await
        }));
    }
    for task in tasks {
        task.await.unwrap().unwrap();
    }
    let requests = fixture.upstream.requests.lock().unwrap();
    assert!(!requests[1].1.contains("Background"));
    assert!(
        requests
            .iter()
            .position(|(_, uri, _)| uri.contains("Background"))
            .unwrap()
            <= 4
    );
}

#[tokio::test]
async fn retry_after_and_retries_share_the_provider_rate_limiter() {
    let fixture = Fixture::new("throttle").await;
    let client = fixture.client();
    let reply = client
        .search(&track("Fixture"), Priority::Interactive)
        .await
        .unwrap();
    assert_eq!(reply.data[0].title, "Fixture");
    let requests = fixture.upstream.requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert!(requests[1].0.duration_since(requests[0].0) >= Duration::from_secs(1));
    assert!(
        requests[0].2["user-agent"]
            .to_str()
            .unwrap()
            .contains("Sonora")
    );
}

#[tokio::test]
async fn providers_have_independent_limits_and_search_escapes_lucene_input() {
    let fixture = Fixture::new("ok").await;
    let client = fixture.client();
    let a = track("One");
    let b = track("Two\" OR *:*");
    let c = track("Three");
    let (a, b, c) = tokio::join!(
        client.search(&a, Priority::Background),
        client.search(&b, Priority::Interactive),
        client.lyrics(&c, Priority::Interactive)
    );
    a.unwrap();
    b.unwrap();
    c.unwrap();
    let requests = fixture.upstream.requests.lock().unwrap();
    let music: Vec<_> = requests
        .iter()
        .filter(|(_, url, _)| url.contains("recording"))
        .collect();
    assert!(music[1].0.duration_since(music[0].0) >= Duration::from_secs(1));
    let queries: Vec<_> = music
        .iter()
        .map(|(_, uri, _)| {
            url::Url::parse(&format!("http://fixture{uri}"))
                .unwrap()
                .query_pairs()
                .find(|(k, _)| k == "query")
                .unwrap()
                .1
                .into_owned()
        })
        .collect();
    assert!(
        queries
            .iter()
            .any(|q| q.contains("recording:\"Two\\\" OR \\*\\:\\*\"")),
        "{queries:?}"
    );
    let lyrics = requests
        .iter()
        .find(|(_, url, _)| url.contains("/api/get"))
        .unwrap();
    assert!(lyrics.0 < music[1].0);
}

#[tokio::test]
async fn invalid_input_and_missing_credentials_do_not_contact_providers() {
    let fixture = Fixture::new("ok").await;
    let client = fixture.client();
    assert!(
        client
            .search(&track(" "), Priority::Interactive)
            .await
            .is_err()
    );
    let missing: TrackInput = serde_json::from_value(json!({"title":"Fixture"})).unwrap();
    assert!(
        client
            .lyrics(&missing, Priority::Interactive)
            .await
            .is_err()
    );
    assert!(
        client
            .release("../../private", Priority::Interactive)
            .await
            .is_err()
    );
    let fingerprint: TrackInput =
        serde_json::from_value(json!({"fingerprint":"AQABfixture","duration":123})).unwrap();
    assert!(
        client
            .identify(&fingerprint, Priority::Interactive)
            .await
            .is_err()
    );
    assert_eq!(fixture.hits(), 0);
}

#[tokio::test]
async fn cached_representations_varying_by_user_agent_do_not_cross_config_changes() {
    let mut fixture = Fixture::new("vary_user_agent").await;
    {
        let client = fixture.client();
        client
            .lyrics(&track("Fixture"), Priority::Interactive)
            .await
            .unwrap();
    }
    fixture.config.user_agent = "SonoraProxy/0.2.0 (https://github.com/tonyredondo/Sonora)".into();
    let client = fixture.client();
    assert_eq!(
        client
            .lyrics(&track("Fixture"), Priority::Interactive)
            .await
            .unwrap()
            .cache,
        "miss"
    );
    assert_eq!(fixture.hits(), 2);
}

#[tokio::test]
async fn an_interrupted_download_is_retried_without_caching_partial_bytes() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let directory = TempDir::new().unwrap();
    let hits = Arc::new(AtomicUsize::new(0));
    let count = hits.clone();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        for attempt in 0..2 {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let mut buffer = [0_u8; 1024];
            while !request.windows(4).any(|w| w == b"\r\n\r\n") {
                let n = socket.read(&mut buffer).await.unwrap();
                if n == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..n]);
            }
            count.fetch_add(1, Ordering::SeqCst);
            let body = if attempt == 0 {
                b"{".to_vec()
            } else {
                json!({"id":1,"trackName":"Fixture","artistName":"Artist","albumName":"Album","duration":123,"plainLyrics":"Fixture","syncedLyrics":null}).to_string().into_bytes()
            };
            let length = if attempt == 0 { 1000 } else { body.len() };
            let header = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n"
            );
            socket.write_all(header.as_bytes()).await.unwrap();
            socket.write_all(&body).await.unwrap();
            socket.shutdown().await.unwrap();
        }
    });
    let mut config = Config::default();
    config.cache.path = directory.path().join("cache.sqlite");
    config.lrclib.base_url = Some(base);
    config.network.max_retries = 1;
    let client = Client::new(config).unwrap();
    assert_eq!(
        client
            .lyrics(&track("Fixture"), Priority::Interactive)
            .await
            .unwrap()
            .data["id"],
        1
    );
    assert_eq!(
        client
            .lyrics(&track("Fixture"), Priority::Interactive)
            .await
            .unwrap()
            .cache,
        "hit"
    );
    assert_eq!(hits.load(Ordering::SeqCst), 2);
    server.await.unwrap();
}

#[tokio::test]
async fn dropping_a_queued_lookup_prevents_its_network_request() {
    let fixture = Fixture::new("ok").await;
    let client = fixture.client();
    client
        .search(&track("First"), Priority::Interactive)
        .await
        .unwrap();
    let pending_client = client.clone();
    let pending = tokio::spawn(async move {
        pending_client
            .search(&track("Cancelled"), Priority::Background)
            .await
    });
    tokio::time::sleep(Duration::from_millis(50)).await;
    pending.abort();
    let _ = pending.await;
    client
        .search(&track("Last"), Priority::Interactive)
        .await
        .unwrap();
    assert_eq!(fixture.hits(), 2);
    assert!(
        !fixture
            .upstream
            .requests
            .lock()
            .unwrap()
            .iter()
            .any(|(_, url, _)| url.contains("Cancelled"))
    );
}
