use axum::{body::Body, http::Request};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use sonora_proxy::{api, config::Config};
use tempfile::TempDir;
use tower::ServiceExt;

const TOKEN: &str = "archive-test-token-no-real-credentials";
const AUDIO: &str = "pcm64-v1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const FIRST: &str = "11111111-1111-4111-8111-111111111111";
const SECOND: &str = "22222222-2222-4222-8222-222222222222";

fn config(root: &TempDir) -> Config {
    // Parsing also proves that old provider-only configurations remain valid.
    Config::parse(
        &format!("[server]\napi_token = '{TOKEN}'\n[cache]\npath = 'cache.sqlite'\n[metadata]\npath = 'metadata.sqlite'\n"),
        root.path().to_owned(),
    ).unwrap()
}
fn record(id: &str, album: &str) -> Value {
    json!({"id":id,"audio_id":AUDIO,"confirmed_at":1792300000000_i64,
        "values":{"title":"A song","artist":"An artist","album":album,
            "lyrics":"[re:Transcrita por IA · ElevenLabs]\n[00:01.25]A line"},
        "artwork":"/9j/2Q=="})
}
async fn call(
    app: axum::Router,
    method: &str,
    path: &str,
    data: Option<Value>,
    authorized: bool,
) -> (u16, Value) {
    let mut request = Request::builder()
        .method(method)
        .uri(path)
        .header("Content-Type", "application/json");
    if authorized {
        request = request.header("Authorization", format!("Bearer {TOKEN}"));
    }
    let response = app
        .oneshot(
            request
                .body(data.map_or_else(Body::empty, |v| Body::from(v.to_string())))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status().as_u16();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

#[tokio::test]
async fn confirmed_records_survive_restart_and_provider_cache_removal_without_merging_editions() {
    let root = TempDir::new().unwrap();
    let app = api::router(config(&root)).unwrap();
    assert_eq!(
        call(
            app.clone(),
            "PUT",
            &format!("/v1/metadata-records/{FIRST}"),
            Some(record(FIRST, "Original")),
            true
        )
        .await
        .0,
        201
    );
    assert_eq!(
        call(
            app.clone(),
            "PUT",
            &format!("/v1/metadata-records/{SECOND}"),
            Some(record(SECOND, "Reissue")),
            true
        )
        .await
        .0,
        201
    );
    drop(app);
    std::fs::remove_file(root.path().join("cache.sqlite")).unwrap();
    let reopened = api::router(config(&root)).unwrap();
    let (status, page) = call(
        reopened.clone(),
        "GET",
        &format!("/v1/audio/{AUDIO}/metadata"),
        None,
        true,
    )
    .await;
    assert_eq!(status, 200);
    let albums: Vec<_> = page["records"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["album"].as_str().unwrap())
        .collect();
    assert_eq!(albums, ["Reissue", "Original"]);
    let (_, restored) = call(
        reopened,
        "GET",
        &format!("/v1/metadata-records/{FIRST}"),
        None,
        true,
    )
    .await;
    assert_eq!(restored, record(FIRST, "Original"));
}

#[tokio::test]
async fn retries_are_idempotent_and_cannot_replace_another_confirmed_copy() {
    let root = TempDir::new().unwrap();
    let app = api::router(config(&root)).unwrap();
    let path = format!("/v1/metadata-records/{FIRST}");
    assert_eq!(
        call(
            app.clone(),
            "PUT",
            &path,
            Some(record(FIRST, "Original")),
            true
        )
        .await
        .0,
        201
    );
    assert_eq!(
        call(
            app.clone(),
            "PUT",
            &path,
            Some(record(FIRST, "Original")),
            true
        )
        .await
        .0,
        200
    );
    assert_eq!(
        call(
            app.clone(),
            "PUT",
            &path,
            Some(record(FIRST, "Wrong edition")),
            true
        )
        .await
        .0,
        409
    );
    let (_, saved) = call(app, "GET", &path, None, true).await;
    assert_eq!(saved["values"]["album"], "Original");
}

#[tokio::test]
async fn archive_requires_authentication_and_rejects_invalid_audio_or_metadata() {
    let root = TempDir::new().unwrap();
    let app = api::router(config(&root)).unwrap();
    let path = format!("/v1/metadata-records/{FIRST}");
    assert_eq!(
        call(
            app.clone(),
            "PUT",
            &path,
            Some(record(FIRST, "Original")),
            false
        )
        .await
        .0,
        401
    );
    let mut invalid = record(FIRST, "Original");
    invalid["audio_id"] = json!("../../another-file");
    assert_eq!(
        call(app.clone(), "PUT", &path, Some(invalid), true).await.0,
        400
    );
    let mut invalid = record(FIRST, "Original");
    invalid["values"]["trackNumber"] = json!("-2");
    assert_eq!(
        call(app.clone(), "PUT", &path, Some(invalid), true).await.0,
        400
    );
    let mut invalid = record(FIRST, "Original");
    invalid["values"]["path"] = json!("/private/file.wav");
    assert_eq!(
        call(app.clone(), "PUT", &path, Some(invalid), true).await.0,
        400
    );
    assert_eq!(call(app, "GET", &path, None, true).await.0, 404);
}

#[tokio::test]
async fn pagination_never_omits_or_repeats_a_confirmed_edition() {
    let root = TempDir::new().unwrap();
    let app = api::router(config(&root)).unwrap();
    let mut ids = Vec::new();
    for index in 0..51 {
        let id = uuid::Uuid::new_v4().to_string();
        assert_eq!(
            call(
                app.clone(),
                "PUT",
                &format!("/v1/metadata-records/{id}"),
                Some(record(&id, &format!("Edition {index}"))),
                true
            )
            .await
            .0,
            201
        );
        ids.push(id);
    }
    let (_, first) = call(
        app.clone(),
        "GET",
        &format!("/v1/audio/{AUDIO}/metadata"),
        None,
        true,
    )
    .await;
    assert_eq!(first["records"].as_array().unwrap().len(), 50);
    let cursor = first["next_cursor"].as_i64().unwrap();
    let (_, second) = call(
        app,
        "GET",
        &format!("/v1/audio/{AUDIO}/metadata?before={cursor}"),
        None,
        true,
    )
    .await;
    let returned: Vec<_> = first["records"]
        .as_array()
        .unwrap()
        .iter()
        .chain(second["records"].as_array().unwrap())
        .map(|r| r["id"].as_str().unwrap().to_owned())
        .collect();
    ids.reverse();
    assert_eq!(returned, ids);
    assert!(second["next_cursor"].is_null());
}

#[tokio::test]
async fn a_full_archive_rejects_new_copies_without_evicting_existing_edits() {
    use sonora_proxy::{
        config::MetadataConfig,
        metadata_archive::{ArchiveError, MetadataArchive, MetadataRecord},
    };
    let root = TempDir::new().unwrap();
    let archive = MetadataArchive::open(&MetadataConfig {
        path: root.path().join("metadata.sqlite"),
        max_bytes: 4500,
    })
    .unwrap();
    let mut first: MetadataRecord = serde_json::from_value(record(FIRST, "Original")).unwrap();
    first.values.insert("lyrics".into(), "A".repeat(2000));
    assert!(archive.put(first.clone()).await.unwrap());
    let mut second = first.clone();
    second.id = uuid::Uuid::parse_str(SECOND).unwrap();
    assert!(matches!(archive.put(second).await, Err(ArchiveError::Full)));
    assert_eq!(archive.get(first.id).await.unwrap(), Some(first));
}

#[tokio::test]
async fn maximum_editor_artwork_and_escaped_lyrics_fit_the_json_route_limit() {
    let root = TempDir::new().unwrap();
    let app = api::router(config(&root)).unwrap();
    let mut copy = record(FIRST, "Original");
    copy["values"]["lyrics"] = json!("\"".repeat(1_000_000));
    copy["artwork"] = json!("/".repeat(13_333_332) + "/w==");
    let path = format!("/v1/metadata-records/{FIRST}");
    assert_eq!(
        call(app.clone(), "PUT", &path, Some(copy), true).await.0,
        201
    );
    let (status, restored) = call(app, "GET", &path, None, true).await;
    assert_eq!(status, 200);
    assert_eq!(
        restored["values"]["lyrics"].as_str().unwrap().len(),
        1_000_000
    );
    assert_eq!(restored["artwork"].as_str().unwrap().len(), 13_333_336);
}
