use crate::PredictConfig;
use std::sync::Arc;
use sui_indexer_alt_framework::types::full_checkpoint_content::{
    Checkpoint, ExecutedTransaction, ObjectSet,
};
use sui_types::base_types::ObjectID;
use sui_types::effects::TransactionEffectsAPI;
use sui_types::transaction::{Command, TransactionDataAPI};

/// Captures common transaction metadata for event processing.
pub struct EventMeta {
    digest: Arc<str>,
    sender: Arc<str>,
    checkpoint: i64,
    checkpoint_timestamp_ms: i64,
    package: Arc<str>,
    tx_index: i64,
    event_index: i64,
}

impl EventMeta {
    pub fn from_checkpoint_tx(
        checkpoint: &Checkpoint,
        tx: &ExecutedTransaction,
        tx_index: usize,
    ) -> Self {
        Self {
            digest: tx.effects.transaction_digest().to_string().into(),
            sender: tx.transaction.sender().to_string().into(),
            checkpoint: checkpoint.summary.sequence_number as i64,
            checkpoint_timestamp_ms: checkpoint.summary.timestamp_ms as i64,
            package: Arc::from(""),
            tx_index: tx_index as i64,
            event_index: 0,
        }
    }

    pub fn with_event(&self, index: usize, package: Arc<str>) -> Self {
        Self {
            digest: Arc::clone(&self.digest),
            sender: Arc::clone(&self.sender),
            checkpoint: self.checkpoint,
            checkpoint_timestamp_ms: self.checkpoint_timestamp_ms,
            package,
            tx_index: self.tx_index,
            event_index: index as i64,
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

    pub fn tx_index(&self) -> i64 {
        self.tx_index
    }

    pub fn event_index(&self) -> i64 {
        self.event_index
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
                for (tx_index, tx) in checkpoint.transactions.iter().enumerate() {
                    if !is_predict_tx(tx, &checkpoint.object_set, &self.config) {
                        continue;
                    }
                    let Some(events) = &tx.events else { continue };

                    let base_meta = EventMeta::from_checkpoint_tx(checkpoint, tx, tx_index);

                    for (index, ev) in events.data.iter().enumerate() {
                        if <$event>::matches_event_type(&ev.type_, &self.config.account_addresses) {
                            let $ev: $event = bcs::from_bytes(&ev.contents)?;
                            let $meta = base_meta.with_event(
                                index,
                                event_package(&ev.type_).into(),
                            );
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
        let has_predict_event = events
            .data
            .iter()
            .any(|event| config.account_addresses.contains(&event.type_.address));
        if has_predict_event {
            return true;
        }
    }

    // Check move calls
    let txn_kind = tx.transaction.kind();
    txn_kind.iter_commands().any(|cmd| {
        if let Command::MoveCall(move_call) = cmd {
            config.object_ids.contains(&move_call.package)
        } else {
            false
        }
    })
}

pub(crate) fn event_package(event_type: &move_core_types::language_storage::StructTag) -> String {
    event_type.address.to_string()
}

pub(crate) fn find_predict_object_id_from_candidates<I>(
    candidates: I,
    config: &PredictConfig,
) -> Option<String>
where
    I: IntoIterator<Item = (move_core_types::language_storage::StructTag, ObjectID)>,
{
    candidates.into_iter().find_map(|(struct_tag, object_id)| {
        let is_predict_object = struct_tag.name.as_str() == "Predict"
            && config
                .account_addresses
                .iter()
                .any(|addr| struct_tag.address == *addr);
        if is_predict_object {
            Some(object_id.to_hex_uncompressed())
        } else {
            None
        }
    })
}

fn predict_object_id_from_tx(
    tx: &ExecutedTransaction,
    checkpoint_objects: &ObjectSet,
    config: &PredictConfig,
) -> Option<String> {
    find_predict_object_id_from_candidates(
        tx.input_objects(checkpoint_objects)
            .filter_map(|obj| obj.data.struct_tag().map(|tag| (tag, obj.id()))),
        config,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use move_core_types::account_address::AccountAddress;
    use move_core_types::identifier::Identifier;
    use move_core_types::language_storage::StructTag;
    use std::str::FromStr;
    use sui_types::base_types::ObjectID;

    #[test]
    fn event_package_uses_event_type_address() {
        let tag = StructTag {
            address: AccountAddress::from_hex_literal("0x42").unwrap(),
            module: Identifier::new("oracle").unwrap(),
            name: Identifier::new("OracleActivated").unwrap(),
            type_params: vec![],
        };

        assert_eq!(event_package(&tag), tag.address.to_string());
    }

    #[test]
    fn with_event_updates_package_and_indices() {
        let meta = EventMeta {
            digest: Arc::from("txdigest"),
            sender: Arc::from("0xsender"),
            checkpoint: 9,
            checkpoint_timestamp_ms: 1234,
            package: Arc::from(""),
            tx_index: 3,
            event_index: 0,
        };

        let updated = meta.with_event(5, Arc::from("0xeventpackage"));

        assert_eq!(updated.package(), "0xeventpackage");
        assert_eq!(updated.tx_index(), 3);
        assert_eq!(updated.event_index(), 5);
        assert_eq!(updated.event_digest(), "txdigest5");
    }

    #[test]
    fn find_predict_object_id_from_candidates_prefers_predict_inputs() {
        let config = PredictConfig::new(["0x42"]);
        let candidates = vec![
            (
                StructTag {
                    address: AccountAddress::from_hex_literal("0x42").unwrap(),
                    module: Identifier::new("oracle").unwrap(),
                    name: Identifier::new("OracleSVI").unwrap(),
                    type_params: vec![],
                },
                ObjectID::from_str(
                    "0x1111111111111111111111111111111111111111111111111111111111111111",
                )
                .unwrap(),
            ),
            (
                StructTag {
                    address: AccountAddress::from_hex_literal("0x42").unwrap(),
                    module: Identifier::new("predict").unwrap(),
                    name: Identifier::new("Predict").unwrap(),
                    type_params: vec![],
                },
                ObjectID::from_str(
                    "0x2222222222222222222222222222222222222222222222222222222222222222",
                )
                .unwrap(),
            ),
        ];

        let predict_id =
            find_predict_object_id_from_candidates(candidates.iter().cloned(), &config);

        assert_eq!(
            predict_id,
            Some("0x2222222222222222222222222222222222222222222222222222222222222222".to_string())
        );
    }
}

// === Handler definitions ===

use crate::models::{
    OracleActivated, OracleAskBoundsCleared, OracleAskBoundsSet, OracleCreated,
    OraclePricesUpdated, OracleSVIUpdated, OracleSettled, PositionMinted, PositionRedeemed,
    PredictCreated, PredictManagerCreated, PricingConfigUpdated, QuoteAssetDisabled,
    QuoteAssetEnabled, RangeMinted, RangeRedeemed, RiskConfigUpdated, Supplied,
    TradingPauseUpdated, Withdrawn,
};
use predict_schema::models::{
    OracleActivatedRow, OracleAskBoundsClearedRow, OracleAskBoundsSetRow, OracleCreatedRow,
    OraclePricesUpdatedRow, OracleSettledRow, OracleSviUpdatedRow, PositionMintedRow,
    PositionRedeemedRow, PredictCreatedRow, PredictManagerCreatedRow, PricingConfigUpdatedRow,
    QuoteAssetDisabledRow, QuoteAssetEnabledRow, RangeMintedRow, RangeRedeemedRow,
    RiskConfigUpdatedRow, SuppliedRow, TradingPauseUpdatedRow, WithdrawnRow,
};

// === oracle module handlers ===

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
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
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
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
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
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
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
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        oracle_id: event.oracle_id.to_string(),
        a: event.a as i64,
        b: event.b as i64,
        rho: event.rho.magnitude as i64,
        rho_negative: event.rho.is_negative,
        m: event.m.magnitude as i64,
        m_negative: event.m.is_negative,
        sigma: event.sigma as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}

// === registry module handlers ===

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
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
    }
}

pub struct OracleCreatedHandler {
    config: Arc<PredictConfig>,
}

impl OracleCreatedHandler {
    pub fn new(config: Arc<PredictConfig>) -> Self {
        Self { config }
    }
}

#[async_trait::async_trait]
impl sui_indexer_alt_framework::pipeline::Processor for OracleCreatedHandler {
    const NAME: &'static str = "oracle_created";
    type Value = OracleCreatedRow;

    async fn process(&self, checkpoint: &Arc<Checkpoint>) -> anyhow::Result<Vec<Self::Value>> {
        use crate::traits::MoveStruct;

        let mut results = vec![];
        for (tx_index, tx) in checkpoint.transactions.iter().enumerate() {
            if !is_predict_tx(tx, &checkpoint.object_set, &self.config) {
                continue;
            }
            let Some(events) = &tx.events else { continue };

            let base_meta = EventMeta::from_checkpoint_tx(checkpoint, tx, tx_index);
            let predict_id = predict_object_id_from_tx(tx, &checkpoint.object_set, &self.config)
                .unwrap_or_else(|| "0x0".to_string());

            for (index, ev) in events.data.iter().enumerate() {
                if !OracleCreated::matches_event_type(&ev.type_, &self.config.account_addresses) {
                    continue;
                }
                let event: OracleCreated = bcs::from_bytes(&ev.contents)?;
                let meta = base_meta.with_event(index, event_package(&ev.type_).into());
                results.push(OracleCreatedRow {
                    event_digest: meta.event_digest(),
                    digest: meta.digest(),
                    sender: meta.sender(),
                    checkpoint: meta.checkpoint(),
                    checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
                    tx_index: meta.tx_index(),
                    event_index: meta.event_index(),
                    package: meta.package(),
                    predict_id: predict_id.clone(),
                    oracle_id: event.oracle_id.to_string(),
                    oracle_cap_id: event.oracle_cap_id.to_string(),
                    underlying_asset: event.underlying_asset.clone(),
                    expiry: event.expiry as i64,
                    min_strike: event.min_strike as i64,
                    tick_size: event.tick_size as i64,
                });
                tracing::debug!("Observed oracle_created event");
            }
        }

        Ok(results)
    }
}

#[async_trait::async_trait]
impl sui_indexer_alt_framework::postgres::handler::Handler for OracleCreatedHandler {
    async fn commit<'a>(
        values: &[Self::Value],
        conn: &mut sui_indexer_alt_framework::postgres::Connection<'a>,
    ) -> anyhow::Result<usize> {
        use diesel_async::RunQueryDsl;

        Ok(
            diesel::insert_into(predict_schema::schema::oracle_created::table)
                .values(values)
                .on_conflict_do_nothing()
                .execute(conn)
                .await?,
        )
    }
}

// === predict module handlers ===

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
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        manager_id: event.manager_id.to_string(),
        trader: event.trader.to_string(),
        quote_asset: event.quote_asset.as_string(),
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
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        manager_id: event.manager_id.to_string(),
        owner: event.owner.to_string(),
        executor: event.executor.to_string(),
        quote_asset: event.quote_asset.as_string(),
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
    name: RangeMintedHandler,
    processor_name: "range_minted",
    event_type: RangeMinted,
    db_model: RangeMintedRow,
    table: range_minted,
    map_event: |event, meta| RangeMintedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        manager_id: event.manager_id.to_string(),
        trader: event.trader.to_string(),
        quote_asset: event.quote_asset.as_string(),
        oracle_id: event.oracle_id.to_string(),
        expiry: event.expiry as i64,
        lower_strike: event.lower_strike as i64,
        higher_strike: event.higher_strike as i64,
        quantity: event.quantity as i64,
        cost: event.cost as i64,
        ask_price: event.ask_price as i64,
    }
}

define_handler! {
    name: RangeRedeemedHandler,
    processor_name: "range_redeemed",
    event_type: RangeRedeemed,
    db_model: RangeRedeemedRow,
    table: range_redeemed,
    map_event: |event, meta| RangeRedeemedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        manager_id: event.manager_id.to_string(),
        trader: event.trader.to_string(),
        quote_asset: event.quote_asset.as_string(),
        oracle_id: event.oracle_id.to_string(),
        expiry: event.expiry as i64,
        lower_strike: event.lower_strike as i64,
        higher_strike: event.higher_strike as i64,
        quantity: event.quantity as i64,
        payout: event.payout as i64,
        bid_price: event.bid_price as i64,
        is_settled: event.is_settled,
    }
}

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
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
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
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        base_spread: event.base_spread as i64,
        min_spread: event.min_spread as i64,
        utilization_multiplier: event.utilization_multiplier as i64,
        min_ask_price: event.min_ask_price as i64,
        max_ask_price: event.max_ask_price as i64,
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
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        max_total_exposure_pct: event.max_total_exposure_pct as i64,
    }
}

define_handler! {
    name: OracleAskBoundsSetHandler,
    processor_name: "oracle_ask_bounds_set",
    event_type: OracleAskBoundsSet,
    db_model: OracleAskBoundsSetRow,
    table: oracle_ask_bounds_set,
    map_event: |event, meta| OracleAskBoundsSetRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        oracle_id: event.oracle_id.to_string(),
        min_ask_price: event.min_ask_price as i64,
        max_ask_price: event.max_ask_price as i64,
    }
}

define_handler! {
    name: OracleAskBoundsClearedHandler,
    processor_name: "oracle_ask_bounds_cleared",
    event_type: OracleAskBoundsCleared,
    db_model: OracleAskBoundsClearedRow,
    table: oracle_ask_bounds_cleared,
    map_event: |event, meta| OracleAskBoundsClearedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        oracle_id: event.oracle_id.to_string(),
    }
}

define_handler! {
    name: QuoteAssetEnabledHandler,
    processor_name: "quote_asset_enabled",
    event_type: QuoteAssetEnabled,
    db_model: QuoteAssetEnabledRow,
    table: quote_asset_enabled,
    map_event: |event, meta| QuoteAssetEnabledRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        quote_asset: event.quote_asset.as_string(),
    }
}

define_handler! {
    name: QuoteAssetDisabledHandler,
    processor_name: "quote_asset_disabled",
    event_type: QuoteAssetDisabled,
    db_model: QuoteAssetDisabledRow,
    table: quote_asset_disabled,
    map_event: |event, meta| QuoteAssetDisabledRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        quote_asset: event.quote_asset.as_string(),
    }
}

define_handler! {
    name: SuppliedHandler,
    processor_name: "supplied",
    event_type: Supplied,
    db_model: SuppliedRow,
    table: supplied,
    map_event: |event, meta| SuppliedRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        supplier: event.supplier.to_string(),
        quote_asset: event.quote_asset.as_string(),
        amount: event.amount as i64,
        shares_minted: event.shares_minted as i64,
    }
}

define_handler! {
    name: WithdrawnHandler,
    processor_name: "withdrawn",
    event_type: Withdrawn,
    db_model: WithdrawnRow,
    table: withdrawn,
    map_event: |event, meta| WithdrawnRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        predict_id: event.predict_id.to_string(),
        withdrawer: event.withdrawer.to_string(),
        quote_asset: event.quote_asset.as_string(),
        amount: event.amount as i64,
        shares_burned: event.shares_burned as i64,
    }
}

// === predict_manager module handlers ===

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
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        package: meta.package(),
        manager_id: event.manager_id.to_string(),
        owner: event.owner.to_string(),
    }
}
