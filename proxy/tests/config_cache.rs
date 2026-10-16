use bytes::Bytes;
use sonora_proxy::{
    cache::{Cache, CacheEntry, ResponseHeaders},
    config::{Config, discover_config},
};
use std::{path::PathBuf, time::Duration};
use tempfile::TempDir;

#[test]
fn config_discovers_home_then_portable_and_explicit_path_wins() {
    let temp = TempDir::new().unwrap();
    let home = temp.path().join("home");
    let bin = temp.path().join("bin");
    std::fs::create_dir_all(home.join(".config/sonora-proxy")).unwrap();
    std::fs::create_dir_all(&bin).unwrap();
    let portable = bin.join("sonora-proxy.toml");
    std::fs::write(&portable, "[server]\nlisten='127.0.0.1:8089'").unwrap();
    assert_eq!(discover_config(None, &home, &bin).unwrap(), portable);
    let personal = home.join(".config/sonora-proxy/config.toml");
    std::fs::write(&personal, "[server]\nlisten='127.0.0.1:8090'").unwrap();
    assert_eq!(discover_config(None, &home, &bin).unwrap(), personal);
    assert_eq!(
        discover_config(Some(&portable), &home, &bin).unwrap(),
        portable
    );
    assert!(discover_config(Some(&bin.join("absent.toml")), &home, &bin).is_err());
}

#[test]
fn configuration_loads_secrets_without_exposing_them_in_errors() {
    let temp = TempDir::new().unwrap();
    let file = temp.path().join("config.toml");
    let secret = "test-only-secret-never-echo";
    std::fs::write(&file, format!("[server]\napi_token='{secret}'\n[cache]\npath='state/cache.sqlite'\n[acoustid]\nclient_key='{secret}'\n")).unwrap();
    let config = Config::load(&file).unwrap();
    assert_eq!(config.acoustid.client_key.as_deref(), Some(secret));
    assert_eq!(config.cache.path, temp.path().join("state/cache.sqlite"));
    std::fs::write(&file, format!("[server]\napi_token='{secret}'\nlisten=42")).unwrap();
    let error = Config::load(&file).err().unwrap().to_string();
    assert!(
        !error.contains(secret),
        "TOML errors must not echo source lines"
    );
}

#[test]
fn configuration_rejects_unsafe_rates_and_unknown_fields() {
    for text in [
        "[musicbrainz]\nmin_interval_ms=20",
        "[acoustid]\nmin_interval_ms=100",
        "[cache]\nmax_bytes=0",
        "[server]\nlisten='0.0.0.0:8089'",
        "[server]\napi_tokne='typo'",
    ] {
        assert!(
            Config::parse(text, PathBuf::from("/tmp")).is_err(),
            "{text}"
        );
    }
}

fn entry(body: &'static [u8], expires_at: u64) -> CacheEntry {
    CacheEntry {
        status: 200,
        body: Bytes::from_static(body),
        headers: ResponseHeaders {
            content_type: Some("application/json".into()),
            etag: Some("\"v1\"".into()),
            ..Default::default()
        },
        stored_at: 100,
        expires_at,
    }
}

#[tokio::test]
async fn cache_survives_reopen_and_retains_stale_validators() {
    let temp = TempDir::new().unwrap();
    let path = temp.path().join("cache.sqlite");
    {
        let cache = Cache::open(&path, 1024, 10).unwrap();
        cache
            .put("lyrics", entry(b"{\"plainLyrics\":\"fixture\"}", 110))
            .await
            .unwrap();
        assert!(
            Cache::open(&path, 1024, 10).is_err(),
            "one writer process owns a cache"
        );
    }
    let cache = Cache::open(&path, 1024, 10).unwrap();
    let saved = cache.get("lyrics").await.unwrap().unwrap();
    assert_eq!(saved.body, b"{\"plainLyrics\":\"fixture\"}".as_slice());
    assert_eq!(saved.headers.etag.as_deref(), Some("\"v1\""));
    assert!(!saved.is_fresh(111));
}

#[tokio::test]
async fn cache_enforces_payload_and_entry_budgets_and_can_remove() {
    let temp = TempDir::new().unwrap();
    let cache = Cache::open(&temp.path().join("cache.sqlite"), 12, 2).unwrap();
    cache.put("first", entry(b"12345678", 200)).await.unwrap();
    tokio::time::sleep(Duration::from_millis(5)).await;
    cache.put("second", entry(b"abcdefgh", 200)).await.unwrap();
    assert!(cache.get("first").await.unwrap().is_none());
    assert!(cache.get("second").await.unwrap().is_some());
    cache
        .put("oversized", entry(b"1234567890123", 200))
        .await
        .unwrap();
    assert!(cache.get("oversized").await.unwrap().is_none());
    cache.remove("second").await.unwrap();
    assert!(cache.get("second").await.unwrap().is_none());
}

#[tokio::test]
async fn lowering_cache_budget_takes_effect_when_reopening() {
    let directory = TempDir::new().unwrap();
    let path = directory.path().join("cache.sqlite");
    {
        let cache = Cache::open(&path, 1024, 10).unwrap();
        cache.put("first", entry(b"12345678", 200)).await.unwrap();
        cache.put("second", entry(b"abcdefgh", 200)).await.unwrap();
    }
    let cache = Cache::open(&path, 8, 1).unwrap();
    assert!(cache.get("first").await.unwrap().is_none());
    assert!(cache.get("second").await.unwrap().is_some());
}
