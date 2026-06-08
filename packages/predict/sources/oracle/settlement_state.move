// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Settlement candidate buffers and terminal settlement state for one market oracle.
///
/// `market_oracle.move` owns authorization, source binding, and live Block Scholes
/// validation. This module owns settlement candidate recording, source priority,
/// random-subset averaging, terminal price storage, and the settled event.
module deepbook_predict::settlement_state;

use deepbook_predict::{constants, market_oracle_config::MarketOracleConfig, oracle_events};
use sui::random::RandomGenerator;

const EMarketNotSettled: u64 = 0;
const EInvalidSettlementTimestamp: u64 = 1;

const SOURCE_PYTH_SAMPLED_AVERAGE: u8 = 1;
const SOURCE_PYTH: u8 = 2;
const SOURCE_BLOCK_SCHOLES_SAMPLED_AVERAGE: u8 = 3;
const SOURCE_BLOCK_SCHOLES: u8 = 4;

/// One source observation that can become a settlement candidate.
public struct DataPoint has copy, drop, store {
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

/// Candidate state for one settlement source.
public struct SourceState has drop, store {
    samples: vector<u64>,
    last_sampled_source_timestamp_ms: u64,
    last_sampled_update_timestamp_ms: u64,
    first_post_expiry: Option<DataPoint>,
}

/// Settlement source/candidate state embedded in `MarketOracle`.
public struct SettlementState has store {
    settlement_price: Option<u64>,
    pyth: SourceState,
    block_scholes: SourceState,
}

public(package) fun source_pyth(): u8 {
    SOURCE_PYTH
}

public(package) fun source_pyth_sampled_average(): u8 {
    SOURCE_PYTH_SAMPLED_AVERAGE
}

public(package) fun source_block_scholes(): u8 {
    SOURCE_BLOCK_SCHOLES
}

public(package) fun source_block_scholes_sampled_average(): u8 {
    SOURCE_BLOCK_SCHOLES_SAMPLED_AVERAGE
}

public(package) fun new(): SettlementState {
    SettlementState {
        settlement_price: option::none(),
        pyth: new_source_state(),
        block_scholes: new_source_state(),
    }
}

public(package) fun is_settled(state: &SettlementState): bool {
    state.settlement_price.is_some()
}

public(package) fun price(state: &SettlementState): u64 {
    assert!(state.is_settled(), EMarketNotSettled);
    state.settlement_price.destroy_some()
}

public(package) fun record_pyth_observation(
    state: &mut SettlementState,
    config: &MarketOracleConfig,
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
    expiry: u64,
    now: u64,
) {
    let settled = state.is_settled();
    state
        .pyth
        .record_observation(
            config,
            DataPoint { spot, source_timestamp_ms, update_timestamp_ms },
            expiry,
            now,
            settled,
        );
}

public(package) fun record_block_scholes_observation(
    state: &mut SettlementState,
    config: &MarketOracleConfig,
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
    expiry: u64,
    now: u64,
) {
    let settled = state.is_settled();
    state
        .block_scholes
        .record_observation(
            config,
            DataPoint { spot, source_timestamp_ms, update_timestamp_ms },
            expiry,
            now,
            settled,
        );
}

public(package) fun settle(
    state: &mut SettlementState,
    market_oracle_id: ID,
    expiry: u64,
    gen: &mut RandomGenerator,
) {
    if (state.is_settled()) return;

    if (state.pyth.has_enough_samples()) {
        let price = random_subset_mean(state.pyth.samples, gen);
        let source_timestamp_ms = state.pyth.last_sampled_source_timestamp_ms;
        let update_timestamp_ms = state.pyth.last_sampled_update_timestamp_ms;
        state.commit(
            market_oracle_id,
            expiry,
            price,
            SOURCE_PYTH_SAMPLED_AVERAGE,
            source_timestamp_ms,
            update_timestamp_ms,
        );
        return;
    } else if (state.pyth.first_post_expiry.is_some()) {
        let point = state.pyth.first_post_expiry.destroy_some();
        state.commit(
            market_oracle_id,
            expiry,
            point.spot,
            SOURCE_PYTH,
            point.source_timestamp_ms,
            point.update_timestamp_ms,
        );
        return;
    } else if (state.block_scholes.has_enough_samples()) {
        let price = random_subset_mean(state.block_scholes.samples, gen);
        let source_timestamp_ms = state.block_scholes.last_sampled_source_timestamp_ms;
        let update_timestamp_ms = state.block_scholes.last_sampled_update_timestamp_ms;
        state.commit(
            market_oracle_id,
            expiry,
            price,
            SOURCE_BLOCK_SCHOLES_SAMPLED_AVERAGE,
            source_timestamp_ms,
            update_timestamp_ms,
        );
        return;
    } else if (state.block_scholes.first_post_expiry.is_some()) {
        let point = state.block_scholes.first_post_expiry.destroy_some();
        state.commit(
            market_oracle_id,
            expiry,
            point.spot,
            SOURCE_BLOCK_SCHOLES,
            point.source_timestamp_ms,
            point.update_timestamp_ms,
        );
    }
}

fun new_source_state(): SourceState {
    SourceState {
        samples: vector[],
        last_sampled_source_timestamp_ms: 0,
        last_sampled_update_timestamp_ms: 0,
        first_post_expiry: option::none(),
    }
}

fun record_observation(
    source: &mut SourceState,
    config: &MarketOracleConfig,
    point: DataPoint,
    expiry: u64,
    now: u64,
    settled: bool,
) {
    if (settled) return;

    if (now >= expiry) {
        source.record_post_expiry_candidate(config, point, expiry, now);
    } else {
        let in_window = now + constants::settlement_sample_window_ms!() >= expiry;
        if (!in_window) return;

        source.record_sample(config, point, now);
    }
}

fun record_sample(
    source: &mut SourceState,
    config: &MarketOracleConfig,
    point: DataPoint,
    now: u64,
) {
    if (!config.settlement_source_fresh(now, point.freshness_timestamp_ms())) return;
    if (point.source_timestamp_ms <= source.last_sampled_source_timestamp_ms) return;

    push_sample(&mut source.samples, point.spot);
    source.last_sampled_source_timestamp_ms = point.source_timestamp_ms;
    source.last_sampled_update_timestamp_ms = point.update_timestamp_ms;
}

fun record_post_expiry_candidate(
    source: &mut SourceState,
    config: &MarketOracleConfig,
    point: DataPoint,
    expiry: u64,
    now: u64,
) {
    if (source.first_post_expiry.is_some()) return;
    if (
        !config.settlement_source_fresh(now, point.freshness_timestamp_ms())
            || point.source_timestamp_ms <= expiry
    ) return;

    source.first_post_expiry = option::some(point);
}

fun freshness_timestamp_ms(point: &DataPoint): u64 {
    point.source_timestamp_ms.min(point.update_timestamp_ms)
}

fun commit(
    state: &mut SettlementState,
    market_oracle_id: ID,
    expiry: u64,
    settlement_price: u64,
    spot_source: u8,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    if (settlement_source_sampled(spot_source)) {
        assert!(
            source_timestamp_ms > 0 && source_timestamp_ms < expiry,
            EInvalidSettlementTimestamp,
        );
    } else {
        assert!(source_timestamp_ms > expiry, EInvalidSettlementTimestamp);
    };

    state.settlement_price = option::some(settlement_price);
    state.clear_candidates();

    oracle_events::emit_market_oracle_settled(
        market_oracle_id,
        expiry,
        settlement_price,
        spot_source,
        source_timestamp_ms,
        update_timestamp_ms,
    );
}

fun clear_candidates(state: &mut SettlementState) {
    state.pyth = new_source_state();
    state.block_scholes = new_source_state();
}

/// Append one spot, evicting the oldest sample once `max_settlement_samples` is
/// reached so the buffer keeps the most recent observations.
fun push_sample(samples: &mut vector<u64>, spot: u64) {
    if (samples.length() >= constants::max_settlement_samples!()) {
        samples.remove(0);
    };
    samples.push_back(spot);
}

fun has_enough_samples(source: &SourceState): bool {
    source.samples.length() >= constants::min_settlement_samples!()
}

fun settlement_source_sampled(spot_source: u8): bool {
    spot_source == SOURCE_PYTH_SAMPLED_AVERAGE
        || spot_source == SOURCE_BLOCK_SCHOLES_SAMPLED_AVERAGE
}

/// Random-subset mean of the collected spot samples: shuffle, then average the
/// first half (at least one). Sui native randomness makes the exact settlement
/// price unpredictable from the sample set alone. Caller guarantees at least
/// `min_settlement_samples` samples.
fun random_subset_mean(source_samples: vector<u64>, gen: &mut RandomGenerator): u64 {
    let mut samples = source_samples;
    gen.shuffle(&mut samples);
    let k = (samples.length() / 2).max(1);
    let mut sum = 0u128;
    k.do!(|i| sum = sum + (samples[i] as u128));
    (sum / (k as u128)) as u64
}
