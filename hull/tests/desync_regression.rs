//! Regression tests for audit §2.C-01 — the hull's /commit and
//! /settle handlers must propagate kernel rejection back to the
//! HTTP caller instead of silently overwriting local state with a
//! root the settle kernel has not attested.
//!
//! The settle kernel's `%register` cause is single-shot per
//! `hull_id`. After the first /commit, a second /commit poke
//! produces an empty effect list (handle-register returns ~) and
//! pre-fix the hull returned HTTP 200 with the new (unattested)
//! root anyway. These tests fail against pre-fix code; they exist
//! to keep the fix from regressing.

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tokio::sync::Mutex;
use tower::ServiceExt;

use hull::api::{router, AppState};
use hull::config::{resolve_with_demo_key_checked, HullConfig, SettlementCliOverrides};
use nockapp::kernel::boot;

async fn boot_state() -> Arc<Mutex<AppState>> {
    // Disable auth on loopback — the static flag is process-wide,
    // so the first test to call this wins, but every test wants
    // the same behaviour.
    hull::api::check_auth_config_with_bind(true, "127.0.0.1").expect("loopback no-auth");

    let cli = boot::default_boot_cli(false);
    let app = boot::setup(kernels_settle::KERNEL, cli, &[], "hull-desync-test", None)
        .await
        .expect("settle kernel boot");

    let toml = HullConfig::default();
    let settlement = resolve_with_demo_key_checked(&SettlementCliOverrides::default(), &toml)
        .expect("default settlement resolves to Local mode");

    let tmp = tempfile::tempdir().expect("tempdir");
    let output_dir = tmp.keep();

    Arc::new(Mutex::new(AppState {
        app,
        fields: Vec::new(),
        tree: None,
        hull_id: 1,
        note_counter: 0,
        settlement,
        output_dir,
    }))
}

async fn json_post(app: axum::Router, uri: &str, body: &str) -> (StatusCode, Vec<u8>) {
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(uri)
                .header("content-type", "application/json")
                .body(Body::from(body.to_owned()))
                .unwrap(),
        )
        .await
        .expect("oneshot");
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes().to_vec();
    (status, bytes)
}

async fn get(app: axum::Router, uri: &str) -> (StatusCode, Vec<u8>) {
    let resp = app
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .expect("oneshot");
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes().to_vec();
    (status, bytes)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn double_commit_returns_409() {
    let state = boot_state().await;

    let body_a = r#"{"fields":[{"key":"k","value":"v1"}]}"#;
    let (status, _) = json_post(router(state.clone()), "/commit", body_a).await;
    assert_eq!(status, StatusCode::OK, "first /commit must succeed");

    let body_b = r#"{"fields":[{"key":"k","value":"v2"}]}"#;
    let (status, _) = json_post(router(state.clone()), "/commit", body_b).await;
    assert_eq!(
        status,
        StatusCode::CONFLICT,
        "second /commit must be rejected by the kernel — empty effect list"
    );

    let st = state.lock().await;
    assert_eq!(st.fields.len(), 1, "local state unchanged after rejection");
    assert_eq!(st.fields[0].value, "v1", "first commit's value retained");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn settle_after_commit_returns_409() {
    let state = boot_state().await;

    let body = r#"{"fields":[{"key":"a","value":"1"}]}"#;
    let (status, _) = json_post(router(state.clone()), "/commit", body).await;
    assert_eq!(status, StatusCode::OK, "/commit must succeed first");

    // /settle currently builds a %register poke (audit §2.C-01
    // disposition: deferred to docs/AUDIT_C01_FOLLOWUP.md). With
    // hull_id already registered, the kernel returns ~; the fix
    // makes this surface as 409.
    let (status, _) = json_post(router(state.clone()), "/settle", "{}").await;
    assert_eq!(
        status,
        StatusCode::CONFLICT,
        "/settle re-pokes %register and the kernel rejects the duplicate"
    );

    let st = state.lock().await;
    assert_eq!(st.note_counter, 0, "counter must not advance on rejected settle");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn commit_success_path_still_updates_state() {
    let state = boot_state().await;

    let body = r#"{"fields":[{"key":"x","value":"y"}]}"#;
    let (status, _) = json_post(router(state.clone()), "/commit", body).await;
    assert_eq!(status, StatusCode::OK);

    let (status, bytes) = get(router(state.clone()), "/status").await;
    assert_eq!(status, StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&bytes).expect("status returns JSON");
    assert_eq!(body["has_tree"], serde_json::Value::Bool(true));
    assert_eq!(body["field_count"], serde_json::Value::from(1u64));
    assert!(body["merkle_root"].as_str().is_some());
}
