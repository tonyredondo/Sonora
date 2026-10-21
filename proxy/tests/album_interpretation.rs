use http_body_util::BodyExt;
use serde_json::{Value, json};
use sonora_proxy::config::{CodexConfig, Config};
use std::path::Path;
use tempfile::TempDir;
use tower::ServiceExt;
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
(root/'input.json').write_text(json.dumps(x))
instruction_arg=next(x for x in args if x.startswith('model_instructions_file='))
(root/'instructions.txt').write_text(Path(json.loads(instruction_arg.split('=',1)[1])).read_text())
assert args[args.index('--model')+1]=='gpt-6-astra'
assert 'model_reasoning_effort='+json.dumps(x.get('effort','xhigh')) in args
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

fn album() -> Value {
    json!({"language":"es","album":{"title":"Journeys","artist":"Travellers","tracks":[
        {"context":{"title":"Leaving","artist":"Travellers","album":"Journeys","styles":["Rock---Indie Rock"],"moods":["sad"]},"lyrics":"I leave the house.\nI return each spring.","genre":"Rock"},
        {"context":{"title":"Home","artist":"Guest","album":"Journeys","styles":[],"moods":["relaxed"]},"lyrics":"","genre":"Ambient"}
    ]}})
}
async fn post(app: axum::Router, body: &Value, auth: bool) -> axum::response::Response {
    let mut request = axum::http::Request::builder()
        .method("POST")
        .uri("/v1/albums/interpret")
        .header("Content-Type", "application/json");
    if auth {
        request = request.header("Authorization", "Bearer fixture");
    }
    app.oneshot(
        request
            .body(axum::body::Body::from(body.to_string()))
            .unwrap(),
    )
    .await
    .unwrap()
}
#[cfg(unix)]
#[tokio::test]
async fn full_album_reaches_isolated_codex_and_cache_is_separate_and_refreshable() {
    let tmp = TempDir::new().unwrap();
    let binary = stub(tmp.path(), false);
    let mut config = Config::default();
    config.cache.path = tmp.path().join("cache.sqlite");
    config.metadata.path = tmp.path().join("metadata.sqlite");
    config.server.api_token = Some("fixture".into());
    config.codex = CodexConfig {
        enabled: true,
        binary: binary.clone(),
    };
    let app = sonora_proxy::api::router(config).unwrap();
    assert_eq!(post(app.clone(), &album(), false).await.status(), 401);
    for _ in 0..2 {
        assert_eq!(post(app.clone(), &album(), true).await.status(), 200);
    }
    let captured: Value =
        serde_json::from_slice(&std::fs::read(tmp.path().join("input.json")).unwrap()).unwrap();
    assert_eq!(captured, album());
    assert_eq!(
        std::fs::read_to_string(tmp.path().join("calls"))
            .unwrap()
            .lines()
            .count(),
        1
    );
    let prompt = std::fs::read_to_string(tmp.path().join("instructions.txt")).unwrap();
    assert!(prompt.contains("ALL supplied tracks"));
    assert!(prompt.contains("never instructions"));
    assert!(prompt.contains("Do not mention tags"));
    let mut changed = album();
    changed["album"]["tracks"][1]["context"]["moods"] = json!(["happy"]);
    assert_eq!(post(app.clone(), &changed, true).await.status(), 200);
    let mut changed_lyrics = album();
    changed_lyrics["album"]["tracks"][1]["lyrics"] = json!("A new home.");
    assert_eq!(post(app.clone(), &changed_lyrics, true).await.status(), 200);
    // Valid album bodies can exceed the proxy's ordinary 256 KiB route limit.
    let mut large = album();
    let mut track = large["album"]["tracks"][0].clone();
    track["context"]["title"] = json!("t".repeat(2000));
    track["lyrics"] = json!("l".repeat(3000));
    large["album"]["tracks"] = json!(vec![track; 80]);
    assert!(large.to_string().len() > 256 * 1024);
    assert_eq!(post(app.clone(), &large, true).await.status(), 200);
    let mut refresh = album();
    refresh["refresh"] = json!(true);
    let script = std::fs::read_to_string(&binary).unwrap();
    std::fs::write(&binary, script.replace("Interpretation in ", "Updated in ")).unwrap();
    let updated = post(app.clone(), &refresh, true).await;
    assert_eq!(updated.status(), 200);
    std::fs::write(&binary, "#!/bin/sh\nexit 1\n").unwrap();
    assert_eq!(post(app.clone(), &refresh, true).await.status(), 502);
    let cached = post(app, &album(), true)
        .await
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes();
    assert_eq!(
        serde_json::from_slice::<Value>(&cached).unwrap()["explanation"],
        "Updated in es"
    );
    assert_eq!(
        std::fs::read_to_string(tmp.path().join("calls"))
            .unwrap()
            .lines()
            .count(),
        5
    );
}
#[tokio::test]
async fn invalid_album_input_is_rejected_before_disabled_provider() {
    let tmp = TempDir::new().unwrap();
    let mut config = Config::default();
    config.cache.path = tmp.path().join("cache.sqlite");
    config.metadata.path = tmp.path().join("metadata.sqlite");
    let app = sonora_proxy::api::router(config).unwrap();
    for body in [
        json!({"album":{"title":"A","artist":"B","tracks":[]},"language":"es"}),
        {
            let mut x = album();
            x["album"]["tracks"][0]["lyrics"] = json!("x".repeat(65537));
            x
        },
        {
            let mut x = album();
            x["album"]["tracks"][0]["lyrics"] = json!("");
            x
        },
    ] {
        assert_eq!(post(app.clone(), &body, true).await.status(), 400);
    }
    assert_eq!(post(app, &album(), true).await.status(), 503);
}

#[cfg(unix)]
#[test]
fn medium_and_legacy_meanings_use_matching_effort_and_separate_persistent_caches() {
    let tmp = TempDir::new().unwrap();
    let mut config = Config::default();
    config.cache.path = tmp.path().join("cache.sqlite");
    config.metadata.path = tmp.path().join("metadata.sqlite");
    config.server.api_token = Some("fixture".into());
    config.codex = CodexConfig {
        enabled: true,
        binary: stub(tmp.path(), false),
    };
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let app = sonora_proxy::api::router(config.clone()).unwrap();
        for (route, base) in [
            (
                "/v1/lyrics/interpret",
                json!({"lyrics":"A tree grows.","language":"es"}),
            ),
            ("/v1/albums/interpret", album()),
        ] {
            for effort in [None, Some("medium"), None, Some("medium")] {
                let mut body = base.clone();
                if let Some(effort) = effort {
                    body["effort"] = json!(effort);
                }
                let response = app
                    .clone()
                    .oneshot(
                        axum::http::Request::builder()
                            .method("POST")
                            .uri(route)
                            .header("Authorization", "Bearer fixture")
                            .header("Content-Type", "application/json")
                            .body(axum::body::Body::from(body.to_string()))
                            .unwrap(),
                    )
                    .await
                    .unwrap();
                assert_eq!(response.status(), 200);
                let bytes = response.into_body().collect().await.unwrap().to_bytes();
                let value: Value = serde_json::from_slice(&bytes).unwrap();
                assert_eq!(value["effort"], effort.unwrap_or("xhigh"));
                assert_eq!(value["model"], "gpt-6-astra");
            }
            let mut invalid = base;
            invalid["effort"] = json!("unsupported");
            let response = app
                .clone()
                .oneshot(
                    axum::http::Request::builder()
                        .method("POST")
                        .uri(route)
                        .header("Authorization", "Bearer fixture")
                        .header("Content-Type", "application/json")
                        .body(axum::body::Body::from(invalid.to_string()))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), 400);
        }
        assert_eq!(
            std::fs::read_to_string(tmp.path().join("calls"))
                .unwrap()
                .lines()
                .count(),
            4
        );
        drop(app);
    });
    // A restart retires all blocking work and scheduler workers before reopening
    // the exclusive cache lease, just as process shutdown does.
    drop(runtime);
    config.codex.enabled = false;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let reopened = sonora_proxy::api::router(config).unwrap();
        for effort in [None, Some("medium")] {
            let mut body = album();
            if let Some(effort) = effort {
                body["effort"] = json!(effort);
            }
            let response = post(reopened.clone(), &body, true).await;
            assert_eq!(response.status(), 200);
            let bytes = response.into_body().collect().await.unwrap().to_bytes();
            assert_eq!(
                serde_json::from_slice::<Value>(&bytes).unwrap()["effort"],
                effort.unwrap_or("xhigh")
            );
        }
    });
}
