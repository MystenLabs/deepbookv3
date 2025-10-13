use crate::schema::{
    balances, deep_burned, flashloans, margin_fees, margin_manager_operations, margin_pool_admin,
    margin_pool_operations, margin_registry_events, order_fills, order_updates, pool_prices, pools,
    proposals, rebates, stakes, sui_error_transactions, trade_params_update, votes,
};
use diesel::deserialize::FromSql;
use diesel::pg::{Pg, PgValue};
use diesel::serialize::{Output, ToSql};
use diesel::sql_types::Text;
use diesel::{AsExpression, Identifiable, Insertable, Queryable, QueryableByName, Selectable};
use serde::Serialize;
use std::str::FromStr;
use strum_macros::{AsRefStr, EnumString};
use sui_field_count::FieldCount;

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

// === Margin Pool Operations ===
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = margin_pool_operations, primary_key(event_digest))]
pub struct MarginPoolOperations {
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
    pub operation_type: String,
    pub onchain_timestamp: i64,
}

// === Margin Manager Operations ===
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = margin_manager_operations, primary_key(event_digest))]
pub struct MarginManagerOperations {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_manager_id: String,
    pub balance_manager_id: Option<String>,
    pub owner: Option<String>,
    pub margin_pool_id: Option<String>,
    pub operation_type: String,
    pub loan_amount: Option<i64>,
    pub total_borrow: Option<i64>,
    pub total_shares: Option<i64>,
    pub repay_amount: Option<i64>,
    pub repay_shares: Option<i64>,
    pub liquidation_amount: Option<i64>,
    pub pool_reward: Option<i64>,
    pub pool_default: Option<i64>,
    pub risk_ratio: Option<i64>,
    pub onchain_timestamp: i64,
}

// === Margin Pool Admin ===
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = margin_pool_admin, primary_key(event_digest))]
pub struct MarginPoolAdmin {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub margin_pool_id: String,
    pub event_type: String,
    pub maintainer_cap_id: Option<String>,
    pub asset_type: Option<String>,
    pub deepbook_pool_id: Option<String>,
    pub pool_cap_id: Option<String>,
    pub enabled: Option<bool>,
    pub config_json: Option<serde_json::Value>,
    pub onchain_timestamp: i64,
}

// === Margin Fees ===
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = margin_fees, primary_key(event_digest))]
pub struct MarginFees {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub fee_type: String,
    pub margin_pool_id: Option<String>,
    pub maintainer_cap_id: Option<String>,
    pub referral_id: Option<String>,
    pub owner: Option<String>,
    pub fees: Option<i64>,
    pub maintainer_fees: Option<i64>,
    pub protocol_fees: Option<i64>,
    pub referral_fees: Option<i64>,
    pub total_shares: Option<i64>,
    pub onchain_timestamp: i64,
}

// === Margin Registry Events ===
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount)]
#[diesel(table_name = margin_registry_events, primary_key(event_digest))]
pub struct MarginRegistryEvents {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub event_type: String,
    pub maintainer_cap_id: Option<String>,
    pub allowed: Option<bool>,
    pub pool_id: Option<String>,
    pub enabled: Option<bool>,
    pub config_json: Option<serde_json::Value>,
    pub onchain_timestamp: i64,
}
