use std::process::Command;
use tempfile::TempDir;

#[test]
fn configuration_check_uses_explicit_file_and_never_echoes_secrets_or_creates_cache() {
    let directory = TempDir::new().unwrap();
    let file = directory.path().join("config.toml");
    std::fs::write(
        &file,
        "[cache]\npath='cache/data.sqlite'\n[acoustid]\nclient_key='test-secret-cli-only'\n",
    )
    .unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_sonora-proxy"))
        .args(["--config", file.to_str().unwrap(), "--check-config"])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("configuration valid"));
    assert!(!directory.path().join("cache").exists());
    std::fs::write(
        &file,
        "[server]\napi_token='test-secret-cli-only'\nlisten=42",
    )
    .unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_sonora-proxy"))
        .args(["--config", file.to_str().unwrap(), "--check-config"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(!String::from_utf8_lossy(&output.stderr).contains("test-secret-cli-only"));
}

#[test]
fn example_configuration_can_be_validated_without_credentials() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("sonora-proxy.example.toml");
    let output = Command::new(env!("CARGO_BIN_EXE_sonora-proxy"))
        .args(["--config", path.to_str().unwrap(), "--check-config"])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}
