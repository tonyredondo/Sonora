use axum::{body::Body, http::Request};
use base64::{Engine, engine::general_purpose::STANDARD};
use http_body_util::BodyExt;
use serde_json::json;
use sonora_proxy::config::Config;
use tower::ServiceExt;

#[tokio::test]
async fn expansion_routes_enforce_auth_and_image_validation_without_using_codex() {
    let tmp = tempfile::tempdir().unwrap();
    let mut config = Config::default();
    config.cache.path = tmp.path().join("cache.sqlite");
    config.metadata.path = tmp.path().join("metadata.sqlite");
    config.server.api_token = Some("synthetic-panorama-contract-token".into());
    let app = sonora_proxy::api::router(config).unwrap();
    let mut png = std::io::Cursor::new(Vec::new());
    image::RgbaImage::from_pixel(32, 32, image::Rgba([1, 2, 3, 255]))
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    let source = STANDARD.encode(png.into_inner());
    for (auth, input, expected) in [
        (false, json!({"image":source,"aspect":"9:4"}), 401),
        (true, json!({"image":"not-base64","aspect":"9:4"}), 400),
        (
            true,
            json!({"image":STANDARD.encode(b"not an image"),"aspect":"9:4"}),
            400,
        ),
        (true, json!({"image":source,"aspect":"9:4"}), 503),
        (true, json!({"image":source,"aspect":"2:3"}), 503),
    ] {
        let mut request = Request::builder()
            .method("POST")
            .uri("/v1/artwork/expansions/jobs")
            .header("content-type", "application/json");
        if auth {
            request = request.header("authorization", "Bearer synthetic-panorama-contract-token");
        }
        let response = app
            .clone()
            .oneshot(request.body(Body::from(input.to_string())).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), expected);
    }
    let id = "a".repeat(64);
    for suffix in ["", "/image", "/ack"] {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(if suffix == "/ack" { "POST" } else { "GET" })
                    .uri(format!("/v1/artwork/expansions/jobs/{id}{suffix}"))
                    .header("authorization", "Bearer synthetic-panorama-contract-token")
                    .header("content-type", "application/json")
                    .body(Body::from(if suffix == "/ack" {
                        json!({"sha256":id}).to_string()
                    } else {
                        String::new()
                    }))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), 404);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&body).unwrap()["error"],
            "artwork_expansion_not_found"
        );
    }
}
