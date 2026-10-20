use http_body_util::BodyExt;
use serde_json::json;
use sonora_proxy::{
    cache::Cache,
    config::{CodexConfig, Config},
    interpretation::{InterpretationInput, InterpretationService},
};
use std::{path::Path, time::Duration};
use tempfile::TempDir;
use tower::ServiceExt;

fn input(language: &str) -> InterpretationInput {
    InterpretationInput {
        lyrics: "I plant a tree beside the old gate. Each spring I return to see how it grows."
            .into(),
        language: language.into(),
        refresh: false,
    }
}
fn cache(root: &Path) -> Cache {
    Cache::open(&root.join("cache.sqlite"), 1_000_000, 100).unwrap()
}
#[cfg(unix)]
fn stub(root: &Path, sleep: bool) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let bin = root.join("codex-stub");
    let script = format!(
        r#"#!/usr/bin/python3
import sys,json,os,time
from pathlib import Path
root=Path({root:?})
x=json.load(sys.stdin)
args=sys.argv
assert args[args.index('--model')+1]=='gpt-6-astra'
assert 'model_reasoning_effort="xhigh"' in args
assert '--ignore-user-config' in args and '--ephemeral' in args
assert args[args.index('--sandbox')+1]=='read-only'
assert 'OPENAI_API_KEY' not in os.environ
with (root/'calls').open('a') as f:f.write('call\n')
(root/'pid').write_text(str(os.getpid()))
if {sleep}:time.sleep(30)
print(json.dumps({{'type':'item.completed','item':{{'type':'agent_message','text':'I will interpret the supplied text.'}}}}))
print(json.dumps({{'type':'item.completed','item':{{'type':'agent_message','text':json.dumps({{'explanation':'Interpretation in '+x['language']}})}}}}))
print(json.dumps({{'type':'turn.completed'}}))
"#,
        root = root.to_str().unwrap(),
        sleep = if sleep { "True" } else { "False" }
    );
    std::fs::write(&bin, script).unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o700)).unwrap();
    bin
}
#[cfg(unix)]
#[tokio::test]
async fn explicit_refresh_bypasses_cache_and_failure_preserves_last_good_result() {
    let tmp = TempDir::new().unwrap();
    let binary = stub(tmp.path(), false);
    let mut cfg = Config::default();
    cfg.cache.path = tmp.path().join("cache.sqlite");
    cfg.metadata.path = tmp.path().join("metadata.sqlite");
    cfg.server.api_token = Some("test-token".into());
    cfg.codex = CodexConfig {
        enabled: true,
        binary: binary.clone(),
    };
    let app = sonora_proxy::api::router(cfg).unwrap();
    for (body, expected) in [
        (
            json!({"lyrics":"A tree grows","language":"es"}),
            "Interpretation in es",
        ),
        (
            json!({"lyrics":"A tree grows","language":"es","refresh":true}),
            "Updated in es",
        ),
        (
            json!({"lyrics":"A tree grows","language":"es"}),
            "Updated in es",
        ),
    ] {
        let request = axum::http::Request::builder()
            .method("POST")
            .uri("/v1/lyrics/interpret")
            .header("Authorization", "Bearer test-token")
            .header("Content-Type", "application/json")
            .body(axum::body::Body::from(body.to_string()))
            .unwrap();
        let response = app.clone().oneshot(request).await.unwrap();
        assert_eq!(response.status().as_u16(), 200);
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&bytes).unwrap()["explanation"],
            expected
        );
        let script = std::fs::read_to_string(&binary).unwrap();
        std::fs::write(&binary, script.replace("Interpretation in ", "Updated in ")).unwrap();
    }
    assert_eq!(
        std::fs::read_to_string(tmp.path().join("calls"))
            .unwrap()
            .lines()
            .count(),
        2
    );
    std::fs::write(&binary, "#!/usr/bin/python3\nimport sys\nsys.exit(1)\n").unwrap();
    drop(app); // Release the router's exclusive cache lease before reopening it.
    let service = InterpretationService::new(
        CodexConfig {
            enabled: true,
            binary,
        },
        cache(tmp.path()),
    );
    let request = InterpretationInput {
        lyrics: "A tree grows".into(),
        language: "es".into(),
        refresh: true,
    };
    assert!(service.interpret(request.clone()).await.is_err());
    let cached = service
        .interpret(InterpretationInput {
            refresh: false,
            ..request
        })
        .await
        .unwrap();
    assert_eq!(cached.explanation, "Updated in es");
}

#[cfg(unix)]
#[tokio::test]
async fn identical_requests_share_cached_result_and_cache_survives_restart() {
    let tmp = TempDir::new().unwrap();
    let service = InterpretationService::new(
        CodexConfig {
            enabled: true,
            binary: stub(tmp.path(), false),
        },
        cache(tmp.path()),
    );
    let (a, b) = tokio::join!(
        service.interpret(input("es")),
        service.interpret(input("es"))
    );
    assert_eq!(a.unwrap().explanation, b.unwrap().explanation);
    assert_eq!(
        std::fs::read_to_string(tmp.path().join("calls"))
            .unwrap()
            .lines()
            .count(),
        1
    );
    service.interpret(input("en")).await.unwrap();
    assert_eq!(
        std::fs::read_to_string(tmp.path().join("calls"))
            .unwrap()
            .lines()
            .count(),
        2
    );
    drop(service);
    let restarted = InterpretationService::new(CodexConfig::default(), cache(tmp.path()));
    assert!(restarted.interpret(input("es")).await.is_ok());
    assert!(restarted.interpret(input("fr")).await.is_err());
}
#[cfg(unix)]
#[tokio::test]
async fn cancellation_stops_owned_child_and_releases_queue() {
    let tmp = TempDir::new().unwrap();
    let service = InterpretationService::new(
        CodexConfig {
            enabled: true,
            binary: stub(tmp.path(), true),
        },
        cache(tmp.path()),
    );
    let copy = service.clone();
    let task = tokio::spawn(async move { copy.interpret(input("es")).await });
    let file = tmp.path().join("pid");
    for _ in 0..100 {
        if file.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let pid = std::fs::read_to_string(&file).unwrap();
    task.abort();
    let _ = task.await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let alive = std::process::Command::new("kill")
        .args(["-0", &pid])
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success();
    assert!(
        !alive,
        "Cancelled analysis must not leave a Codex process running"
    );
    stub(tmp.path(), false);
    assert!(service.interpret(input("es")).await.is_ok());
}

#[cfg(unix)]
#[tokio::test]
async fn failed_process_output_is_not_cached_and_can_be_retried() {
    for suffix in [
        "print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':'not JSON'}}))",
        "print(json.dumps({'type':'turn.failed','error':{'message':'usage_limit_reached'}}))",
        "print('x' * 1_048_577)",
        "sys.exit(1)",
    ] {
        let tmp = TempDir::new().unwrap();
        let binary = stub(tmp.path(), false);
        let script = std::fs::read_to_string(&binary).unwrap();
        std::fs::write(&binary, format!("{script}\n{suffix}\n")).unwrap();
        let service = InterpretationService::new(
            CodexConfig {
                enabled: true,
                binary,
            },
            cache(tmp.path()),
        );
        let failed = tokio::time::timeout(Duration::from_secs(5), service.interpret(input("es")))
            .await
            .expect("Invalid output must not leave the worker blocked");
        assert!(failed.is_err());
        stub(tmp.path(), false);
        let value = tokio::time::timeout(Duration::from_secs(5), service.interpret(input("es")))
            .await
            .expect("The worker must accept a retry")
            .unwrap();
        assert_eq!(value.explanation, "Interpretation in es");
        assert_eq!(
            std::fs::read_to_string(tmp.path().join("calls"))
                .unwrap()
                .lines()
                .count(),
            2,
            "An earlier valid message from a failed process must never be cached"
        );
    }
}

#[tokio::test]
async fn api_authentication_and_disabled_state_do_not_start_codex() {
    let tmp = TempDir::new().unwrap();
    let mut cfg = Config::default();
    cfg.cache.path = tmp.path().join("cache.sqlite");
    cfg.metadata.path = tmp.path().join("metadata.sqlite");
    cfg.server.api_token = Some("test-token".into());
    let app = sonora_proxy::api::router(cfg).unwrap();
    for (token, status) in [("wrong", 401), ("test-token", 503)] {
        let request = axum::http::Request::builder()
            .method("POST")
            .uri("/v1/lyrics/interpret")
            .header("Authorization", format!("Bearer {token}"))
            .header("Content-Type", "application/json")
            .body(axum::body::Body::from(
                json!({"lyrics":"Some lyrics","language":"es"}).to_string(),
            ))
            .unwrap();
        let r = app.clone().oneshot(request).await.unwrap();
        assert_eq!(r.status().as_u16(), status);
        if status == 503 {
            let body = r.into_body().collect().await.unwrap().to_bytes();
            assert_eq!(
                serde_json::from_slice::<serde_json::Value>(&body).unwrap()["error"],
                "codex_disabled"
            );
        }
    }
}

/// Explicit opt-in only. Uses synthetic lyrics and the host user's existing Codex session.
#[tokio::test]
#[ignore = "requires explicit approval to use Codex plan usage"]
async fn live_codex_astra_xhigh_interpretation_and_cache() {
    let binary = std::env::var_os("SONORA_LIVE_CODEX")
        .expect("set SONORA_LIVE_CODEX to the approved binary");
    let tmp = TempDir::new().unwrap();
    let service = InterpretationService::new(
        CodexConfig {
            enabled: true,
            binary: binary.into(),
        },
        cache(tmp.path()),
    );
    let value = service.interpret(input("es")).await.unwrap();
    assert!(!value.explanation.is_empty());
    assert!(value.explanation.split_whitespace().count() > 20);
    println!(
        "Synthetic lyric interpreted with {} / {} ({} characters)",
        value.model,
        value.effort,
        value.explanation.len()
    );
    drop(service);
    let cached = InterpretationService::new(CodexConfig::default(), cache(tmp.path()));
    assert_eq!(
        value.explanation,
        cached.interpret(input("es")).await.unwrap().explanation
    );
}
