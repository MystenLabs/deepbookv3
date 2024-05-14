// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::trade_params {
    public struct TradeParams has store, drop, copy {
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
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
