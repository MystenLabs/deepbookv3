// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Public-facing interface for the package.
module margin_trading::hello;

use deepbook::account::Account;
use deepbook::balance_manager::{Self, BalanceManager, TradeProof};
use deepbook::big_vector::BigVector;
use deepbook::book::{Self, Book};
use deepbook::constants;
use deepbook::deep_price::{Self, DeepPrice, OrderDeepPrice, emit_deep_price_added};
use deepbook::math;
use deepbook::order::Order;
use deepbook::order_info::{Self, OrderInfo};
use deepbook::pool::{Self, Pool};
use deepbook::registry::{DeepbookAdminCap, Registry};
use deepbook::state::{Self, State};
use deepbook::vault::{Self, Vault, FlashLoan};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::vec_set::{Self, VecSet};
use sui::versioned::{Self, Versioned};
use token::deep::{DEEP, ProtectedTreasury};

// === Errors ===
// const EInvalidFee: u64 = 1;
// const ESameBaseAndQuote: u64 = 2;
// const EInvalidTickSize: u64 = 3;
// const EInvalidLotSize: u64 = 4;
// const EInvalidMinSize: u64 = 5;
// const EInvalidQuantityIn: u64 = 6;
// const EIneligibleReferencePool: u64 = 7;
// const EInvalidOrderBalanceManager: u64 = 9;
// const EIneligibleTargetPool: u64 = 10;
// const EPackageVersionDisabled: u64 = 11;
// const EMinimumQuantityOutNotMet: u64 = 12;
// const EInvalidStake: u64 = 13;
// const EPoolNotRegistered: u64 = 14;
// const EPoolCannotBeBothWhitelistedAndStable: u64 = 15;

// === Structs ===

// === Public-Mutative Functions * EXCHANGE * ===

// public fun liquidate<BaseAsset, QuoteAsset>(

//     pool: &mut Pool<BaseAsset, QuoteAsset>,
//     account: &mut Account,
//     clock: &Clock,
//     balance_manager: &mut BalanceManager<BaseAsset, QuoteAsset>,
//     trade_proof: TradeProof<BaseAsset, QuoteAsset>,
// ) {
//     Vault::liquidate(pool, account, clock, balance_manager, trade_proof);
// }
