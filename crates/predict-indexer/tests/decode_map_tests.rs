//! Decode + `map()` unit tests for the Predict order-event handlers.
//!
//! Stubbed this round (fixture-free): each test will build a decode struct +
//! `PredictEventMeta::for_test(...)`, call the handler's `map()`, and assert the
//! resulting Row fields (u256 -> decimal string, ids -> canonical 0x,
//! tx_index/event_index, Option handling, NUMERIC vs BIGINT columns).

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn order_minted_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (u256->decimal string, tx_index/event_index, Option handling).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn live_order_redeemed_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (u256->decimal string, tx_index/event_index, Option handling).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn settled_order_redeemed_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (u256->decimal string, tx_index/event_index, Option handling).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn liquidated_order_redeemed_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (u256->decimal string, tx_index/event_index, Option handling).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn order_liquidated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (u256->decimal string, tx_index/event_index, Option handling).
}
