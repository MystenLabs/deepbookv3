use crate::schema::{
    // Margin Pool Operations Events
    asset_supplied,
    asset_withdrawn,
    balances,
    // Collateral Events (deposit/withdraw)
    collateral_events,
    // TPSL (Take Profit/Stop Loss) Events
    conditional_order_events,
    deep_burned,
    deepbook_pool_config_updated,
    deepbook_pool_registered,
    deepbook_pool_updated,
    deepbook_pool_updated_registry,
    flashloans,
    interest_params_updated,
    liquidation,
    loan_borrowed,
    loan_repaid,
    // Margin Registry Events
    maintainer_cap_updated,
    maintainer_fees_withdrawn,
    // Margin Manager Events
    margin_manager_created,
    margin_manager_state,
    margin_pool_config_updated,
    // Margin Pool Admin Events
    margin_pool_created,
    // snapshots for analytics
    margin_pool_snapshots,
    order_fills,
    order_updates,
    pause_cap_updated,
    points,
    pool_created,
    pool_prices,
    pools,
    proposals,
    protocol_fees_increased,
    protocol_fees_withdrawn,
    rebates,
    referral_fee_events,
    referral_fees_claimed,
    stakes,
    sui_error_transactions,
    supplier_cap_minted,
    supply_referral_minted,
    trade_params_update,
    votes,
};
use bigdecimal::BigDecimal;
use diesel::deserialize::FromSql;
use diesel::pg::{Pg, PgValue};
use diesel::serialize::{Output, ToSql};
use diesel::sql_types::Text;
use diesel::{AsExpression, Identifiable, Insertable, Queryable, QueryableByName, Selectable};
use serde::{Serialize, Serializer};
use std::str::FromStr;
use strum_macros::{AsRefStr, EnumString};
use sui_field_count::FieldCount;

fn serialize_bigdecimal_option<S>(
    value: &Option<BigDecimal>,
    serializer: S,
) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    match value {
        Some(v) => serializer.serialize_some(&v.to_string()),
        None => serializer.serialize_none(),
    }
}

fn serialize_datetime<S>(value: &chrono::NaiveDateTime, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    serializer.serialize_str(&value.to_string())
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = order_updates, primary_key(event_digest))]
pub struct OrderUpdate {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub status: OrderUpdateStatus,
    pub pool_id: String,
    pub order_id: String, // u128
    pub client_order_id: i64,
    pub price: i64,
    pub is_bid: bool,
    pub original_quantity: i64,
    pub quantity: i64,
    pub filled_quantity: i64,
    pub onchain_timestamp: i64,
    pub trader: String,
    pub balance_manager_id: String,
}

#[derive(Debug, AsExpression, EnumString, AsRefStr)]
#[diesel(sql_type = Text)]
pub enum OrderUpdateStatus {
    Placed,
    Modified,
    Canceled,
    Expired,
}

impl FromSql<Text, Pg> for OrderUpdateStatus {
    fn from_sql(bytes: PgValue<'_>) -> diesel::deserialize::Result<Self> {
        let s = std::str::from_utf8(bytes.as_bytes())?;
        Ok(OrderUpdateStatus::from_str(s)?)
    }
}

impl ToSql<Text, Pg> for OrderUpdateStatus {
    fn to_sql<'b>(&'b self, out: &mut Output<'b, '_, Pg>) -> diesel::serialize::Result {
        <str as ToSql<Text, Pg>>::to_sql(self.as_ref(), out)
    }
}

#[derive(Debug, Clone, QueryableByName, Serialize)]
pub struct OrderStatus {
    #[diesel(sql_type = diesel::sql_types::Text)]
    pub order_id: String,
    #[diesel(sql_type = diesel::sql_types::Text)]
    pub balance_manager_id: String,
    #[diesel(sql_type = diesel::sql_types::Bool)]
    pub is_bid: bool,
    #[diesel(sql_type = diesel::sql_types::Text)]
    pub current_status: String,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub price: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub placed_at: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub last_updated_at: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub original_quantity: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub filled_quantity: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub remaining_quantity: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = order_fills, primary_key(event_digest))]
pub struct OrderFill {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_id: String,
    pub maker_order_id: String, // u128
    pub taker_order_id: String, // u128
    pub maker_client_order_id: i64,
    pub taker_client_order_id: i64,
    pub price: i64,
    pub taker_fee: i64,
    pub taker_fee_is_deep: bool,
    pub maker_fee: i64,
    pub maker_fee_is_deep: bool,
    pub taker_is_bid: bool,
    pub base_quantity: i64,
    pub quote_quantity: i64,
    pub maker_balance_manager_id: String,
    pub taker_balance_manager_id: String,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, FieldCount)]
pub struct OrderFillSummary {
    pub pool_id: String,
    pub maker_balance_manager_id: String,
    pub taker_balance_manager_id: String,
    pub quantity: i64,
}

#[derive(QueryableByName, Debug, Serialize, FieldCount)]
pub struct BalancesSummary {
    #[diesel(sql_type = Text)]
    pub asset: String,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub amount: i64,
    #[diesel(sql_type = diesel::sql_types::Bool)]
    pub deposit: bool,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = flashloans, primary_key(event_digest))]
pub struct Flashloan {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_id: String,
    pub borrow_quantity: i64,
    pub borrow: bool,
    pub type_name: String,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = pool_prices, primary_key(event_digest))]
pub struct PoolPrice {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub target_pool: String,
    pub reference_pool: String,
    pub conversion_rate: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = balances, primary_key(event_digest))]
pub struct Balances {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub balance_manager_id: String,
    pub asset: String,
    pub amount: i64,
    pub deposit: bool,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = deep_burned, primary_key(event_digest))]
pub struct DeepBurned {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_id: String,
    pub burned_amount: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = pool_created, primary_key(event_digest))]
pub struct PoolCreated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_id: String,
    pub taker_fee: i64,
    pub maker_fee: i64,
    pub tick_size: i64,
    pub lot_size: i64,
    pub min_size: i64,
    pub whitelisted_pool: bool,
    pub treasury_address: String,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = proposals, primary_key(event_digest))]
pub struct Proposals {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_id: String,
    pub balance_manager_id: String,
    pub epoch: i64,
    pub taker_fee: i64,
    pub maker_fee: i64,
    pub stake_required: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = rebates, primary_key(event_digest))]
pub struct Rebates {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_id: String,
    pub balance_manager_id: String,
    pub epoch: i64,
    pub claim_amount: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = referral_fee_events, primary_key(event_digest))]
pub struct ReferralFeeEvent {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_id: String,
    pub referral_id: String,
    pub base_fee: i64,
    pub quote_fee: i64,
    pub deep_fee: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = stakes, primary_key(event_digest))]
pub struct Stakes {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_id: String,
    pub balance_manager_id: String,
    pub epoch: i64,
    pub amount: i64,
    pub stake: bool,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = trade_params_update, primary_key(event_digest))]
pub struct TradeParamsUpdate {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_id: String,
    pub taker_fee: i64,
    pub maker_fee: i64,
    pub stake_required: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = votes, primary_key(event_digest))]
pub struct Votes {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_id: String,
    pub balance_manager_id: String,
    pub epoch: i64,
    pub from_proposal_id: Option<String>,
    pub to_proposal_id: String,
    pub stake: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = pools, primary_key(pool_id))]
pub struct Pools {
    pub pool_id: String,
    pub pool_name: String,
    pub base_asset_id: String,
    pub base_asset_decimals: i16,
    pub base_asset_symbol: String,
    pub base_asset_name: String,
    pub quote_asset_id: String,
    pub quote_asset_decimals: i16,
    pub quote_asset_symbol: String,
    pub quote_asset_name: String,
    pub min_size: i64,
    pub lot_size: i64,
    pub tick_size: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = sui_error_transactions, primary_key(txn_digest))]
pub struct SuiErrorTransactions {
    pub txn_digest: String,
    pub sender_address: String,
    pub timestamp_ms: i64,
    pub failure_status: String,
    pub package: String,
    pub cmd_idx: Option<i64>,
}

// === Margin Manager Events ===
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = margin_manager_created, primary_key(event_digest))]
pub struct MarginManagerCreated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_manager_id: String,
    pub balance_manager_id: String,
    pub deepbook_pool_id: Option<String>,
    pub owner: String,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = loan_borrowed, primary_key(event_digest))]
pub struct LoanBorrowed {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_manager_id: String,
    pub margin_pool_id: String,
    pub loan_amount: i64,
    pub loan_shares: i64,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = loan_repaid, primary_key(event_digest))]
pub struct LoanRepaid {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_manager_id: String,
    pub margin_pool_id: String,
    pub repay_amount: i64,
    pub repay_shares: i64,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = liquidation, primary_key(event_digest))]
pub struct Liquidation {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_manager_id: String,
    pub margin_pool_id: String,
    pub liquidation_amount: i64,
    pub pool_reward: i64,
    pub pool_default: i64,
    pub risk_ratio: i64,
    pub onchain_timestamp: i64,
    pub remaining_base_asset: BigDecimal,
    pub remaining_quote_asset: BigDecimal,
    pub remaining_base_debt: BigDecimal,
    pub remaining_quote_debt: BigDecimal,
    pub base_pyth_price: i64,
    pub base_pyth_decimals: i16,
    pub quote_pyth_price: i64,
    pub quote_pyth_decimals: i16,
}

// === Margin Pool Operations Events ===
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = asset_supplied, primary_key(event_digest))]
pub struct AssetSupplied {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_pool_id: String,
    pub asset_type: String,
    pub supplier: String,
    pub amount: i64,
    pub shares: i64,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = asset_withdrawn, primary_key(event_digest))]
pub struct AssetWithdrawn {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_pool_id: String,
    pub asset_type: String,
    pub supplier: String,
    pub amount: i64,
    pub shares: i64,
    pub onchain_timestamp: i64,
}

// === Margin Pool Admin Events ===
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = margin_pool_created, primary_key(event_digest))]
pub struct MarginPoolCreated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_pool_id: String,
    pub maintainer_cap_id: String,
    pub asset_type: String,
    pub config_json: serde_json::Value,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = deepbook_pool_updated, primary_key(event_digest))]
pub struct DeepbookPoolUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_pool_id: String,
    pub deepbook_pool_id: String,
    pub pool_cap_id: String,
    pub enabled: bool,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = interest_params_updated, primary_key(event_digest))]
pub struct InterestParamsUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_pool_id: String,
    pub pool_cap_id: String,
    pub config_json: serde_json::Value,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = margin_pool_config_updated, primary_key(event_digest))]
pub struct MarginPoolConfigUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_pool_id: String,
    pub pool_cap_id: String,
    pub config_json: serde_json::Value,
    pub onchain_timestamp: i64,
}

// === Margin Registry Events ===
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = maintainer_cap_updated, primary_key(event_digest))]
pub struct MaintainerCapUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub maintainer_cap_id: String,
    pub allowed: bool,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = deepbook_pool_registered, primary_key(event_digest))]
pub struct DeepbookPoolRegistered {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_id: String,
    pub config_json: Option<serde_json::Value>,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = deepbook_pool_updated_registry, primary_key(event_digest))]
pub struct DeepbookPoolUpdatedRegistry {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_id: String,
    pub enabled: bool,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = deepbook_pool_config_updated, primary_key(event_digest))]
pub struct DeepbookPoolConfigUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_id: String,
    pub config_json: serde_json::Value,
    pub onchain_timestamp: i64,
}

// === Additional Margin Pool Events ===
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = maintainer_fees_withdrawn, primary_key(event_digest))]
pub struct MaintainerFeesWithdrawn {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_pool_id: String,
    pub margin_pool_cap_id: String,
    pub maintainer_fees: i64,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = protocol_fees_withdrawn, primary_key(event_digest))]
pub struct ProtocolFeesWithdrawn {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_pool_id: String,
    pub protocol_fees: i64,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = supplier_cap_minted, primary_key(event_digest))]
pub struct SupplierCapMinted {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub supplier_cap_id: String,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = supply_referral_minted, primary_key(event_digest))]
pub struct SupplyReferralMinted {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_pool_id: String,
    pub supply_referral_id: String,
    pub owner: String,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = pause_cap_updated, primary_key(event_digest))]
pub struct PauseCapUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pause_cap_id: String,
    pub allowed: bool,
    pub onchain_timestamp: i64,
}

// === Protocol Fees Events ===
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = protocol_fees_increased, primary_key(event_digest))]
pub struct ProtocolFeesIncreasedEvent {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_pool_id: String,
    pub total_shares: i64,
    pub referral_fees: i64,
    pub maintainer_fees: i64,
    pub protocol_fees: i64,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = referral_fees_claimed, primary_key(event_digest))]
pub struct ReferralFeesClaimedEvent {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub referral_id: String,
    pub owner: String,
    pub fees: i64,
    pub onchain_timestamp: i64,
}

// === Margin Manager State ===
#[derive(Queryable, Selectable, Identifiable, Debug, Serialize)]
#[diesel(table_name = margin_manager_state)]
pub struct MarginManagerState {
    pub id: i32,
    pub margin_manager_id: String,
    pub deepbook_pool_id: String,
    pub base_margin_pool_id: Option<String>,
    pub quote_margin_pool_id: Option<String>,
    pub base_asset_id: Option<String>,
    pub base_asset_symbol: Option<String>,
    pub quote_asset_id: Option<String>,
    pub quote_asset_symbol: Option<String>,
    #[serde(serialize_with = "serialize_bigdecimal_option")]
    pub risk_ratio: Option<BigDecimal>,
    #[serde(serialize_with = "serialize_bigdecimal_option")]
    pub base_asset: Option<BigDecimal>,
    #[serde(serialize_with = "serialize_bigdecimal_option")]
    pub quote_asset: Option<BigDecimal>,
    #[serde(serialize_with = "serialize_bigdecimal_option")]
    pub base_debt: Option<BigDecimal>,
    #[serde(serialize_with = "serialize_bigdecimal_option")]
    pub quote_debt: Option<BigDecimal>,
    pub base_pyth_price: Option<i64>,
    pub base_pyth_decimals: Option<i32>,
    pub quote_pyth_price: Option<i64>,
    pub quote_pyth_decimals: Option<i32>,
    #[serde(serialize_with = "serialize_datetime")]
    pub created_at: chrono::NaiveDateTime,
    #[serde(serialize_with = "serialize_datetime")]
    pub updated_at: chrono::NaiveDateTime,
    #[serde(serialize_with = "serialize_bigdecimal_option")]
    pub current_price: Option<BigDecimal>,
    #[serde(serialize_with = "serialize_bigdecimal_option")]
    pub lowest_trigger_above_price: Option<BigDecimal>,
    #[serde(serialize_with = "serialize_bigdecimal_option")]
    pub highest_trigger_below_price: Option<BigDecimal>,
}

// === Margin Pool Snapshots (for metrics polling) ===
#[derive(Queryable, Selectable, Insertable, Debug, Serialize)]
#[diesel(table_name = margin_pool_snapshots)]
pub struct MarginPoolSnapshot {
    pub id: i64,
    pub margin_pool_id: String,
    pub asset_type: String,
    #[serde(serialize_with = "serialize_datetime")]
    pub timestamp: chrono::NaiveDateTime,
    pub total_supply: i64,
    pub total_borrow: i64,
    pub vault_balance: i64,
    pub supply_cap: i64,
    pub interest_rate: i64,
    pub available_withdrawal: i64,
    pub utilization_rate: f64,
    pub solvency_ratio: Option<f64>,
    pub available_liquidity_pct: Option<f64>,
}

#[derive(Insertable, Debug)]
#[diesel(table_name = margin_pool_snapshots)]
pub struct NewMarginPoolSnapshot {
    pub margin_pool_id: String,
    pub asset_type: String,
    pub total_supply: i64,
    pub total_borrow: i64,
    pub vault_balance: i64,
    pub supply_cap: i64,
    pub interest_rate: i64,
    pub available_withdrawal: i64,
    pub utilization_rate: f64,
    pub solvency_ratio: Option<f64>,
    pub available_liquidity_pct: Option<f64>,
}

// === Collateral Events ===
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = collateral_events, primary_key(event_digest))]
pub struct CollateralEvent {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub event_type: String,
    pub margin_manager_id: String,
    pub amount: BigDecimal,
    pub asset_type: String,
    pub pyth_decimals: i16,
    pub pyth_price: BigDecimal,
    pub withdraw_base_asset: Option<bool>,
    pub base_pyth_decimals: Option<i16>,
    pub base_pyth_price: Option<BigDecimal>,
    pub quote_pyth_decimals: Option<i16>,
    pub quote_pyth_price: Option<BigDecimal>,
    pub remaining_base_asset: Option<BigDecimal>,
    pub remaining_quote_asset: Option<BigDecimal>,
    pub remaining_base_debt: Option<BigDecimal>,
    pub remaining_quote_debt: Option<BigDecimal>,
    pub onchain_timestamp: i64,
}

// === TPSL (Take Profit / Stop Loss) Events ===
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = conditional_order_events, primary_key(event_digest))]
pub struct ConditionalOrderEvent {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub event_type: String,
    pub manager_id: String,
    pub pool_id: Option<String>,
    pub conditional_order_id: i64,
    pub trigger_below_price: bool,
    pub trigger_price: BigDecimal,
    pub is_limit_order: bool,
    pub client_order_id: i64,
    pub order_type: i16,
    pub self_matching_option: i16,
    pub price: BigDecimal,
    pub quantity: BigDecimal,
    pub is_bid: bool,
    pub pay_with_deep: bool,
    pub expire_timestamp: i64,
    pub onchain_timestamp: i64,
}

// === Points ===
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = points, primary_key(id))]
pub struct Points {
    pub id: i64,
    pub address: String,
    pub amount: i64,
    pub week: i32,
    #[serde(serialize_with = "serialize_datetime")]
    pub timestamp: chrono::NaiveDateTime,
}
