use bytes::Bytes;
use http_body_util::BodyExt;
use sonora_proxy::{
    audio_character::{CharacterService, MAX_BYTES},
    cache::Cache,
    config::{AudioCharacterConfig, Config},
};
use std::{path::Path, time::Duration};
use tempfile::TempDir;
use tower::ServiceExt;

fn pcm() -> Bytes {
    let size = 32_000_u32;
    let mut data = b"RIFF".to_vec();
    data.extend((size + 36).to_le_bytes());
    data.extend(b"WAVEfmt ");
    data.extend(16_u32.to_le_bytes());
    data.extend([1, 0, 1, 0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0, 16, 0]);
    data.extend(b"data");
    data.extend(size.to_le_bytes());
    data.resize(size as usize + 44, 0);
    data.into()
}

#[tokio::test]
#[ignore = "requires an installed Essentia runtime and pinned models"]
async fn live_worker_accepts_one_second_and_silence() {
    let tmp = TempDir::new().unwrap();
    let service = CharacterService::new(
        AudioCharacterConfig {
            enabled: true,
            python: std::env::var_os("SONORA_ANALYSIS_PYTHON")
                .expect("set SONORA_ANALYSIS_PYTHON")
                .into(),
            models: std::env::var_os("SONORA_ANALYSIS_MODELS")
                .expect("set SONORA_ANALYSIS_MODELS")
                .into(),
        },
        cache(tmp.path()),
    );
    let mut music = pcm().to_vec();
    for frame in 0..16_000 {
        let value = ((frame as f64 * 0.17).sin() * 6000.0) as i16;
        music[44 + frame * 2..46 + frame * 2].copy_from_slice(&value.to_le_bytes());
    }
    let music = service.analyze(music.into(), false).await.unwrap();
    assert!(!music.silent);
    assert_eq!(music.styles.len(), 8);
    let silence = service.analyze(pcm(), false).await.unwrap();
    assert!(silence.silent);
    assert!(silence.styles.is_empty());
    assert!(silence.moods.values().all(|value| *value == 0.0));
}
fn cache(root: &Path) -> Cache {
    Cache::open(&root.join("cache.sqlite"), 1_000_000, 100).unwrap()
}
#[cfg(unix)]
fn stub(root: &Path) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let binary = root.join("python-stub");
    std::fs::write(&binary,format!(r#"#!/usr/bin/python3
import sys,json,time
from pathlib import Path
root=Path({root:?})
assert sys.argv[1:3]==['-I','-c']
assert sys.stdin.buffer.read()[:4]==b'RIFF'
with (root/'calls').open('a') as f:f.write('call\n')
time.sleep(0.15)
if (root/'fail').exists():sys.exit(1)
if (root/'oversize').exists():print('x'*40000);sys.exit(0)
print(json.dumps({{'version':'essentia-discogs-v1','silent':False,'styles':[{{'label':'Rock---Indie Rock','score':0.3}}], 'moods':{{'happy':0.2,'sad':0.8,'relaxed':0.9,'aggressive':0.1}}}}))
"#,root=root.to_str().unwrap())).unwrap();
    std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
    binary
}
#[cfg(unix)]
#[tokio::test]
async fn coalesces_work_restores_persistently_and_preserves_cache_on_failed_refresh() {
    let tmp = TempDir::new().unwrap();
    let cache = cache(tmp.path());
    let config = AudioCharacterConfig {
        enabled: true,
        python: stub(tmp.path()),
        models: tmp.path().into(),
    };
    let service = CharacterService::new(config.clone(), cache.clone());
    let (a, b) = tokio::join!(service.analyze(pcm(), false), service.analyze(pcm(), false));
    assert_eq!(a.unwrap().styles[0].label, b.unwrap().styles[0].label);
    assert_eq!(
        std::fs::read_to_string(tmp.path().join("calls"))
            .unwrap()
            .lines()
            .count(),
        1
    );
    std::fs::write(tmp.path().join("fail"), "").unwrap();
    assert!(service.analyze(pcm(), true).await.is_err());
    let reopened = CharacterService::new(config, cache);
    assert_eq!(
        reopened.analyze(pcm(), false).await.unwrap().moods["sad"],
        0.8
    );
    assert_eq!(
        std::fs::read_to_string(tmp.path().join("calls"))
            .unwrap()
            .lines()
            .count(),
        2
    );
}
#[cfg(unix)]
#[tokio::test]
async fn rejects_oversized_worker_output_and_invalid_audio() {
    let tmp = TempDir::new().unwrap();
    let service = CharacterService::new(
        AudioCharacterConfig {
            enabled: true,
            python: stub(tmp.path()),
            models: tmp.path().into(),
        },
        cache(tmp.path()),
    );
    assert!(
        service
            .analyze(Bytes::from_static(b"not WAV"), false)
            .await
            .is_err()
    );
    assert!(
        service
            .analyze(Bytes::from(vec![0; MAX_BYTES + 1]), false)
            .await
            .is_err()
    );
    std::fs::write(tmp.path().join("oversize"), "").unwrap();
    assert!(
        tokio::time::timeout(Duration::from_secs(3), service.analyze(pcm(), false))
            .await
            .unwrap()
            .is_err()
    );
}
#[tokio::test]
async fn api_requires_auth_and_exposes_optional_capability_without_upstream_calls() {
    let tmp = TempDir::new().unwrap();
    let mut config = Config::default();
    config.cache.path = tmp.path().join("cache.sqlite");
    config.metadata.path = tmp.path().join("metadata.sqlite");
    config.server.api_token = Some("test-token".into());
    let app = sonora_proxy::api::router(config).unwrap();
    for (auth, expected) in [(false, 401), (true, 503)] {
        let mut request = axum::http::Request::builder()
            .method("POST")
            .uri("/v1/audio/character");
        if auth {
            request = request.header("Authorization", "Bearer test-token");
        }
        let response = app
            .clone()
            .oneshot(request.body(axum::body::Body::from(pcm())).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), expected);
    }
    let oversized = app
        .clone()
        .oneshot(
            axum::http::Request::builder()
                .method("POST")
                .uri("/v1/audio/character")
                .header("Authorization", "Bearer test-token")
                .body(axum::body::Body::from(vec![0_u8; MAX_BYTES + 1]))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(oversized.status(), 413);
    let response = app
        .oneshot(
            axum::http::Request::builder()
                .uri("/v1/status")
                .header("Authorization", "Bearer test-token")
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let value: serde_json::Value =
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(value["audio_character"]["enabled"], false);
}

#[cfg(unix)]
#[tokio::test]
async fn enabled_api_runs_the_configured_worker_reuses_cache_and_honors_refresh() {
    let tmp = TempDir::new().unwrap();
    let mut config = Config::default();
    config.cache.path = tmp.path().join("cache.sqlite");
    config.metadata.path = tmp.path().join("metadata.sqlite");
    config.server.api_token = Some("fixture-only".into());
    config.audio_character = AudioCharacterConfig {
        enabled: true,
        python: stub(tmp.path()),
        models: tmp.path().into(),
    };
    let app = sonora_proxy::api::router(config).unwrap();
    for path in [
        "/v1/audio/character",
        "/v1/audio/character",
        "/v1/audio/character?refresh=true",
    ] {
        let response = app
            .clone()
            .oneshot(
                axum::http::Request::builder()
                    .method("POST")
                    .uri(path)
                    .header("Authorization", "Bearer fixture-only")
                    .header("Content-Type", "audio/wav")
                    .body(axum::body::Body::from(pcm()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        let value: serde_json::Value =
            serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                .unwrap();
        assert_eq!(value["styles"][0]["label"], "Rock---Indie Rock");
    }
    assert_eq!(
        std::fs::read_to_string(tmp.path().join("calls"))
            .unwrap()
            .lines()
            .count(),
        2
    );
}
