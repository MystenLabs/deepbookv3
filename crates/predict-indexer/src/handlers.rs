use crate::PredictConfig;
use std::sync::Arc;
use sui_indexer_alt_framework::types::full_checkpoint_content::{
    Checkpoint, ExecutedTransaction, ObjectSet,
};
use sui_types::transaction::{Command, TransactionDataAPI};
use sui_types::effects::TransactionEffectsAPI;

/// Captures common transaction metadata for event processing.
pub struct EventMeta {
    digest: Arc<str>,
    sender: Arc<str>,
    checkpoint: i64,
    checkpoint_timestamp_ms: i64,
    package: Arc<str>,
    event_index: usize,
}

impl EventMeta {
    pub fn from_checkpoint_tx(checkpoint: &Checkpoint, tx: &ExecutedTransaction) -> Self {
        Self {
            digest: tx.effects.transaction_digest().to_string().into(),
            sender: tx.transaction.sender().to_string().into(),
            checkpoint: checkpoint.summary.sequence_number as i64,
            checkpoint_timestamp_ms: checkpoint.summary.timestamp_ms as i64,
            package: try_extract_move_call_package(tx).unwrap_or_default().into(),
            event_index: 0,
        }
    }

    pub fn with_index(&self, index: usize) -> Self {
        Self {
            digest: Arc::clone(&self.digest),
            sender: Arc::clone(&self.sender),
            checkpoint: self.checkpoint,
            checkpoint_timestamp_ms: self.checkpoint_timestamp_ms,
            package: Arc::clone(&self.package),
            event_index: index,
        }
    }

    pub fn event_digest(&self) -> String {
        format!("{}{}", self.digest, self.event_index)
    }

    pub fn digest(&self) -> String {
        self.digest.to_string()
    }

    pub fn sender(&self) -> String {
        self.sender.to_string()
    }

    pub fn checkpoint(&self) -> i64 {
        self.checkpoint
    }

    pub fn checkpoint_timestamp_ms(&self) -> i64 {
        self.checkpoint_timestamp_ms
    }

    pub fn package(&self) -> String {
        self.package.to_string()
    }
}

/// Macro to generate a handler from minimal configuration.
#[macro_export]
macro_rules! define_handler {
    {
        name: $handler:ident,
        processor_name: $proc_name:literal,
        event_type: $event:ty,
        db_model: $model:ty,
        table: $table:ident,
        map_event: |$ev:ident, $meta:ident| $body:expr
    } => {
        pub struct $handler {
            config: std::sync::Arc<$crate::PredictConfig>,
        }

        impl $handler {
            pub fn new(config: std::sync::Arc<$crate::PredictConfig>) -> Self {
                Self { config }
            }
        }

        #[async_trait::async_trait]
        impl sui_indexer_alt_framework::pipeline::Processor for $handler {
            const NAME: &'static str = $proc_name;
            type Value = $model;

            async fn process(
                &self,
                checkpoint: &std::sync::Arc<sui_indexer_alt_framework::types::full_checkpoint_content::Checkpoint>,
            ) -> anyhow::Result<Vec<Self::Value>> {
                use $crate::handlers::{is_predict_tx, EventMeta};
                use $crate::traits::MoveStruct;

                let mut results = vec![];
                for tx in &checkpoint.transactions {
                    if !is_predict_tx(tx, &checkpoint.object_set, &self.config) {
                        continue;
                    }
                    let Some(events) = &tx.events else { continue };

                    let base_meta = EventMeta::from_checkpoint_tx(checkpoint, tx);

                    for (index, ev) in events.data.iter().enumerate() {
                        if <$event>::matches_event_type(&ev.type_, &self.config.account_addresses) {
                            let $ev: $event = bcs::from_bytes(&ev.contents)?;
                            let $meta = base_meta.with_index(index);
                            results.push($body);
                            tracing::debug!("Observed {} event", $proc_name);
                        }
                    }
                }
                Ok(results)
            }
        }

        #[async_trait::async_trait]
        impl sui_indexer_alt_framework::postgres::handler::Handler for $handler {
            async fn commit<'a>(
                values: &[Self::Value],
                conn: &mut sui_pg_db::Connection<'a>,
            ) -> anyhow::Result<usize> {
                use diesel_async::RunQueryDsl;
                Ok(diesel::insert_into(predict_schema::schema::$table::table)
                    .values(values)
                    .on_conflict_do_nothing()
                    .execute(conn)
                    .await?)
            }
        }
    };
}

pub(crate) fn is_predict_tx(
    tx: &ExecutedTransaction,
    checkpoint_objects: &ObjectSet,
    config: &PredictConfig,
) -> bool {
    // Check input objects
    let has_predict_input = tx.input_objects(checkpoint_objects).any(|obj| {
        obj.data
            .type_()
            .map(|t| {
                config
                    .account_addresses
                    .iter()
                    .any(|addr| t.address() == *addr)
            })
            .unwrap_or_default()
    });

    if has_predict_input {
        return true;
    }

    // Check events
    if let Some(events) = &tx.events {
        let has_predict_event = events.data.iter().any(|event| {
            config
                .account_addresses
                .iter()
                .any(|addr| event.type_.address == *addr)
        });
        if has_predict_event {
            return true;
        }
    }

    // Check move calls
    let txn_kind = tx.transaction.kind();
    txn_kind.iter_commands().any(|cmd| {
        if let Command::MoveCall(move_call) = cmd {
            config
                .object_ids
                .iter()
                .any(|pkg| *pkg == move_call.package)
        } else {
            false
        }
    })
}

pub(crate) fn try_extract_move_call_package(tx: &ExecutedTransaction) -> Option<String> {
    let txn_kind = tx.transaction.kind();
    let first_command = txn_kind.iter_commands().next()?;
    if let Command::MoveCall(move_call) = first_command {
        Some(move_call.package.to_string())
    } else {
        None
    }
}

// === Oracle handlers ===

use crate::models::{
    AdminVaultBalanceChanged, CollateralizedPositionMinted, CollateralizedPositionRedeemed,
    OracleActivated, OracleCreated, OraclePricesUpdated, OracleSVIUpdated, OracleSettled,
    PositionMinted, PositionRedeemed, PredictCreated, PredictManagerCreated, PricingConfigUpdated,
    RiskConfigUpdated, TradingPauseUpdated,
};
use predict_schema::models::{
    AdminVaultBalanceChangedRow, CollateralizedPositionMintedRow,
    CollateralizedPositionRedeemedRow, OracleActivatedRow, OracleCreatedRow,
    OraclePricesUpdatedRow, OracleSettledRow, OracleSviUpdatedRow, PositionMintedRow,
    PositionRedeemedRow, PredictCreatedRow, PredictManagerCreatedRow, PricingConfigUpdatedRow,
    RiskConfigUpdatedRow, TradingPauseUpdatedRow,
};

define_handler! {
    name: OracleActivatedHandler,
    processor_name: "oracle_activated",
    event_type: OracleActivated,
    db_model: OracleActivatedRow,
    table: oracle_activated,
    map_event: |event, meta| OracleActivatedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        oracle_id: event.oracle_id.to_string(),
        expiry: event.expiry as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}

define_handler! {
    name: OracleSettledHandler,
    processor_name: "oracle_settled",
    event_type: OracleSettled,
    db_model: OracleSettledRow,
    table: oracle_settled,
    map_event: |event, meta| OracleSettledRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        oracle_id: event.oracle_id.to_string(),
        expiry: event.expiry as i64,
        settlement_price: event.settlement_price as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}

define_handler! {
    name: OraclePricesUpdatedHandler,
    processor_name: "oracle_prices_updated",
    event_type: OraclePricesUpdated,
    db_model: OraclePricesUpdatedRow,
    table: oracle_prices_updated,
    map_event: |event, meta| OraclePricesUpdatedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        oracle_id: event.oracle_id.to_string(),
        spot: event.spot as i64,
        forward: event.forward as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}

define_handler! {
    name: OracleSviUpdatedHandler,
    processor_name: "oracle_svi_updated",
    event_type: OracleSVIUpdated,
    db_model: OracleSviUpdatedRow,
    table: oracle_svi_updated,
    map_event: |event, meta| OracleSviUpdatedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        oracle_id: event.oracle_id.to_string(),
        a: event.a as i64,
        b: event.b as i64,
        rho: event.rho as i64,
        rho_negative: event.rho_negative,
        m: event.m as i64,
        m_negative: event.m_negative,
        sigma: event.sigma as i64,
        risk_free_rate: event.risk_free_rate as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}

// === Registry handlers ===

define_handler! {
    name: PredictCreatedHandler,
    processor_name: "predict_created",
    event_type: PredictCreated,
    db_model: PredictCreatedRow,
    table: predict_created,
    map_event: |event, meta| PredictCreatedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
    }
}

define_handler! {
    name: OracleCreatedHandler,
    processor_name: "oracle_created",
    event_type: OracleCreated,
    db_model: OracleCreatedRow,
    table: oracle_created,
    map_event: |event, meta| OracleCreatedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        oracle_id: event.oracle_id.to_string(),
        oracle_cap_id: event.oracle_cap_id.to_string(),
        expiry: event.expiry as i64,
    }
}

define_handler! {
    name: AdminVaultBalanceChangedHandler,
    processor_name: "admin_vault_balance_changed",
    event_type: AdminVaultBalanceChanged,
    db_model: AdminVaultBalanceChangedRow,
    table: admin_vault_balance_changed,
    map_event: |event, meta| AdminVaultBalanceChangedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        amount: event.amount as i64,
        deposit: event.deposit,
    }
}

// === Trading handlers ===

define_handler! {
    name: PositionMintedHandler,
    processor_name: "position_minted",
    event_type: PositionMinted,
    db_model: PositionMintedRow,
    table: position_minted,
    map_event: |event, meta| PositionMintedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        manager_id: event.manager_id.to_string(),
        trader: event.trader.to_string(),
        oracle_id: event.oracle_id.to_string(),
        expiry: event.expiry as i64,
        strike: event.strike as i64,
        is_up: event.is_up,
        quantity: event.quantity as i64,
        cost: event.cost as i64,
        ask_price: event.ask_price as i64,
    }
}

define_handler! {
    name: PositionRedeemedHandler,
    processor_name: "position_redeemed",
    event_type: PositionRedeemed,
    db_model: PositionRedeemedRow,
    table: position_redeemed,
    map_event: |event, meta| PositionRedeemedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        manager_id: event.manager_id.to_string(),
        trader: event.trader.to_string(),
        oracle_id: event.oracle_id.to_string(),
        expiry: event.expiry as i64,
        strike: event.strike as i64,
        is_up: event.is_up,
        quantity: event.quantity as i64,
        payout: event.payout as i64,
        bid_price: event.bid_price as i64,
        is_settled: event.is_settled,
    }
}

define_handler! {
    name: CollateralizedPositionMintedHandler,
    processor_name: "collateralized_position_minted",
    event_type: CollateralizedPositionMinted,
    db_model: CollateralizedPositionMintedRow,
    table: collateralized_position_minted,
    map_event: |event, meta| CollateralizedPositionMintedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        manager_id: event.manager_id.to_string(),
        trader: event.trader.to_string(),
        oracle_id: event.oracle_id.to_string(),
        locked_expiry: event.locked_expiry as i64,
        locked_strike: event.locked_strike as i64,
        locked_is_up: event.locked_is_up,
        minted_expiry: event.minted_expiry as i64,
        minted_strike: event.minted_strike as i64,
        minted_is_up: event.minted_is_up,
        quantity: event.quantity as i64,
    }
}

define_handler! {
    name: CollateralizedPositionRedeemedHandler,
    processor_name: "collateralized_position_redeemed",
    event_type: CollateralizedPositionRedeemed,
    db_model: CollateralizedPositionRedeemedRow,
    table: collateralized_position_redeemed,
    map_event: |event, meta| CollateralizedPositionRedeemedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        manager_id: event.manager_id.to_string(),
        trader: event.trader.to_string(),
        oracle_id: event.oracle_id.to_string(),
        locked_expiry: event.locked_expiry as i64,
        locked_strike: event.locked_strike as i64,
        locked_is_up: event.locked_is_up,
        minted_expiry: event.minted_expiry as i64,
        minted_strike: event.minted_strike as i64,
        minted_is_up: event.minted_is_up,
        quantity: event.quantity as i64,
    }
}

// === Admin handlers ===

define_handler! {
    name: TradingPauseUpdatedHandler,
    processor_name: "trading_pause_updated",
    event_type: TradingPauseUpdated,
    db_model: TradingPauseUpdatedRow,
    table: trading_pause_updated,
    map_event: |event, meta| TradingPauseUpdatedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        paused: event.paused,
    }
}

define_handler! {
    name: PricingConfigUpdatedHandler,
    processor_name: "pricing_config_updated",
    event_type: PricingConfigUpdated,
    db_model: PricingConfigUpdatedRow,
    table: pricing_config_updated,
    map_event: |event, meta| PricingConfigUpdatedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        base_spread: event.base_spread as i64,
        max_skew_multiplier: event.max_skew_multiplier as i64,
        utilization_multiplier: event.utilization_multiplier as i64,
    }
}

define_handler! {
    name: RiskConfigUpdatedHandler,
    processor_name: "risk_config_updated",
    event_type: RiskConfigUpdated,
    db_model: RiskConfigUpdatedRow,
    table: risk_config_updated,
    map_event: |event, meta| RiskConfigUpdatedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        max_total_exposure_pct: event.max_total_exposure_pct as i64,
    }
}

// === User handlers ===

define_handler! {
    name: PredictManagerCreatedHandler,
    processor_name: "predict_manager_created",
    event_type: PredictManagerCreated,
    db_model: PredictManagerCreatedRow,
    table: predict_manager_created,
    map_event: |event, meta| PredictManagerCreatedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        manager_id: event.manager_id.to_string(),
        owner: event.owner.to_string(),
    }
}
