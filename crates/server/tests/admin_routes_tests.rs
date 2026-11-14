use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::Router;
use http_body_util::BodyExt;
use prometheus::Registry;
use serde_json::{json, Value};
use std::sync::Arc;
use sui_pg_db::temp::TempDb;
use sui_pg_db::{Db, DbArgs};
use tower::ServiceExt;
use url::Url;

use deepbook_server::{
    pyth::{PythProConfig, DEFAULT_PRO_URL},
    server::{make_router, AppState},
};

const TOKEN: &str = "test-admin-token";
const POOL_ID: &str = "0xpool";
const BASE: &str = "0x2::sui::SUI";
const QUOTE: &str = "0xdba3::usdc::USDC";

async fn setup() -> (TempDb, Router) {
    let temp_db = TempDb::new().expect("postgres binaries must be on PATH");
    let url: Url = temp_db.database().url().clone();
    let db = Db::for_write(url.clone(), DbArgs::default()).await.unwrap();
    db.run_migrations(Some(&deepbook_schema::MIGRATIONS))
        .await
        .unwrap();

    let registry = Registry::new();
    let rpc_url: Url = "http://localhost:1/".parse().unwrap();
    let state = Arc::new(
        AppState::new(
            url,
            DbArgs::default(),
            &registry,
            rpc_url,
            "deepbook-package".to_string(),
            "deep-token-package".to_string(),
            "deep-treasury".to_string(),
            Some(TOKEN.to_string()),
            None,
            100,
            Url::parse(DEFAULT_PRO_URL).unwrap(),
            None,
            PythProConfig::default(),
        )
        .await
        .unwrap(),
    );

    (temp_db, make_router(state))
}

async fn call(
    router: &Router,
    method: &str,
    uri: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut request = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {TOKEN}"));
    let body = match body {
        Some(body) => {
            request = request.header("content-type", "application/json");
            Body::from(body.to_string())
        }
        None => Body::empty(),
    };
    let response = router
        .clone()
        .oneshot(request.body(body).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn pools(router: &Router) -> Vec<Value> {
    let (status, body) = call(router, "GET", "/get_pools", None).await;
    assert_eq!(status, StatusCode::OK);
    body.as_array().unwrap().clone()
}

fn pool_request() -> Value {
    json!({
        "pool_id": POOL_ID,
        "pool_name": "SUI_USDC",
        "base_asset_id": BASE,
        "base_asset_decimals": 9,
        "base_asset_symbol": "SUI",
        "base_asset_name": "Sui",
        "quote_asset_id": QUOTE,
        "quote_asset_decimals": 6,
        "quote_asset_symbol": "USDC",
        "quote_asset_name": "USDC",
        "min_size": 1000,
        "lot_size": 1000,
        "tick_size": 10000000
    })
}

#[tokio::test]
async fn update_and_delete_routes_match_path_ids() {
    let (_db, router) = setup().await;

    let (status, _) = call(&router, "POST", "/admin/pools", Some(pool_request())).await;
    assert_eq!(status, StatusCode::OK);

    let (status, body) = call(
        &router,
        "PUT",
        &format!("/admin/pools/{POOL_ID}"),
        Some(json!({ "pool_name": "SUI_USDC_RENAMED", "tick_size": 1000 })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let pool = pools(&router).await.pop().unwrap();
    assert_eq!(pool["pool_name"], "SUI_USDC_RENAMED");
    assert_eq!(pool["tick_size"], 1000);

    let (status, body) = call(&router, "DELETE", &format!("/admin/pools/{POOL_ID}"), None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(pools(&router).await.is_empty());

    let (status, _) = call(&router, "DELETE", &format!("/admin/pools/{POOL_ID}"), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn delete_asset_route_matches_a_coin_type() {
    let (_db, router) = setup().await;

    let (status, _) = call(
        &router,
        "POST",
        "/admin/assets",
        Some(json!({
            "asset_type": BASE,
            "name": "Sui",
            "symbol": "SUI",
            "decimals": 9,
            "ucid": null,
            "package_id": null,
            "package_address_url": null
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    let (status, body) = call(&router, "DELETE", &format!("/admin/assets/{BASE}"), None).await;
    assert_eq!(status, StatusCode::OK, "{body}");

    let (status, _) = call(&router, "DELETE", &format!("/admin/assets/{BASE}"), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}
