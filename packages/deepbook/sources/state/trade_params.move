// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::trade_params {
    public struct TradeParams has store, drop, copy {
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
    }

    public(package) fun params(trade_params: &TradeParams): (u64, u64, u64) {
        (trade_params.taker_fee, trade_params.maker_fee, trade_params.stake_required)
    }

    public(package) fun new(
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
    ): TradeParams {
        TradeParams {
            taker_fee,
            maker_fee,
            stake_required,
        }
    }

    public(package) fun set_taker_fee(
        trade_params: &mut TradeParams,
        taker_fee: u64,
    ) {
        trade_params.taker_fee = taker_fee;
    }

    public(package) fun set_maker_fee(
        trade_params: &mut TradeParams,
        maker_fee: u64,
    ) {
        trade_params.maker_fee = maker_fee;
    }

    public(package) fun maker_fee(trade_params: &TradeParams): u64 {
        trade_params.maker_fee
    }

    public(package) fun taker_fee(trade_params: &TradeParams): u64 {
        trade_params.taker_fee
    }

    public(package) fun stake_required(trade_params: &TradeParams): u64 {
        trade_params.stake_required
    }
}
