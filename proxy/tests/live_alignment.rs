//! Manual paid contract probe. Default test runs never read a key or contact ElevenLabs.
use sonora_proxy::{
    config::Config,
    providers::{Client, Priority},
};
use std::{env, fs, path::PathBuf};
use tempfile::TempDir;

#[tokio::test]
#[ignore = "Requires explicit approval, a synthetic <=10-second WAV, and an ElevenLabs key"]
async fn approved_synthetic_elevenlabs_alignment() {
    assert_eq!(
        env::var("SONORA_LIVE_ALIGNMENT_ACK").as_deref(),
        Ok("one-paid-synthetic-test"),
        "Explicit paid-test acknowledgement is required"
    );
    let path =
        |name| PathBuf::from(env::var(name).expect("Explicit live-probe file path is required"));
    let key_file = path("SONORA_LIVE_ALIGNMENT_KEY_FILE");
    let audio_file = path("SONORA_LIVE_ALIGNMENT_WAV");
    let text_file = path("SONORA_LIVE_ALIGNMENT_TEXT");
    let output = path("SONORA_LIVE_ALIGNMENT_OUTPUT");
    assert!(fs::metadata(&key_file).unwrap().len() <= 4096);
    let key = fs::read_to_string(key_file).unwrap().trim().to_owned();
    let audio = fs::read(audio_file).unwrap();
    assert!(
        (32044..=320044).contains(&audio.len()),
        "Paid probe is limited to ten seconds of canonical PCM audio"
    );
    let text = fs::read_to_string(text_file).unwrap();
    assert!(
        text.len() <= 1000,
        "Only the short synthetic test transcript is permitted"
    );
    let root = TempDir::new().unwrap();
    let mut config = Config::default();
    config.cache.path = root.path().join("cache.sqlite");
    config.metadata.path = root.path().join("metadata.sqlite");
    config.elevenlabs.api_key = Some(key);
    // The paid scheduler also enforces zero retries regardless of this setting.
    config.network.max_retries = 0;
    let client = Client::new(config).unwrap();
    let result = client
        .align(audio.into(), text.clone(), Priority::Interactive)
        .await
        .expect(
            "The single approved provider request failed; it must not be automatically repeated",
        );
    assert_eq!(result.data.plain_lyrics, text);
    assert!(result.data.synced_lyrics.starts_with('['));
    assert_eq!(result.cache, "miss");
    fs::write(output, serde_json::to_vec_pretty(&result).unwrap()).unwrap();
    // No second provider request: persistent reuse is covered by the synthetic integration tests.
}
