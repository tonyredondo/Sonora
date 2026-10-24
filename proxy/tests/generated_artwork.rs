use axum::{body::Body, http::Request};
use serde_json::json;
use sonora_proxy::config::Config;
use tower::ServiceExt;

#[tokio::test]
async fn missing_artwork_endpoint_validates_input_before_codex() {
    let tmp = tempfile::TempDir::new().unwrap();
    let mut config = Config::default();
    config.cache.path = tmp.path().join("cache.sqlite");
    config.metadata.path = tmp.path().join("metadata.sqlite");
    let app = sonora_proxy::api::router(config).unwrap();
    for (title, expected) in [("Quiet Horizon", 503), ("", 400)] {
        let body = json!({"title":title,"artist":"Synthetic Artist","album":"First Light","album_description":"A contemplative electronic record about beginnings.","genre":"Ambient","styles":["Electronic"],"moods":["relaxed"]});
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/artwork/generate")
                    .header("content-type", "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), expected);
    }
}

/// Opt-in proof of the installed CLI and its existing ChatGPT session. No API key.
#[tokio::test]
#[ignore = "generates one synthetic image using the local Codex plan"]
async fn native_image_round_trip_is_cached() {
    use http_body_util::BodyExt;
    let tmp = tempfile::TempDir::new().unwrap();
    let mut config = Config::default();
    config.cache.path = tmp.path().join("cache.sqlite");
    config.metadata.path = tmp.path().join("metadata.sqlite");
    config.codex.enabled = true;
    if let Some(binary) = std::env::var_os("SONORA_IMAGE_CODEX_BINARY") {
        config.codex.binary = binary.into();
    }
    let app = sonora_proxy::api::router(config).unwrap();
    let body = json!({"title":"Quiet Horizon", "artist":"Sonora Synthetic QA", "album":"First Light",
        "album_description":"A contemplative electronic record about beginnings, distance and the calm before sunrise.",
        "genre":"Ambient", "styles":["Electronic"], "moods":["relaxed"]});
    let mut first = None;
    for _ in 0..2 {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/artwork/generate")
                    .header("content-type", "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), 200);
        assert_eq!(response.headers()["content-type"], "image/png");
        let image = response.into_body().collect().await.unwrap().to_bytes();
        assert!(image.len() > 1000);
        if let Some(ref first) = first {
            assert_eq!(&image, first);
        } else {
            if let Some(path) = std::env::var_os("SONORA_IMAGE_CAPTURE_PATH") {
                std::fs::write(path, &image).unwrap();
            }
            first = Some(image);
        }
    }
}
