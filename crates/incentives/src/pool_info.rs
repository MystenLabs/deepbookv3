// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Query pool metadata and coin decimals/symbols directly from a SUI full node
//! via JSON-RPC, so the scoring engine does not depend on the indexer's `pools`
//! table being backfilled.

use anyhow::{anyhow, Context, Result};
use reqwest::Client;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::types::PoolMetadata;

/// Fetch [`PoolMetadata`] for a DeepBook pool from the SUI full node.
///
/// 1. `sui_getObject` with `showType` to read the `Pool<Base, Quote>` type string.
/// 2. Parse the two type parameters out of the generic type.
/// 3. `suix_getCoinMetadata` for each coin type → decimals + symbol.
pub async fn fetch_pool_metadata_from_node(
    client: &Client,
    rpc_url: &str,
    pool_id: &str,
) -> Result<PoolMetadata> {
    let obj = rpc_call(
        client,
        rpc_url,
        "sui_getObject",
        json!([pool_id, { "showType": true }]),
    )
    .await
    .context("sui_getObject for pool")?;

    let type_str = obj
        .pointer("/data/type")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("pool object missing /data/type"))?;

    let (base_type, quote_type) = parse_pool_type_params(type_str)
        .ok_or_else(|| anyhow!("could not parse Pool<Base,Quote> from type: {type_str}"))?;

    let (base_decimals, base_symbol) =
        fetch_coin_metadata(client, rpc_url, &base_type).await?;
    let (quote_decimals, quote_symbol) =
        fetch_coin_metadata(client, rpc_url, &quote_type).await?;

    Ok(PoolMetadata {
        base_decimals,
        base_symbol,
        quote_decimals,
        quote_symbol,
    })
}

/// Extract `(BaseType, QuoteType)` from a fully-qualified Move type string like
/// `0xpkg::pool::Pool<0xbase::mod::Coin, 0xquote::mod::Coin>`.
///
/// Handles nested generics by counting angle-bracket depth so commas inside
/// nested `<>` are not treated as the top-level separator.
fn parse_pool_type_params(type_str: &str) -> Option<(String, String)> {
    let open = type_str.find('<')?;
    let close = type_str.rfind('>')?;
    if close <= open + 1 {
        return None;
    }
    let inner = &type_str[open + 1..close];

    // Walk forward, tracking <> depth, to find the top-level comma.
    let mut depth = 0i32;
    let mut split_pos = None;
    for (i, ch) in inner.char_indices() {
        match ch {
            '<' => depth += 1,
            '>' => depth -= 1,
            ',' if depth == 0 => {
                split_pos = Some(i);
                break;
            }
            _ => {}
        }
    }

    let pos = split_pos?;
    let base = inner[..pos].trim().to_string();
    let quote = inner[pos + 1..].trim().to_string();
    if base.is_empty() || quote.is_empty() {
        return None;
    }
    Some((base, quote))
}

/// Call `suix_getCoinMetadata` and return `(decimals, symbol)`.
async fn fetch_coin_metadata(
    client: &Client,
    rpc_url: &str,
    coin_type: &str,
) -> Result<(u8, String)> {
    let resp = rpc_call(
        client,
        rpc_url,
        "suix_getCoinMetadata",
        json!([coin_type]),
    )
    .await
    .with_context(|| format!("suix_getCoinMetadata for {coin_type}"))?;

    let decimals = resp
        .get("decimals")
        .and_then(|v| v.as_u64())
        .ok_or_else(|| anyhow!("missing decimals in CoinMetadata for {coin_type}"))?
        as u8;

    let symbol = resp
        .get("symbol")
        .and_then(|v| v.as_str())
        .unwrap_or("???")
        .to_string();

    Ok((decimals, symbol))
}

/// Low-level JSON-RPC 2.0 helper. Returns the `result` field on success.
async fn rpc_call(
    client: &Client,
    rpc_url: &str,
    method: &str,
    params: Value,
) -> Result<Value> {
    #[derive(Deserialize)]
    struct RpcResponse {
        result: Option<Value>,
        error: Option<Value>,
    }

    let body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });

    let resp: RpcResponse = client
        .post(rpc_url)
        .json(&body)
        .send()
        .await
        .with_context(|| format!("POST {rpc_url} ({method})"))?
        .json()
        .await
        .with_context(|| format!("parsing JSON-RPC response for {method}"))?;

    if let Some(err) = resp.error {
        return Err(anyhow!("JSON-RPC error from {method}: {err}"));
    }

    resp.result
        .ok_or_else(|| anyhow!("JSON-RPC response for {method} has neither result nor error"))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_simple_pool_type() {
        let ty = "0xdee9::pool::Pool<0xabc::sui::SUI, 0xdef::usdc::USDC>";
        let (base, quote) = parse_pool_type_params(ty).unwrap();
        assert_eq!(base, "0xabc::sui::SUI");
        assert_eq!(quote, "0xdef::usdc::USDC");
    }

    #[test]
    fn parse_nested_generics() {
        let ty = "0xpkg::pool::Pool<0xa::m::Coin<0xb::n::T>, 0xc::m::Coin<0xd::n::U>>";
        let (base, quote) = parse_pool_type_params(ty).unwrap();
        assert_eq!(base, "0xa::m::Coin<0xb::n::T>");
        assert_eq!(quote, "0xc::m::Coin<0xd::n::U>");
    }

    #[test]
    fn parse_no_angle_brackets() {
        assert!(parse_pool_type_params("0xpkg::pool::Pool").is_none());
    }
}
