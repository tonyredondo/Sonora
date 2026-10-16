use axum::{
    Router,
    body::Body,
    extract::Request,
    http::{StatusCode, header},
    response::Response,
    routing::get,
};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use sonora_proxy::{api, config::Config};
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tempfile::TempDir;
use tokio::net::TcpListener;
use tower::ServiceExt;

async fn request(
    router: &Router,
    method: &str,
    uri: &str,
    body: Value,
    token: Option<&str>,
) -> (StatusCode, Value) {
    let mut builder = axum::http::Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json");
    if let Some(token) = token {
        builder = builder.header(header::AUTHORIZATION, format!("Bearer {token}"));
    }
    let response = router
        .clone()
        .oneshot(builder.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes)
            .unwrap_or_else(|_| json!({"text":String::from_utf8_lossy(&bytes)})),
    )
}
fn config(directory: &TempDir) -> Config {
    let mut config = Config::default();
    config.cache.path = directory.path().join("cache.sqlite");
    config
}

#[tokio::test]
async fn api_requires_configured_bearer_token_but_health_is_public() {
    let directory = TempDir::new().unwrap();
    let mut config = config(&directory);
    config.server.api_token = Some("test-only-token".into());
    let router = api::router(config).unwrap();
    assert_eq!(
        request(&router, "GET", "/health", json!(null), None)
            .await
            .0,
        StatusCode::OK
    );
    for token in [None, Some("wrong")] {
        assert_eq!(
            request(
                &router,
                "GET",
                "/v1/jobs/11111111-1111-4111-8111-111111111111",
                json!(null),
                token
            )
            .await
            .0,
            StatusCode::UNAUTHORIZED
        );
    }
    assert_eq!(
        request(
            &router,
            "GET",
            "/v1/jobs/11111111-1111-4111-8111-111111111111",
            json!(null),
            Some("test-only-token")
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn invalid_batches_and_provider_parameters_are_rejected_before_jobs_start() {
    let directory = TempDir::new().unwrap();
    let router = api::router(config(&directory)).unwrap();
    for body in [
        json!({"tracks":[]}),
        json!({"tracks":[{}]}),
        json!({"tracks":[{"fingerprint":"AQABfixture"}]}),
        json!({"tracks":[{"title":"Fixture","duration":0}]}),
    ] {
        assert!(
            request(&router, "POST", "/v1/jobs", body, None)
                .await
                .0
                .is_client_error()
        );
    }
    assert!(
        request(
            &router,
            "GET",
            "/v1/recordings?title=%20",
            json!(null),
            None
        )
        .await
        .0
        .is_client_error()
    );
    assert!(
        request(&router, "GET", "/v1/artwork/invalid-id", json!(null), None)
            .await
            .0
            .is_client_error()
    );
}

#[tokio::test]
async fn batch_returns_progress_and_partial_provider_results_without_writing_files() {
    let directory = TempDir::new().unwrap();
    let hits = Arc::new(AtomicUsize::new(0));
    let count = hits.clone();
    let upstream=Router::new().fallback(get(move |req:Request| { let count=count.clone(); async move {
        count.fetch_add(1,Ordering::SeqCst);
        if req.uri().path().contains("recording") { return Response::builder().status(503).body(Body::empty()).unwrap(); }
        Response::builder().header("Content-Type","application/json").body(Body::from(json!({"id":1,"trackName":"Fixture","artistName":"Artist","albumName":"Album","duration":123,"instrumental":false,"plainLyrics":"Synthetic lyric","syncedLyrics":null}).to_string())).unwrap()
    }}));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, upstream).await.unwrap();
    });
    let mut config = config(&directory);
    config.musicbrainz.base_url = Some(base.clone());
    config.lrclib.base_url = Some(base);
    config.network.max_retries = 0;
    let router = api::router(config).unwrap();
    let (status, created) = request(
        &router,
        "POST",
        "/v1/jobs",
        json!({"tracks":[{"title":"Fixture","artist":"Artist","album":"Album","duration":123}]}),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::ACCEPTED);
    let uri = format!("/v1/jobs/{}", created["id"].as_str().unwrap());
    let snapshot = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let (_, snapshot) = request(&router, "GET", &uri, json!(null), None).await;
            if snapshot["state"] == "completed" {
                break snapshot;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(snapshot["completed"], 1);
    assert_eq!(
        snapshot["results"][0]["lyrics"]["data"]["plainLyrics"],
        "Synthetic lyric"
    );
    assert_eq!(
        snapshot["results"][0]["warnings"][0]["provider"],
        "musicbrainz"
    );
    assert_eq!(hits.load(Ordering::SeqCst), 2);
    assert!(directory.path().read_dir().unwrap().all(|e| {
        e.unwrap()
            .file_name()
            .to_str()
            .unwrap()
            .starts_with("cache.")
    }));
    server.abort();
}

#[tokio::test]
async fn cancellation_is_observable_and_job_capacity_is_bounded() {
    let directory = TempDir::new().unwrap();
    let upstream = Router::new().fallback(get(|| async {
        tokio::time::sleep(Duration::from_secs(10)).await;
        "{}"
    }));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, upstream).await.unwrap();
    });
    let mut config = config(&directory);
    config.musicbrainz.base_url = Some(base);
    config.server.max_jobs = 1;
    let router = api::router(config).unwrap();
    let body = json!({"tracks":[{"title":"Fixture","lyrics":false}]});
    let (_, created) = request(&router, "POST", "/v1/jobs", body.clone(), None).await;
    assert_eq!(
        request(&router, "POST", "/v1/jobs", body.clone(), None)
            .await
            .0,
        StatusCode::TOO_MANY_REQUESTS
    );
    let uri = format!("/v1/jobs/{}", created["id"].as_str().unwrap());
    let (status, cancelled) = request(&router, "DELETE", &uri, json!(null), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(cancelled["state"], "cancelled");
    assert_eq!(
        request(&router, "GET", &uri, json!(null), None).await.1["state"],
        "cancelled"
    );
    assert_eq!(
        request(&router, "POST", "/v1/jobs", body, None).await.0,
        StatusCode::ACCEPTED
    );
    server.abort();
}

#[tokio::test]
async fn artwork_download_follows_allowed_redirect_and_reuses_cached_bytes() {
    let directory = TempDir::new().unwrap();
    let hits = Arc::new(AtomicUsize::new(0));
    let count = hits.clone();
    // A tiny JPEG marker fixture is sufficient for the proxy's MIME/size contract; it does not decode images.
    let upstream = Router::new().fallback(get(move |req: Request| {
        let count = count.clone();
        async move {
            count.fetch_add(1, Ordering::SeqCst);
            if req.uri().path() == "/image.jpg" {
                Response::builder()
                    .header("Content-Type", "image/jpeg")
                    .body(Body::from(vec![0xff, 0xd8, 0xff, 0xd9]))
                    .unwrap()
            } else {
                Response::builder()
                    .status(307)
                    .header("Location", "/image.jpg")
                    .body(Body::empty())
                    .unwrap()
            }
        }
    }));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, upstream).await.unwrap();
    });
    let mut config = config(&directory);
    config.cover_art.base_url = Some(base);
    config.cover_art.min_interval_ms = Some(200);
    let router = api::router(config).unwrap();
    for expected in ["miss", "hit"] {
        let response = router
            .clone()
            .oneshot(
                axum::http::Request::builder()
                    .uri("/v1/artwork/22222222-2222-4222-8222-222222222222")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()["x-sonora-cache"], expected);
        assert_eq!(response.headers()["content-type"], "image/jpeg");
        assert_eq!(
            response
                .into_body()
                .collect()
                .await
                .unwrap()
                .to_bytes()
                .as_ref(),
            [0xff, 0xd8, 0xff, 0xd9]
        );
    }
    assert_eq!(hits.load(Ordering::SeqCst), 2);
    server.abort();
}

#[tokio::test]
async fn job_result_memory_limit_reports_failure_without_dropping_it_silently() {
    let directory = TempDir::new().unwrap();
    let upstream=Router::new().fallback(get(||async { axum::Json(json!({"recordings":[{"id":"11111111-1111-4111-8111-111111111111","title":"x".repeat(2500)}]})) }));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, upstream).await.unwrap();
    });
    let mut config = config(&directory);
    config.musicbrainz.base_url = Some(base);
    config.server.max_job_result_bytes = 1024;
    let router = api::router(config).unwrap();
    let (_, created) = request(
        &router,
        "POST",
        "/v1/jobs",
        json!({"tracks":[{"title":"Fixture","lyrics":false}]}),
        None,
    )
    .await;
    let uri = format!("/v1/jobs/{}", created["id"].as_str().unwrap());
    let result = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let (_, result) = request(&router, "GET", &uri, json!(null), None).await;
            if result["state"] == "failed" {
                break result;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(result["completed"], 0);
    assert!(result["error"].as_str().unwrap().contains("memory limit"));
    server.abort();
}

#[tokio::test]
async fn fingerprint_job_preserves_each_recordings_provenance() {
    let directory = TempDir::new().unwrap();
    let first = "11111111-1111-4111-8111-111111111111";
    let second = "22222222-2222-4222-8222-222222222222";
    let upstream=Router::new().fallback(axum::routing::any(move |req:Request|async move {
        if req.uri().path()=="/v2/lookup" {axum::Json(json!({"status":"ok","results":[{"score":0.95,"recordings":[{"id":first},{"id":second},{"id":first}]}]}))}
        else {let id=req.uri().path().rsplit('/').next().unwrap();axum::Json(json!({"id":id,"title":"Fixture","artist-credit":[],"releases":[]}))}
    }));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, upstream).await.unwrap();
    });
    let mut config = config(&directory);
    config.musicbrainz.base_url = Some(base.clone());
    config.acoustid.base_url = Some(base);
    config.acoustid.client_key = Some("test-client-only".into());
    let router = api::router(config).unwrap();
    assert_eq!(
        request(
            &router,
            "GET",
            &format!("/v1/recordings/{first}"),
            json!(null),
            None
        )
        .await
        .0,
        StatusCode::OK
    );
    let (_, created) = request(
        &router,
        "POST",
        "/v1/jobs",
        json!({"tracks":[{"fingerprint":"AQABfixture","duration":123,"lyrics":false}]}),
        None,
    )
    .await;
    let uri = format!("/v1/jobs/{}", created["id"].as_str().unwrap());
    let result = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let (_, result) = request(&router, "GET", &uri, json!(null), None).await;
            if result["state"] == "completed" {
                break result;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    let metadata = &result["results"][0]["metadata"];
    assert_eq!(metadata["data"].as_array().unwrap().len(), 2);
    assert_eq!(metadata["cache"], "mixed");
    let sources = metadata["sources"]
        .as_array()
        .expect("each recording's actual provider request must remain identifiable");
    assert_eq!(sources.len(), 2);
    assert!(sources[0].as_str().unwrap().contains(first));
    assert!(sources[1].as_str().unwrap().contains(second));
    server.abort();
}

#[tokio::test]
async fn artwork_rejects_redirects_to_unrelated_hosts_without_following_them() {
    let directory = TempDir::new().unwrap();
    let upstream = Router::new().fallback(get(|| async {
        Response::builder()
            .status(307)
            .header("Location", "http://127.0.0.1:1/secret")
            .body(Body::empty())
            .unwrap()
    }));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, upstream).await.unwrap();
    });
    let mut config = config(&directory);
    config.cover_art.base_url = Some(base);
    let router = api::router(config).unwrap();
    assert_eq!(
        request(
            &router,
            "GET",
            "/v1/artwork/22222222-2222-4222-8222-222222222222",
            json!(null),
            None
        )
        .await
        .0,
        StatusCode::BAD_GATEWAY
    );
    server.abort();
}
