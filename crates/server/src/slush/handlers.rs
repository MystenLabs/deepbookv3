// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Handler implementations for the Slush DeFi Quickstart Provider API v1.1.0.
//! Each handler corresponds to an endpoint in the OpenAPI spec.

use std::collections::HashMap;
use std::str::FromStr;
use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use deepbook_schema::models::{AssetSupplied, AssetWithdrawn, MarginPoolCreated};
use deepbook_schema::schema;
use diesel::{ExpressionMethods, QueryDsl, SelectableHelper};

use crate::error::DeepBookError;
use crate::server::AppState;

use super::types::*;

use sui_json_rpc_types::SuiObjectDataOptions;
use sui_types::base_types::{ObjectID, SequenceNumber, SuiAddress};
use sui_types::programmable_transaction_builder::ProgrammableTransactionBuilder;
use sui_types::transaction::{
    Argument, CallArg, Command, ObjectArg, ProgrammableMoveCall, TransactionKind,
};
use sui_types::type_input::TypeInput;
use sui_types::TypeTag;

const MARGIN_POOL_MODULE: &str = "margin_pool";
const SUI_CLOCK_OBJECT_ID: &str =
    "0x0000000000000000000000000000000000000000000000000000000000000006";

/// Default MarginRegistry shared object ID (mainnet).
const DEFAULT_MARGIN_REGISTRY_ID: &str =
    "0x0e40998b359a9ccbab22a98ed21bd4346abf19158bc7980c8291908086b3a742";

/// DeepBook app URL for constructing strategy/position links.
const DEEPBOOK_APP_URL: &str = "https://deepbook.tech";

/// DeepBook icon URL.
const DEEPBOOK_ICON_URL: &str = "https://deepbook.tech/favicon.ico";

/// Scaling factor for interest rate (9 decimal fixed-point).
const RATE_SCALE: f64 = 1_000_000_000.0;

// === Metadata Endpoints ===

/// GET /v1/version — return spec version
pub async fn get_version() -> Json<OpenApiVersionResponse> {
    Json(OpenApiVersionResponse {
        version: "1.1.0".to_string(),
    })
}

/// GET /v1/provider — return DeepBook provider metadata
pub async fn get_provider(
    State(state): State<Arc<AppState>>,
) -> Result<Json<ProviderMetadataResponse>, DeepBookError> {
    // Compute total TVL from all margin pools
    let tvl_usd = compute_total_tvl_usd(&state).await.unwrap_or(0.0);

    Ok(Json(ProviderMetadataResponse {
        provider: ProviderMetadata {
            name: "DeepBook".to_string(),
            description: "DeepBook is a decentralized order book and margin lending protocol on the Sui blockchain.".to_string(),
            tvl_usd,
            launch_year: 2024,
            app_url: DEEPBOOK_APP_URL.to_string(),
            icon_url: DEEPBOOK_ICON_URL.to_string(),
        },
    }))
}

// === Strategy Endpoints ===

/// GET /v1/strategies — list all margin pool lending strategies
pub async fn list_strategies(
    State(state): State<Arc<AppState>>,
) -> Result<Json<ListStrategiesResponse>, DeepBookError> {
    let strategies = build_all_strategies(&state).await?;
    Ok(Json(ListStrategiesResponse { strategies }))
}

/// GET /v1/strategies/{strategyId} — get a single strategy by pool ID
pub async fn get_strategy(
    Path(strategy_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<GetStrategyResponse>, DeepBookError> {
    let strategies = build_all_strategies(&state).await?;
    let strategy = strategies
        .into_iter()
        .find(|s| s.id == strategy_id)
        .ok_or_else(|| DeepBookError::not_found(format!("Strategy {}", strategy_id)))?;

    Ok(Json(GetStrategyResponse { strategy }))
}

// === Position Endpoints ===

/// GET /v1/positions?address={address} — list user positions
pub async fn list_positions(
    Query(params): Query<PositionsQuery>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<ListPositionsResponse>, DeepBookError> {
    let address = &params.address;
    let positions = build_positions_for_address(&state, address).await?;
    Ok(Json(ListPositionsResponse { positions }))
}

/// GET /v1/positions/{positionId} — get a single position by SupplierCap object ID
pub async fn get_position(
    Path(position_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<GetPositionResponse>, DeepBookError> {
    let position = build_position_by_id(&state, &position_id).await?;
    Ok(Json(GetPositionResponse { position }))
}

// === Transaction Endpoints ===

/// POST /v1/deposit — build a deposit PTB with placeholder coin
pub async fn create_deposit(
    State(state): State<Arc<AppState>>,
    Json(req): Json<DepositRequest>,
) -> Result<Json<DepositResponse>, (StatusCode, Json<TransactionBuildError>)> {
    build_deposit_tx(&state, &req).await.map_err(|e| {
        (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(TransactionBuildError {
                tag: "TransactionBuildError".to_string(),
                message: Some(e.to_string()),
            }),
        )
    })
}

/// POST /v1/withdraw — build a withdraw PTB
pub async fn create_withdraw(
    State(state): State<Arc<AppState>>,
    Json(req): Json<WithdrawRequest>,
) -> Result<Json<WithdrawResponse>, (StatusCode, Json<TransactionBuildError>)> {
    build_withdraw_tx(&state, &req).await.map_err(|e| {
        (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(TransactionBuildError {
                tag: "TransactionBuildError".to_string(),
                message: Some(e.to_string()),
            }),
        )
    })
}

/// POST /v1/withdraw/cancel — DeepBook withdrawals are instant, so return 501
pub async fn cancel_withdraw() -> impl IntoResponse {
    (
        StatusCode::NOT_IMPLEMENTED,
        Json(NotImplementedError {
            tag: "NotImplementedError".to_string(),
        }),
    )
}

// === Internal Helpers ===

/// Normalize an asset type string to ensure it has a lowercase 0x prefix.
fn normalize_asset_type(asset_type: &str) -> String {
    if let Some(rest) = asset_type.strip_prefix("0x") {
        format!("0x{}", rest)
    } else if let Some(rest) = asset_type.strip_prefix("0X") {
        format!("0x{}", rest)
    } else {
        format!("0x{}", asset_type)
    }
}

/// Query all margin pools from the DB and build Strategy objects.
async fn build_all_strategies(state: &AppState) -> Result<Vec<Strategy>, DeepBookError> {
    let margin_package_id = state
        .margin_package_id()
        .ok_or_else(|| DeepBookError::bad_request("Margin package ID not configured"))?
        .to_string();

    // Query all pools
    let query = schema::margin_pool_created::table
        .select(MarginPoolCreated::as_select())
        .order_by(schema::margin_pool_created::checkpoint_timestamp_ms.desc());
    let pools: Vec<MarginPoolCreated> = state.reader().results(query).await?;

    // Deduplicate by margin_pool_id (keep latest entry)
    let mut seen = std::collections::HashSet::new();
    let unique_pools: Vec<&MarginPoolCreated> = pools
        .iter()
        .filter(|p| seen.insert(p.margin_pool_id.clone()))
        .collect();

    let sui_client = state.sui_client().await?;
    let package = ObjectID::from_hex_literal(&margin_package_id)
        .map_err(|e| DeepBookError::bad_request(format!("Invalid margin package ID: {}", e)))?;

    let mut strategies = Vec::new();

    for pool in unique_pools {
        let pool_id_str = &pool.margin_pool_id;
        let asset_type = &pool.asset_type;
        let normalized = normalize_asset_type(asset_type);

        // Parse asset type
        let type_tag = match TypeTag::from_str(&normalized) {
            Ok(t) => t,
            Err(_) => continue,
        };

        let pool_object_id = match ObjectID::from_hex_literal(pool_id_str) {
            Ok(id) => id,
            Err(_) => continue,
        };

        // Get pool object for shared version
        let pool_object = match sui_client
            .read_api()
            .get_object_with_options(
                pool_object_id,
                SuiObjectDataOptions::full_content().with_owner(),
            )
            .await
        {
            Ok(obj) => obj,
            Err(_) => continue,
        };

        let pool_data = match pool_object.data.as_ref() {
            Some(d) => d,
            None => continue,
        };

        let initial_shared_version = match &pool_data.owner {
            Some(sui_types::object::Owner::Shared {
                initial_shared_version,
            }) => *initial_shared_version,
            _ => continue,
        };

        // Query pool state via RPC (total_supply, total_borrow, interest_rate)
        let pool_state = query_pool_state_for_strategy(
            sui_client,
            package,
            pool_object_id,
            initial_shared_version,
            &type_tag,
        )
        .await;

        let (total_supply, total_borrow, interest_rate) = match pool_state {
            Ok(s) => s,
            Err(_) => continue,
        };

        // Compute APY from interest rate and utilization
        let current_apy = compute_supply_apy(interest_rate, total_supply, total_borrow);

        // Count depositors: distinct suppliers from asset_supplied minus fully-withdrawn
        let depositors_count =
            count_depositors(state, pool_id_str).await.unwrap_or(0);

        // TODO: volume_24h computation requires a price oracle for USD conversion.
        // See compute_volume_24h() for the base-unit implementation when ready.

        // Build strategy
        let coin_type = normalized.clone();
        let asset_name = asset_type
            .rsplit("::")
            .next()
            .unwrap_or(asset_type);

        strategies.push(Strategy {
            id: pool_id_str.clone(),
            type_tag: "StrategyV1".to_string(),
            strategy_type: "LENDING".to_string(),
            coin_type: coin_type.clone(),
            min_deposit: vec![CoinValue {
                coin_type: coin_type.clone(),
                amount: "0".to_string(),
                value_usd: None,
            }],
            apy: ApyInfo {
                current: current_apy,
                // For rolling averages, use current as initial approximation.
                // A production implementation would aggregate from historical
                // InterestParamsUpdated events or a time-series store.
                avg24h: current_apy,
                avg7d: current_apy,
                avg30d: current_apy,
            },
            depositors_count,
            tvl_usd: 0.0, // Requires price oracle for USD conversion
            volume24h_usd: 0.0, // Requires price oracle for USD conversion
            fees: FeesInfo {
                deposit_bps: "0".to_string(),
                withdraw_bps: "0".to_string(),
            },
            url: Some(format!(
                "{}/earn/{}",
                DEEPBOOK_APP_URL, asset_name
            )),
        });
    }

    Ok(strategies)
}

/// Query pool state (total_supply, total_borrow, interest_rate) via RPC dev_inspect.
async fn query_pool_state_for_strategy(
    sui_client: &sui_sdk::SuiClient,
    package: ObjectID,
    pool_id: ObjectID,
    initial_shared_version: SequenceNumber,
    type_tag: &TypeTag,
) -> Result<(u64, u64, u64), DeepBookError> {
    let mut ptb = ProgrammableTransactionBuilder::new();

    // Input 0: Pool object (immutable for read-only queries)
    let pool_input = CallArg::Object(ObjectArg::SharedObject {
        id: pool_id,
        initial_shared_version,
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    });
    ptb.input(pool_input)?;

    let type_input = TypeInput::from(type_tag.clone());
    let type_args = vec![type_input];

    // Command 0: total_supply<Asset>(pool)
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package,
        module: MARGIN_POOL_MODULE.to_string(),
        function: "total_supply".to_string(),
        type_arguments: type_args.clone(),
        arguments: vec![Argument::Input(0)],
    })));

    // Command 1: total_borrow<Asset>(pool)
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package,
        module: MARGIN_POOL_MODULE.to_string(),
        function: "total_borrow".to_string(),
        type_arguments: type_args.clone(),
        arguments: vec![Argument::Input(0)],
    })));

    // Command 2: interest_rate<Asset>(pool)
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package,
        module: MARGIN_POOL_MODULE.to_string(),
        function: "interest_rate".to_string(),
        type_arguments: type_args,
        arguments: vec![Argument::Input(0)],
    })));

    let builder = ptb.finish();
    let tx = TransactionKind::ProgrammableTransaction(builder);

    let inspect_result = sui_client
        .read_api()
        .dev_inspect_transaction_block(SuiAddress::default(), tx, None, None, None)
        .await?;

    let results = inspect_result
        .results
        .ok_or_else(|| DeepBookError::rpc("No results from dev_inspect"))?;

    let total_supply = extract_u64(&results, 0, "total_supply")?;
    let total_borrow = extract_u64(&results, 1, "total_borrow")?;
    let interest_rate = extract_u64(&results, 2, "interest_rate")?;

    Ok((total_supply, total_borrow, interest_rate))
}

/// Extract a u64 value from dev_inspect results at the given index.
fn extract_u64(
    results: &[sui_json_rpc_types::SuiExecutionResult],
    index: usize,
    func_name: &str,
) -> Result<u64, DeepBookError> {
    let result = results
        .get(index)
        .ok_or_else(|| DeepBookError::rpc(format!("Missing result for {}", func_name)))?;
    let bytes = result
        .return_values
        .first()
        .ok_or_else(|| DeepBookError::rpc(format!("No return value for {}", func_name)))?;
    let value: u64 = bcs::from_bytes(&bytes.0)
        .map_err(|e| DeepBookError::deserialization(format!("{}: {}", func_name, e)))?;
    Ok(value)
}

/// Compute supply APY from on-chain interest rate and utilization.
/// The interest rate from the contract is the borrow rate in 9-decimal fixed-point.
/// Supply APY = borrow_rate * utilization, where utilization = total_borrow / total_supply.
fn compute_supply_apy(interest_rate: u64, total_supply: u64, total_borrow: u64) -> f64 {
    if total_supply == 0 {
        return 0.0;
    }
    let borrow_rate = interest_rate as f64 / RATE_SCALE;
    let utilization = total_borrow as f64 / total_supply as f64;
    borrow_rate * utilization
}

/// Count distinct depositors (suppliers) for a pool who have a positive net balance.
/// Uses indexed asset_supplied and asset_withdrawn events.
async fn count_depositors(state: &AppState, pool_id: &str) -> Result<i64, DeepBookError> {
    let pool_id_owned = pool_id.to_string();

    // Get all supply events for this pool
    let supplied: Vec<AssetSupplied> = state
        .reader()
        .results(
            schema::asset_supplied::table
                .select(AssetSupplied::as_select())
                .filter(schema::asset_supplied::margin_pool_id.eq(pool_id_owned.clone())),
        )
        .await?;

    // Get all withdraw events for this pool
    let withdrawn: Vec<AssetWithdrawn> = state
        .reader()
        .results(
            schema::asset_withdrawn::table
                .select(AssetWithdrawn::as_select())
                .filter(schema::asset_withdrawn::margin_pool_id.eq(pool_id_owned)),
        )
        .await?;

    // Aggregate net shares per supplier_cap_id
    let mut net_shares: HashMap<String, i64> = HashMap::new();
    for s in &supplied {
        *net_shares.entry(s.supplier.clone()).or_default() += s.shares;
    }
    for w in &withdrawn {
        *net_shares.entry(w.supplier.clone()).or_default() -= w.shares;
    }

    // Distinct suppliers with positive balance, mapped to unique senders
    let mut active_senders: std::collections::HashSet<String> = std::collections::HashSet::new();
    let supplier_to_sender: HashMap<String, String> = supplied
        .iter()
        .map(|s| (s.supplier.clone(), s.sender.clone()))
        .collect();

    for (supplier, shares) in &net_shares {
        if *shares > 0 {
            if let Some(sender) = supplier_to_sender.get(supplier) {
                active_senders.insert(sender.clone());
            }
        }
    }

    Ok(active_senders.len() as i64)
}

/// Compute 24h volume from supply/withdraw events (in base units).
/// Compute 24h volume from supply/withdraw events (in base units).
/// NOTE: Currently unused since USD conversion requires a price oracle.
/// This will be called from build_all_strategies once the oracle is integrated.
#[allow(dead_code)]
async fn compute_volume_24h(state: &AppState, pool_id: &str) -> Result<i64, DeepBookError> {
    let pool_id_owned = pool_id.to_string();

    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| DeepBookError::internal("System time error"))?
        .as_millis() as i64;
    let start_ms = now_ms - 24 * 60 * 60 * 1000;

    let supplied: Vec<AssetSupplied> = state
        .reader()
        .results(
            schema::asset_supplied::table
                .select(AssetSupplied::as_select())
                .filter(schema::asset_supplied::margin_pool_id.eq(pool_id_owned.clone()))
                .filter(schema::asset_supplied::checkpoint_timestamp_ms.between(start_ms, now_ms)),
        )
        .await?;

    let withdrawn: Vec<AssetWithdrawn> = state
        .reader()
        .results(
            schema::asset_withdrawn::table
                .select(AssetWithdrawn::as_select())
                .filter(schema::asset_withdrawn::margin_pool_id.eq(pool_id_owned))
                .filter(
                    schema::asset_withdrawn::checkpoint_timestamp_ms.between(start_ms, now_ms),
                ),
        )
        .await?;

    let supply_vol: i64 = supplied.iter().map(|s| s.amount).sum();
    let withdraw_vol: i64 = withdrawn.iter().map(|w| w.amount).sum();

    Ok(supply_vol + withdraw_vol)
}

/// Compute total TVL in USD across all margin pools.
/// Currently returns 0.0 as USD conversion requires a price oracle.
async fn compute_total_tvl_usd(_state: &AppState) -> Result<f64, DeepBookError> {
    // TODO: integrate price oracle for USD conversion
    Ok(0.0)
}

/// Build positions for a given wallet address.
async fn build_positions_for_address(
    state: &AppState,
    address: &str,
) -> Result<Vec<Position>, DeepBookError> {
    let address_owned = address.to_string();

    // Get all supply events where sender = address
    let supplied: Vec<AssetSupplied> = state
        .reader()
        .results(
            schema::asset_supplied::table
                .select(AssetSupplied::as_select())
                .filter(schema::asset_supplied::sender.eq(address_owned.clone())),
        )
        .await?;

    if supplied.is_empty() {
        return Ok(vec![]);
    }

    // Get all withdraw events where sender = address
    let withdrawn: Vec<AssetWithdrawn> = state
        .reader()
        .results(
            schema::asset_withdrawn::table
                .select(AssetWithdrawn::as_select())
                .filter(schema::asset_withdrawn::sender.eq(address_owned)),
        )
        .await?;

    // Group by (supplier_cap_id, margin_pool_id, asset_type) → net amounts and shares
    #[derive(Default)]
    struct PositionAgg {
        margin_pool_id: String,
        asset_type: String,
        total_supplied_amount: i64,
        total_withdrawn_amount: i64,
        total_supplied_shares: i64,
        total_withdrawn_shares: i64,
    }

    let mut positions_map: HashMap<String, PositionAgg> = HashMap::new();

    for s in &supplied {
        let entry = positions_map.entry(s.supplier.clone()).or_default();
        entry.margin_pool_id = s.margin_pool_id.clone();
        entry.asset_type = s.asset_type.clone();
        entry.total_supplied_amount += s.amount;
        entry.total_supplied_shares += s.shares;
    }

    for w in &withdrawn {
        if let Some(entry) = positions_map.get_mut(&w.supplier) {
            entry.total_withdrawn_amount += w.amount;
            entry.total_withdrawn_shares += w.shares;
        }
    }

    // Build Position objects for non-zero balances
    let mut positions = Vec::new();
    for (supplier_cap_id, agg) in &positions_map {
        let net_shares = agg.total_supplied_shares - agg.total_withdrawn_shares;
        if net_shares <= 0 {
            continue;
        }

        let net_amount = agg.total_supplied_amount - agg.total_withdrawn_amount;
        let coin_type = normalize_asset_type(&agg.asset_type);
        let asset_name = agg
            .asset_type
            .rsplit("::")
            .next()
            .unwrap_or(&agg.asset_type);

        // Principal = net deposited amount (supplied - withdrawn)
        // Pending rewards = difference between current share value and principal
        // (computing exact pending rewards requires on-chain exchange rate query)
        positions.push(Position {
            id: supplier_cap_id.clone(),
            strategy_id: agg.margin_pool_id.clone(),
            type_tag: "PositionV1".to_string(),
            principal: CoinValue {
                coin_type: coin_type.clone(),
                amount: net_amount.to_string(),
                value_usd: None,
            },
            pending_rewards: vec![CoinValue {
                coin_type: coin_type.clone(),
                amount: "0".to_string(),
                value_usd: None,
            }],
            balance: None,
            url: format!("{}/earn/{}", DEEPBOOK_APP_URL, asset_name),
        });
    }

    Ok(positions)
}

/// Build a single position by SupplierCap object ID.
async fn build_position_by_id(
    state: &AppState,
    position_id: &str,
) -> Result<Position, DeepBookError> {
    let position_id_owned = position_id.to_string();

    // Get all supply events for this supplier_cap_id
    let supplied: Vec<AssetSupplied> = state
        .reader()
        .results(
            schema::asset_supplied::table
                .select(AssetSupplied::as_select())
                .filter(schema::asset_supplied::supplier.eq(position_id_owned.clone())),
        )
        .await?;

    if supplied.is_empty() {
        return Err(DeepBookError::not_found(format!(
            "Position {}",
            position_id
        )));
    }

    let withdrawn: Vec<AssetWithdrawn> = state
        .reader()
        .results(
            schema::asset_withdrawn::table
                .select(AssetWithdrawn::as_select())
                .filter(schema::asset_withdrawn::supplier.eq(position_id_owned)),
        )
        .await?;

    let first = &supplied[0];
    let margin_pool_id = first.margin_pool_id.clone();
    let asset_type = first.asset_type.clone();
    let coin_type = normalize_asset_type(&asset_type);
    let asset_name = asset_type.rsplit("::").next().unwrap_or(&asset_type);

    let total_supplied: i64 = supplied.iter().map(|s| s.amount).sum();
    let total_withdrawn: i64 = withdrawn.iter().map(|w| w.amount).sum();
    let net_amount = total_supplied - total_withdrawn;

    Ok(Position {
        id: position_id.to_string(),
        strategy_id: margin_pool_id,
        type_tag: "PositionV1".to_string(),
        principal: CoinValue {
            coin_type: coin_type.clone(),
            amount: net_amount.to_string(),
            value_usd: None,
        },
        pending_rewards: vec![CoinValue {
            coin_type: coin_type.clone(),
            amount: "0".to_string(),
            value_usd: None,
        }],
        balance: None,
        url: format!("{}/earn/{}", DEEPBOOK_APP_URL, asset_name),
    })
}

/// Build a deposit PTB with a placeholder coin for Slush wallet injection.
///
/// The PTB structure:
///   Input 0: Clock (shared, immutable)
///   Input 1: MarginPool (shared, mutable)
///   Input 2: MarginRegistry (shared, immutable)
///   Input 3: None (pure, for referral Option<ID>)
///   Command 0: margin_pool::mint_supplier_cap(clock) → SupplierCap
///   Command 1: 0x0::placeholder::coin<Asset>() → Coin<Asset>
///   Command 2: margin_pool::supply<Asset>(pool, registry, supplier_cap, coin, none, clock)
///
/// The Slush wallet replaces the placeholder coin call with actual coin selection.
async fn build_deposit_tx(
    state: &AppState,
    req: &DepositRequest,
) -> Result<Json<DepositResponse>, DeepBookError> {
    let margin_package_id = state
        .margin_package_id()
        .ok_or_else(|| DeepBookError::bad_request("Margin package ID not configured"))?
        .to_string();

    let package = ObjectID::from_hex_literal(&margin_package_id)?;
    let pool_object_id = ObjectID::from_hex_literal(&req.strategy_id)?;
    let coin_type = normalize_asset_type(&req.coin_type);
    let type_tag = TypeTag::from_str(&coin_type)?;
    let type_input = TypeInput::from(type_tag);

    let sui_client = state.sui_client().await?;

    // Get pool object for shared version
    let pool_object = sui_client
        .read_api()
        .get_object_with_options(
            pool_object_id,
            SuiObjectDataOptions::full_content().with_owner(),
        )
        .await?;

    let pool_data = pool_object
        .data
        .as_ref()
        .ok_or(DeepBookError::rpc("Missing pool object data"))?;

    let pool_initial_version = match &pool_data.owner {
        Some(sui_types::object::Owner::Shared {
            initial_shared_version,
        }) => *initial_shared_version,
        _ => return Err(DeepBookError::bad_request("Pool is not a shared object")),
    };

    // Get MarginRegistry object
    let registry_id = ObjectID::from_hex_literal(
            state.margin_registry_id().unwrap_or(DEFAULT_MARGIN_REGISTRY_ID),
        )?;
    let registry_object = sui_client
        .read_api()
        .get_object_with_options(
            registry_id,
            SuiObjectDataOptions::full_content().with_owner(),
        )
        .await?;

    let registry_data = registry_object
        .data
        .as_ref()
        .ok_or(DeepBookError::rpc("Missing registry object data"))?;

    let registry_initial_version = match &registry_data.owner {
        Some(sui_types::object::Owner::Shared {
            initial_shared_version,
        }) => *initial_shared_version,
        _ => {
            return Err(DeepBookError::bad_request(
                "Registry is not a shared object",
            ))
        }
    };

    let clock_id = ObjectID::from_hex_literal(SUI_CLOCK_OBJECT_ID)?;

    let mut ptb = ProgrammableTransactionBuilder::new();

    // Input 0: Clock
    let clock_input = CallArg::Object(ObjectArg::SharedObject {
        id: clock_id,
        initial_shared_version: SequenceNumber::from_u64(1),
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    });
    ptb.input(clock_input)?;

    // Input 1: MarginPool (mutable for supply)
    let pool_input = CallArg::Object(ObjectArg::SharedObject {
        id: pool_object_id,
        initial_shared_version: pool_initial_version,
        mutability: sui_types::transaction::SharedObjectMutability::Mutable,
    });
    ptb.input(pool_input)?;

    // Input 2: MarginRegistry (immutable)
    let registry_input = CallArg::Object(ObjectArg::SharedObject {
        id: registry_id,
        initial_shared_version: registry_initial_version,
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    });
    ptb.input(registry_input)?;

    // Input 3: None referral (pure Option<ID>)
    let none_referral: Option<ObjectID> = None;
    ptb.input(CallArg::Pure(bcs::to_bytes(&none_referral).map_err(
        |e| DeepBookError::internal(format!("BCS serialization error: {}", e)),
    )?))?;

    // Command 0: mint_supplier_cap(clock) → SupplierCap
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package,
        module: MARGIN_POOL_MODULE.to_string(),
        function: "mint_supplier_cap".to_string(),
        type_arguments: vec![],
        arguments: vec![Argument::Input(0)], // clock
    })));

    // Command 1: placeholder::coin<Asset>() → Coin<Asset>
    // The Slush wallet recognizes this placeholder and replaces it with actual coin selection.
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: ObjectID::ZERO,
        module: "placeholder".to_string(),
        function: "coin".to_string(),
        type_arguments: vec![type_input.clone()],
        arguments: vec![],
    })));

    // Command 2: supply<Asset>(pool, registry, supplier_cap, coin, referral, clock)
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package,
        module: MARGIN_POOL_MODULE.to_string(),
        function: "supply".to_string(),
        type_arguments: vec![type_input],
        arguments: vec![
            Argument::Input(1),  // pool
            Argument::Input(2),  // registry
            Argument::Result(0), // supplier_cap from mint_supplier_cap
            Argument::Result(1), // coin from placeholder
            Argument::Input(3),  // referral (None)
            Argument::Input(0),  // clock
        ],
    })));

    // Serialize the transaction kind
    let builder = ptb.finish();
    let tx_kind = TransactionKind::ProgrammableTransaction(builder);
    let tx_bytes = bcs::to_bytes(&tx_kind)
        .map_err(|e| DeepBookError::internal(format!("Failed to serialize transaction: {}", e)))?;
    let tx_b64 = base64_encode(&tx_bytes);

    Ok(Json(DepositResponse {
        bytes: tx_b64,
        net_deposit: CoinValue {
            coin_type: coin_type.clone(),
            amount: "0".to_string(), // Amount is determined by Slush wallet
            value_usd: None,
        },
        fees: None,
    }))
}

/// Build a withdraw PTB using the user's SupplierCap.
async fn build_withdraw_tx(
    state: &AppState,
    req: &WithdrawRequest,
) -> Result<Json<WithdrawResponse>, DeepBookError> {
    let margin_package_id = state
        .margin_package_id()
        .ok_or_else(|| DeepBookError::bad_request("Margin package ID not configured"))?
        .to_string();

    let package = ObjectID::from_hex_literal(&margin_package_id)?;
    let coin_type = normalize_asset_type(&req.principal.coin_type);

    // For mode="usdc" on non-USDC pools, return an error
    if req.mode == "usdc"
        && !coin_type.ends_with("::usdc::USDC")
        && !coin_type.ends_with("::USDC")
    {
        return Err(DeepBookError::bad_request(
            "mode=usdc is only supported for USDC pools. Use mode=as-is for other coin types.",
        ));
    }

    let type_tag = TypeTag::from_str(&coin_type)?;
    let type_input = TypeInput::from(type_tag);

    // Look up the position to find the associated margin pool
    let position_id_owned = req.position_id.clone();
    let supplied: Vec<AssetSupplied> = state
        .reader()
        .results(
            schema::asset_supplied::table
                .select(AssetSupplied::as_select())
                .filter(schema::asset_supplied::supplier.eq(position_id_owned)),
        )
        .await?;

    if supplied.is_empty() {
        return Err(DeepBookError::not_found(format!(
            "Position {}",
            req.position_id
        )));
    }

    let pool_id_str = &supplied[0].margin_pool_id;
    let pool_object_id = ObjectID::from_hex_literal(pool_id_str)?;

    let sui_client = state.sui_client().await?;

    // Get pool object
    let pool_object = sui_client
        .read_api()
        .get_object_with_options(
            pool_object_id,
            SuiObjectDataOptions::full_content().with_owner(),
        )
        .await?;

    let pool_data = pool_object
        .data
        .as_ref()
        .ok_or(DeepBookError::rpc("Missing pool object data"))?;

    let pool_initial_version = match &pool_data.owner {
        Some(sui_types::object::Owner::Shared {
            initial_shared_version,
        }) => *initial_shared_version,
        _ => return Err(DeepBookError::bad_request("Pool is not a shared object")),
    };

    // Get MarginRegistry object
    let registry_id = ObjectID::from_hex_literal(
            state.margin_registry_id().unwrap_or(DEFAULT_MARGIN_REGISTRY_ID),
        )?;
    let registry_object = sui_client
        .read_api()
        .get_object_with_options(
            registry_id,
            SuiObjectDataOptions::full_content().with_owner(),
        )
        .await?;

    let registry_data = registry_object
        .data
        .as_ref()
        .ok_or(DeepBookError::rpc("Missing registry object data"))?;

    let registry_initial_version = match &registry_data.owner {
        Some(sui_types::object::Owner::Shared {
            initial_shared_version,
        }) => *initial_shared_version,
        _ => {
            return Err(DeepBookError::bad_request(
                "Registry is not a shared object",
            ))
        }
    };

    // Get SupplierCap object (owned by user)
    let supplier_cap_id = ObjectID::from_hex_literal(&req.position_id)?;
    let supplier_cap_object = sui_client
        .read_api()
        .get_object_with_options(
            supplier_cap_id,
            SuiObjectDataOptions::full_content().with_owner(),
        )
        .await?;

    let supplier_cap_data = supplier_cap_object
        .data
        .as_ref()
        .ok_or(DeepBookError::rpc("Missing SupplierCap object data"))?;

    let supplier_cap_ref = supplier_cap_data.object_ref();

    // Parse withdraw amount
    let withdraw_amount: u64 = req
        .principal
        .amount
        .parse()
        .map_err(|_| DeepBookError::bad_request("Invalid withdraw amount"))?;

    let clock_id = ObjectID::from_hex_literal(SUI_CLOCK_OBJECT_ID)?;

    let mut ptb = ProgrammableTransactionBuilder::new();

    // Input 0: MarginPool (mutable for withdraw)
    let pool_input = CallArg::Object(ObjectArg::SharedObject {
        id: pool_object_id,
        initial_shared_version: pool_initial_version,
        mutability: sui_types::transaction::SharedObjectMutability::Mutable,
    });
    ptb.input(pool_input)?;

    // Input 1: MarginRegistry (immutable)
    let registry_input = CallArg::Object(ObjectArg::SharedObject {
        id: registry_id,
        initial_shared_version: registry_initial_version,
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    });
    ptb.input(registry_input)?;

    // Input 2: SupplierCap (owned by sender)
    let supplier_cap_input = CallArg::Object(ObjectArg::ImmOrOwnedObject(supplier_cap_ref));
    ptb.input(supplier_cap_input)?;

    // Input 3: withdraw amount as Option<u64>
    let amount_option: Option<u64> = Some(withdraw_amount);
    ptb.input(CallArg::Pure(bcs::to_bytes(&amount_option).map_err(
        |e| DeepBookError::internal(format!("BCS serialization error: {}", e)),
    )?))?;

    // Input 4: Clock
    let clock_input = CallArg::Object(ObjectArg::SharedObject {
        id: clock_id,
        initial_shared_version: SequenceNumber::from_u64(1),
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    });
    ptb.input(clock_input)?;

    // Command 0: withdraw<Asset>(pool, registry, supplier_cap, amount, clock)
    // Returns Coin<Asset> which is automatically transferred to sender
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package,
        module: MARGIN_POOL_MODULE.to_string(),
        function: "withdraw".to_string(),
        type_arguments: vec![type_input],
        arguments: vec![
            Argument::Input(0), // pool
            Argument::Input(1), // registry
            Argument::Input(2), // supplier_cap
            Argument::Input(3), // amount
            Argument::Input(4), // clock
        ],
    })));

    // Serialize the transaction kind
    let builder = ptb.finish();
    let tx_kind = TransactionKind::ProgrammableTransaction(builder);
    let tx_bytes = bcs::to_bytes(&tx_kind)
        .map_err(|e| DeepBookError::internal(format!("Failed to serialize transaction: {}", e)))?;
    let tx_b64 = base64_encode(&tx_bytes);

    Ok(Json(WithdrawResponse {
        bytes: tx_b64,
        principal: CoinValue {
            coin_type: coin_type.clone(),
            amount: withdraw_amount.to_string(),
            value_usd: None,
        },
        rewards: vec![],
        fees: None,
    }))
}

/// Base64 encode bytes using standard encoding (with padding).
fn base64_encode(bytes: &[u8]) -> String {
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine;
    STANDARD.encode(bytes)
}
