// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One index market. The publisher cap writes each mid.
/// Open and Exit price from that mid and its standard deviation.
/// A paused market does not take a new mid.
/// When the deployer requires an enclave, Settle accepts only that enclave's result.
/// When it does not, the publisher cap writes the result.
/// Claim pays the settled payoff. A long pays above its floor. A short pays below its cap.
module venue::index_market;

use account::{account::{Self, AccountWrapper}, account_registry::AccountRegistry};
use enclave::enclave::{Self, Enclave};
use std::bcs;
use sui::{balance::{Self, Balance}, clock::Clock, ed25519, event, table::{Self, Table}};
use venue::{
    admin::AdminCap,
    deployer_admin::DeployerAdminCap,
    deployer_registry::DeployerRegistry,
    deployer_vault::Vault,
    index_curve,
    index_ticket::{Self, Ticket, VenueApp},
    market_phase,
    publisher::PublisherCap,
};

const EPhase: u64 = 0;
const EPaused: u64 = 1;
const EWindow: u64 = 2;
const EBps: u64 = 3;
const EEnclave: u64 = 4;
const EType: u64 = 5;
const ECap: u64 = 6;
const ESignature: u64 = 7;
const ETimestamp: u64 = 8;
const EQuote: u64 = 9;
const EFloor: u64 = 10;
const ECash: u64 = 11;
const ECost: u64 = 12;
const EProceeds: u64 = 13;
const ETicket: u64 = 14;
const EDeployer: u64 = 15;
const ETickets: u64 = 16;
const ESide: u64 = 17;
const EFee: u64 = 18;
/// The client sequence is not strictly newer than the sequence stored on the market.
const ESequence: u64 = 19;

const RESULT_INTENT: u8 = 1;
const LONG: u8 = 0;
const SHORT: u8 = 1;
const BPS: u64 = 10_000;
const SIGNER_KEY_LEN: u64 = 32;

public fun long_side(): u8 { LONG }

public fun short_side(): u8 { SHORT }

public struct ResultQuote has copy, drop {
    result: u64,
}

public struct FeeOverride has copy, drop {
    fee_bps: u64,
    expiry_ms: u64,
    nonce: u64,
    signature: vector<u8>,
}

public struct FeeQuote has copy, drop {
    fee_bps: u64,
    trader: address,
    market_id: ID,
    expiry_ms: u64,
    nonce: u64,
}

public struct Obligation has store, drop, copy {
    side: u8,
    floor: u64,
    cap: u64,
    size: u64,
    std: u64,
    premium: u64,
    open_cash: u64,
    worst: u64,
}

/// Bounds, fees, and windows copied at Publish. Sui rejects a struct with more than 32 fields.
public struct MarketTerms has copy, drop, store {
    lower: u64,
    upper: u64,
    ask_fee_bps: u64,
    bid_fee_bps: u64,
    wallet_fee_bps: u64,
    market_cap: u64,
    claim_window_ms: u64,
    pending_window_ms: u64,
    end_ms: u64,
    freshness_ms: u64,
    pause_max_ms: u64,
    void_window_ms: u64,
}

/// Times that move after Publish.
public struct MarketClock has copy, drop, store {
    pause_started_ms: Option<u64>,
    settled_at_ms: Option<u64>,
    ended_at_ms: Option<u64>,
    last_signed_ms: u64,
    last_mid_ms: u64,
    sequence: u64,
}

public struct IndexMarket<phantom T> has key {
    id: UID,
    deployer_id: ID,
    vault_id: ID,
    type_id: ID,
    enclave_id: Option<ID>,
    terms: MarketTerms,
    mid: u64,
    std: u64,
    has_quote: bool,
    clock: MarketClock,
    phase: u8,
    admin_paused: bool,
    deployer_paused: bool,
    voided: bool,
    result: Option<u64>,
    cash: Balance<T>,
    held_fees: Balance<T>,
    owed: u64,
    live_gain: u64,
    live_loss: u64,
    open_ids: vector<ID>,
    obligations: Table<ID, Obligation>,
    nonce_traders: vector<address>,
    nonces: Table<address, vector<u64>>,
    last_paid: u64,
}

public fun fee_override(fee_bps: u64, expiry_ms: u64, nonce: u64, signature: vector<u8>): FeeOverride {
    FeeOverride { fee_bps, expiry_ms, nonce, signature }
}

public struct MarketPublished has copy, drop {
    market_id: ID,
    deployer_id: ID,
    market_cap: u64,
}

public struct MidPublished has copy, drop {
    market_id: ID,
    mid: u64,
    bid_fee_bps: u64,
    ask_fee_bps: u64,
    std: u64,
    sequence: u64,
    timestamp_ms: u64,
}

public struct Opened has copy, drop {
    market_id: ID,
    ticket_id: ID,
    side: u8,
    worst: u64,
    premium: u64,
    std: u64,
    open_cash: u64,
    owed: u64,
}

public struct Exited has copy, drop {
    market_id: ID,
    ticket_id: ID,
    premium: u64,
    open_cash: u64,
    proceeds: u64,
    owed: u64,
}

public struct Claimed has copy, drop {
    market_id: ID,
    ticket_id: ID,
    premium: u64,
    open_cash: u64,
    paid: u64,
    owed: u64,
}

public struct Settled has copy, drop {
    market_id: ID,
    result: u64,
    owed: u64,
}

public struct Voided has copy, drop {
    market_id: ID,
    owed: u64,
    sender: address,
}

public struct Rebalanced has copy, drop {
    market_id: ID,
    amount: u64,
    to_market: bool,
    market_cash: u64,
}

public struct Ended has copy, drop {
    market_id: ID,
    ended_at_ms: u64,
}

/// Creates a live market and shares it. The first mid arrives through `publish_mid`.
public fun publish<T>(
    registry: &DeployerRegistry,
    vault: &Vault<T>,
    cap: &PublisherCap,
    enclave: &Enclave<VenueApp>,
    type_id: ID,
    lower: u64,
    upper: u64,
    ask_fee_bps: u64,
    bid_fee_bps: u64,
    market_cap: u64,
    claim_window_ms: u64,
    pending_window_ms: u64,
    end_ms: u64,
    freshness_ms: u64,
    pause_max_ms: u64,
    void_window_ms: u64,
    ctx: &mut TxContext,
) {
    transfer::share_object(build(
        registry, vault, cap, enclave, type_id, lower, upper, ask_fee_bps, bid_fee_bps,
        market_cap, claim_window_ms, pending_window_ms, end_ms, freshness_ms, pause_max_ms,
        void_window_ms, ctx,
    ));
}

/// Creates a live market with no enclave id. Settle then requires the publisher cap while the enclave flag is off.
public fun publish_with_key<T>(
    registry: &DeployerRegistry,
    vault: &Vault<T>,
    cap: &PublisherCap,
    type_id: ID,
    lower: u64,
    upper: u64,
    ask_fee_bps: u64,
    bid_fee_bps: u64,
    market_cap: u64,
    claim_window_ms: u64,
    pending_window_ms: u64,
    end_ms: u64,
    freshness_ms: u64,
    pause_max_ms: u64,
    void_window_ms: u64,
    ctx: &mut TxContext,
) {
    transfer::share_object(build_with_key(
        registry, vault, cap, type_id, lower, upper, ask_fee_bps, bid_fee_bps,
        market_cap, claim_window_ms, pending_window_ms, end_ms, freshness_ms, pause_max_ms,
        void_window_ms, ctx,
    ));
}

/// Builds a market without sharing it. Tests hold the value for the rest of the transaction.
public(package) fun build<T>(
    registry: &DeployerRegistry,
    vault: &Vault<T>,
    cap: &PublisherCap,
    enclave: &Enclave<VenueApp>,
    type_id: ID,
    lower: u64,
    upper: u64,
    ask_fee_bps: u64,
    bid_fee_bps: u64,
    market_cap: u64,
    claim_window_ms: u64,
    pending_window_ms: u64,
    end_ms: u64,
    freshness_ms: u64,
    pause_max_ms: u64,
    void_window_ms: u64,
    ctx: &mut TxContext,
): IndexMarket<T> {
    finish(
        registry, vault, cap, type_id, option::some(object::id(enclave)), lower, upper, ask_fee_bps, bid_fee_bps,
        market_cap, claim_window_ms, pending_window_ms, end_ms, freshness_ms, pause_max_ms, void_window_ms, ctx,
    )
}

/// Builds a market with no enclave id. Tests hold the value.
public(package) fun build_with_key<T>(
    registry: &DeployerRegistry,
    vault: &Vault<T>,
    cap: &PublisherCap,
    type_id: ID,
    lower: u64,
    upper: u64,
    ask_fee_bps: u64,
    bid_fee_bps: u64,
    market_cap: u64,
    claim_window_ms: u64,
    pending_window_ms: u64,
    end_ms: u64,
    freshness_ms: u64,
    pause_max_ms: u64,
    void_window_ms: u64,
    ctx: &mut TxContext,
): IndexMarket<T> {
    finish(
        registry, vault, cap, type_id, option::none(), lower, upper, ask_fee_bps, bid_fee_bps,
        market_cap, claim_window_ms, pending_window_ms, end_ms, freshness_ms, pause_max_ms, void_window_ms, ctx,
    )
}

fun finish<T>(
    registry: &DeployerRegistry,
    vault: &Vault<T>,
    cap: &PublisherCap,
    type_id: ID,
    enclave_id: Option<ID>,
    lower: u64,
    upper: u64,
    ask_fee_bps: u64,
    bid_fee_bps: u64,
    market_cap: u64,
    claim_window_ms: u64,
    pending_window_ms: u64,
    end_ms: u64,
    freshness_ms: u64,
    pause_max_ms: u64,
    void_window_ms: u64,
    ctx: &mut TxContext,
): IndexMarket<T> {
    assert!(cap.deployer_id() == vault.deployer_id(), EDeployer);
    assert!(!registry.stopped(vault.deployer_id()), EPaused);
    assert!(!registry.paused(vault.deployer_id()), EPaused);
    assert!(claim_window_ms >= registry.min_claim_window_ms(), EWindow);
    assert!(registry.has_type(vault.deployer_id(), type_id), EType);
    assert!(registry.type_exists(type_id), EType);
    if (enclave_id.is_some()) {
        assert!(registry.has_enclave(vault.deployer_id(), *enclave_id.borrow()), EEnclave);
    } else if (registry.enclave_required(vault.deployer_id())) {
        abort EEnclave
    };
    assert!(ask_fee_bps <= BPS && bid_fee_bps <= BPS, EBps);
    assert!(upper > lower, EFloor);
    assert!(market_cap > 0, ECap);
    if (registry.market_cap_ceiling(vault.deployer_id()).is_some()) {
        assert!(market_cap <= registry.market_cap_ceiling(vault.deployer_id()).destroy_some(), ECap);
    };
    let vault_id = object::id(vault);
    assert!(registry.vault_id(vault.deployer_id()) == option::some(vault_id), EDeployer);
    let market = IndexMarket<T> {
        id: object::new(ctx),
        deployer_id: vault.deployer_id(),
        vault_id,
        type_id,
        enclave_id,
        terms: MarketTerms {
            lower,
            upper,
            ask_fee_bps,
            bid_fee_bps,
            wallet_fee_bps: registry.wallet_fee_bps(vault.deployer_id()),
            market_cap,
            claim_window_ms,
            pending_window_ms,
            end_ms,
            freshness_ms,
            pause_max_ms,
            void_window_ms,
        },
        mid: 0,
        std: 0,
        has_quote: false,
        clock: MarketClock {
            pause_started_ms: option::none(),
            settled_at_ms: option::none(),
            ended_at_ms: option::none(),
            last_signed_ms: 0,
            last_mid_ms: 0,
            sequence: 0,
        },
        phase: market_phase::live(),
        admin_paused: false,
        deployer_paused: false,
        voided: false,
        result: option::none(),
        cash: balance::zero(),
        held_fees: balance::zero(),
        owed: 0,
        live_gain: 0,
        live_loss: 0,
        open_ids: vector[],
        obligations: table::new(ctx),
        nonce_traders: vector[],
        nonces: table::new(ctx),
        last_paid: 0,
    };
    event::emit(MarketPublished {
        market_id: object::id(&market),
        deployer_id: market.deployer_id,
        market_cap,
    });
    market
}

#[test_only]
public fun destroy_for_testing<T>(market: IndexMarket<T>, vault: &mut Vault<T>) {
    let IndexMarket {
        id, cash, held_fees, obligations, open_ids, nonces, nonce_traders, live_gain, live_loss, ..
    } = market;
    assert!(open_ids.is_empty(), ETickets);
    vault.replace_live(live_gain, live_loss, 0, 0);
    id.delete();
    obligations.destroy_empty();
    drop_nonces(nonce_traders, nonces);
    let mut cash = cash;
    cash.join(held_fees);
    vault.join_cash(cash);
}

/// Writes the mid, both fee rates, and the standard deviation. The publisher cap is the authority.
/// A long Open uses the ask from this push. A short Open uses the bid. Exit swaps those two.
public fun publish_mid<T>(
    market: &mut IndexMarket<T>,
    vault: &mut Vault<T>,
    cap: &PublisherCap,
    mid: u64,
    bid_fee_bps: u64,
    ask_fee_bps: u64,
    std: u64,
    sequence: u64,
    clock: &Clock,
) {
    assert!(cap.deployer_id() == market.deployer_id, EDeployer);
    assert!(object::id(vault) == market.vault_id, EDeployer);
    assert!(sequence > market.clock.sequence, ESequence);
    market.clock.sequence = sequence;
    store_mid(market, mid, bid_fee_bps, ask_fee_bps, std, clock);
    sync_mark(market, vault);
}

/// Opens one ticket. `bound` is the floor of a long and the cap of a short.
/// An absent fee override charges the ask from the latest mid on a long and the bid from the latest mid on a short.
public fun open<T>(
    market: &mut IndexMarket<T>,
    vault: &mut Vault<T>,
    registry: &DeployerRegistry,
    _accounts: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    side: u8,
    bound: u64,
    size: u64,
    max_cost: u64,
    fee: Option<FeeOverride>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_trading(market, registry);
    assert_fresh(market, clock);
    assert!(size > 0, EFloor);
    assert!(side == LONG || side == SHORT, ESide);
    let (floor, cap) = bounds(market, side, bound);
    let premium = price_of(market, side, floor, cap, size);
    let fee_bps = take_fee(market, registry, side, fee, clock, ctx);
    let fee_cash = index_curve::fee_on(premium, fee_bps);
    let open_cash = premium + fee_cash;
    assert!(open_cash <= max_cost, ECost);
    let worst = index_curve::worst_case(floor, cap, size);
    let new_owed = max_claims_with(market, side, floor, cap, size);
    assert!(new_owed <= market.terms.market_cap, ECap);
    assert!(spendable(market) >= new_owed.saturating_sub(premium), ECash);
    let auth = account::generate_auth(ctx);
    let coin = wrapper.load_account_mut(auth).withdraw<T>(open_cash, ctx);
    let mut paid = coin.into_balance();
    market.held_fees.join(paid.split(fee_cash));
    market.cash.join(paid);
    market.owed = new_owed;
    let entry_mid = market.mid;
    let ticket = index_ticket::new(
        object::id(market),
        side,
        floor,
        cap,
        size,
        market.std,
        entry_mid,
        premium,
        open_cash,
        worst,
        ctx,
    );
    let ticket_id = index_ticket::id(&ticket);
    market.open_ids.push_back(ticket_id);
    market.obligations.add(
        ticket_id,
        Obligation { side, floor, cap, size, std: market.std, premium, open_cash, worst },
    );
    sync_mark(market, vault);
    let account = wrapper.load_account_mut(account::generate_auth(ctx));
    index_ticket::insert(account, ticket, ctx);
    event::emit(Opened {
        market_id: object::id(market),
        ticket_id,
        side,
        worst,
        premium,
        std: market.std,
        open_cash,
        owed: market.owed,
    });
}

/// Sells the whole ticket at the live mid and the live standard deviation.
/// A long pays the bid fee. A short pays the ask fee.
public fun exit<T>(
    market: &mut IndexMarket<T>,
    vault: &mut Vault<T>,
    registry: &DeployerRegistry,
    _accounts: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    ticket_id: ID,
    min_proceeds: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_trading(market, registry);
    assert_fresh(market, clock);
    assert!(object::id(vault) == market.vault_id, EDeployer);
    let ticket = {
        let account = wrapper.load_account_mut(account::generate_auth(ctx));
        index_ticket::remove(account, ticket_id)
    };
    assert!(index_ticket::market_id(&ticket) == object::id(market), ETicket);
    let price = price_of(
        market,
        index_ticket::side(&ticket),
        index_ticket::floor(&ticket),
        index_ticket::cap(&ticket),
        index_ticket::size(&ticket),
    );
    let fee_bps = if (index_ticket::side(&ticket) == SHORT) { market.terms.ask_fee_bps } else { market.terms.bid_fee_bps };
    let fee_cash = index_curve::fee_on(price, fee_bps);
    let proceeds = price - fee_cash;
    assert!(proceeds >= min_proceeds, EProceeds);
    assert!(spendable(market) >= price, ECash);
    let premium = index_ticket::premium_of(&ticket);
    let (loss, gain) = if (premium >= price) { (0, premium - price) } else { (price - premium, 0) };
    drop_ticket(market, &ticket);
    sync_mark(market, vault);
    vault.realize(loss, gain);
    let exit_fee = market.cash.split(fee_cash);
    market.held_fees.join(exit_fee);
    if (proceeds > 0) {
        let auth = account::generate_auth(ctx);
        let coin = market.cash.split(proceeds).into_coin(ctx);
        wrapper.load_account_mut(auth).deposit(coin);
    };
    market.last_paid = proceeds;
    cover_owed(market, vault);
    event::emit(Exited {
        market_id: object::id(market),
        ticket_id,
        premium,
        open_cash: index_ticket::open_cash_of(&ticket),
        proceeds,
        owed: market.owed,
    });
    index_ticket::destroy(ticket);
}

public fun end_as_publisher<T>(market: &mut IndexMarket<T>, cap: &PublisherCap, clock: &Clock) {
    assert!(cap.deployer_id() == market.deployer_id, EDeployer);
    end(market, clock);
}

public fun end_as_deployer<T>(market: &mut IndexMarket<T>, cap: &DeployerAdminCap, clock: &Clock) {
    assert!(cap.deployer_id() == market.deployer_id, EDeployer);
    end(market, clock);
}

/// Ends trading once the clock has reached the market's end time.
public fun end_after_clock<T>(market: &mut IndexMarket<T>, clock: &Clock) {
    assert!(clock.timestamp_ms() >= market.terms.end_ms, EWindow);
    end(market, clock);
}

/// Stores a Nautilus result. The deployer flag must require an enclave.
public fun settle<T>(
    market: &mut IndexMarket<T>,
    vault: &mut Vault<T>,
    registry: &DeployerRegistry,
    enclave: &Enclave<VenueApp>,
    result: u64,
    timestamp_ms: u64,
    signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(registry.enclave_required(market.deployer_id), EEnclave);
    assert_pending(market, vault, clock);
    assert!(market.enclave_id.is_some(), EEnclave);
    assert!(object::id(enclave) == *market.enclave_id.borrow(), EEnclave);
    assert!(
        enclave.verify_signature(RESULT_INTENT, timestamp_ms, ResultQuote { result }, &signature),
        ESignature,
    );
    write_result(market, vault, registry, result, timestamp_ms, clock, ctx);
}

/// Writes the result from the publisher cap. The deployer flag must not require an enclave.
public fun settle_as_publisher<T>(
    market: &mut IndexMarket<T>,
    vault: &mut Vault<T>,
    registry: &DeployerRegistry,
    cap: &PublisherCap,
    result: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!registry.enclave_required(market.deployer_id), EEnclave);
    assert!(cap.deployer_id() == market.deployer_id, EDeployer);
    assert_pending(market, vault, clock);
    write_result(market, vault, registry, result, clock.timestamp_ms(), clock, ctx);
}

/// Voids once a pause has lasted `pause_max_ms`, once pending plus the void window has passed, or once the deployer is stopped.
public fun void<T>(
    market: &mut IndexMarket<T>,
    vault: &mut Vault<T>,
    registry: &DeployerRegistry,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(public_void_open(market, registry, clock), EWindow);
    assert!(object::id(vault) == market.vault_id, EDeployer);
    clear_live(market, vault);
    void_market(market, clock, ctx);
}

/// Voids the market. Claim later returns each ticket's open cash.
public fun void_as_admin<T>(
    market: &mut IndexMarket<T>,
    vault: &mut Vault<T>,
    _cap: &AdminCap,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(object::id(vault) == market.vault_id, EDeployer);
    clear_live(market, vault);
    void_market(market, clock, ctx);
}

/// Voids the market with the deployer admin cap.
public fun void_as_deployer<T>(
    market: &mut IndexMarket<T>,
    vault: &mut Vault<T>,
    cap: &DeployerAdminCap,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(cap.deployer_id() == market.deployer_id, EDeployer);
    assert!(object::id(vault) == market.vault_id, EDeployer);
    clear_live(market, vault);
    void_market(market, clock, ctx);
}

/// Sets the admin pause flag and moves a live market to the paused phase.
public fun pause_as_admin<T>(market: &mut IndexMarket<T>, _cap: &AdminCap, clock: &Clock) {
    if (market.admin_paused) return;
    market.admin_paused = true;
    note_pause(market, clock);
}

/// Sets the deployer pause flag on this market.
public fun pause_as_deployer<T>(market: &mut IndexMarket<T>, cap: &DeployerAdminCap, clock: &Clock) {
    assert!(cap.deployer_id() == market.deployer_id, EDeployer);
    if (market.deployer_paused) return;
    market.deployer_paused = true;
    note_pause(market, clock);
}

/// Clears the deployer pause flag.
public fun resume_as_deployer<T>(market: &mut IndexMarket<T>, cap: &DeployerAdminCap) {
    assert!(cap.deployer_id() == market.deployer_id, EDeployer);
    if (!market.deployer_paused) return;
    market.deployer_paused = false;
    note_resume(market);
}

/// Clears the admin pause flag.
public fun unblock<T>(market: &mut IndexMarket<T>, _cap: &AdminCap) {
    if (!market.admin_paused) return;
    market.admin_paused = false;
    note_resume(market);
}

/// Pays a settled ticket into the sender's account.
public fun claim<T>(
    market: &mut IndexMarket<T>,
    _accounts: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    ticket_id: ID,
    ctx: &mut TxContext,
) {
    assert!(market.phase == market_phase::settlement(), EPhase);
    let ticket = {
        let account = wrapper.load_account_mut(account::generate_auth(ctx));
        index_ticket::remove(account, ticket_id)
    };
    assert!(index_ticket::market_id(&ticket) == object::id(market), ETicket);
    let paid = if (market.voided) {
        index_ticket::open_cash_of(&ticket)
    } else if (index_ticket::side(&ticket) == SHORT) {
        index_curve::short_payout(
            index_ticket::size(&ticket),
            index_ticket::floor(&ticket),
            index_ticket::cap(&ticket),
            *market.result.borrow(),
        )
    } else {
        index_curve::claim_payout(
            index_ticket::size(&ticket),
            index_ticket::floor(&ticket),
            index_ticket::cap(&ticket),
            *market.result.borrow(),
        )
    };
    let premium = index_ticket::premium_of(&ticket);
    let open_cash = index_ticket::open_cash_of(&ticket);
    drop_ticket(market, &ticket);
    market.owed = market.owed.saturating_sub(paid);
    if (paid > 0) {
        let auth = account::generate_auth(ctx);
        let coin = market.cash.split(paid).into_coin(ctx);
        wrapper.load_account_mut(auth).deposit(coin);
    };
    market.last_paid = paid;
    event::emit(Claimed {
        market_id: object::id(market),
        ticket_id,
        premium,
        open_cash,
        paid,
        owed: market.owed,
    });
    index_ticket::destroy(ticket);
}

/// Replaces this market's cap. Rebalance reads the new cap on the next call.
public fun set_market_cap<T>(
    market: &mut IndexMarket<T>,
    registry: &DeployerRegistry,
    cap: &DeployerAdminCap,
    market_cap: u64,
) {
    assert!(cap.deployer_id() == market.deployer_id, EDeployer);
    assert!(market_cap > 0, ECap);
    if (registry.market_cap_ceiling(market.deployer_id).is_some()) {
        assert!(market_cap <= registry.market_cap_ceiling(market.deployer_id).destroy_some(), ECap);
    };
    market.terms.market_cap = market_cap;
}

/// Moves cash between the vault and the market when the band is crossed.
public fun rebalance<T>(
    market: &mut IndexMarket<T>,
    vault: &mut Vault<T>,
    registry: &DeployerRegistry,
) {
    if (market.phase != market_phase::live() && market.phase != market_phase::paused()) return;
    assert!(object::id(vault) == market.vault_id, EDeployer);
    let bps = registry.rebalance_bps(market.deployer_id);
    let target = band_target(market.owed, market.terms.market_cap, bps);
    let upper = band_upper(market.owed, bps);
    let cash_now = spendable(market);
    if (cash_now < target) {
        let want = target - cash_now;
        let pulled = if (want < vault.cash()) { want } else { vault.cash() };
        if (pulled == 0) return;
        market.cash.join(vault.split_cash(pulled));
        event::emit(Rebalanced {
            market_id: object::id(market),
            amount: pulled,
            to_market: true,
            market_cash: market.cash.value(),
        });
    } else if (cash_now > upper) {
        let send = cash_now - target;
        if (send == 0) return;
        vault.join_cash(market.cash.split(send));
        event::emit(Rebalanced {
            market_id: object::id(market),
            amount: send,
            to_market: false,
            market_cash: market.cash.value(),
        });
    }
}

/// Returns leftover cash to the vault once every ticket is claimed and the window has elapsed.
public fun destroy<T>(market: IndexMarket<T>, vault: &mut Vault<T>, clock: &Clock) {
    assert!(market.phase == market_phase::settlement(), EPhase);
    assert!(market.open_ids.is_empty(), ETickets);
    let settled = *market.clock.settled_at_ms.borrow();
    assert!(
        (clock.timestamp_ms() as u128) >= (settled as u128) + (market.terms.claim_window_ms as u128),
        EWindow,
    );
    assert!(object::id(vault) == market.vault_id, EDeployer);
    let IndexMarket {
        id,
        cash,
        held_fees,
        obligations,
        open_ids: _,
        nonces,
        nonce_traders,
        live_gain,
        live_loss,
        ..,
    } = market;
    vault.replace_live(live_gain, live_loss, 0, 0);
    id.delete();
    obligations.destroy_empty();
    drop_nonces(nonce_traders, nonces);
    let mut cash = cash;
    cash.join(held_fees);
    vault.join_cash(cash);
}

public fun cash<T>(market: &IndexMarket<T>): u64 { market.cash.value() }

public fun owed<T>(market: &IndexMarket<T>): u64 { market.owed }

public fun mid<T>(market: &IndexMarket<T>): u64 { market.mid }

public fun std<T>(market: &IndexMarket<T>): u64 { market.std }

public fun phase<T>(market: &IndexMarket<T>): u8 { market.phase }

public fun held_fees<T>(market: &IndexMarket<T>): u64 { market.held_fees.value() }

public fun wallet_fee_bps<T>(market: &IndexMarket<T>): u64 { market.terms.wallet_fee_bps }

public fun sequence<T>(market: &IndexMarket<T>): u64 { market.clock.sequence }

public fun admin_paused<T>(market: &IndexMarket<T>): bool { market.admin_paused }

public fun open_count<T>(market: &IndexMarket<T>): u64 { market.open_ids.length() }

public fun open_ticket<T>(market: &IndexMarket<T>, index: u64): ID { market.open_ids[index] }

public fun last_paid<T>(market: &IndexMarket<T>): u64 { market.last_paid }

fun store_mid<T>(
    market: &mut IndexMarket<T>,
    mid: u64,
    bid_fee_bps: u64,
    ask_fee_bps: u64,
    std: u64,
    clock: &Clock,
) {
    assert!(market.phase == market_phase::live(), EPhase);
    assert!(std > 0, EQuote);
    assert!(ask_fee_bps <= BPS && bid_fee_bps <= BPS, EBps);
    market.mid = mid;
    market.std = std;
    market.terms.bid_fee_bps = bid_fee_bps;
    market.terms.ask_fee_bps = ask_fee_bps;
    market.has_quote = true;
    market.clock.last_mid_ms = clock.timestamp_ms();
    event::emit(MidPublished {
        market_id: object::id(market),
        mid,
        bid_fee_bps,
        ask_fee_bps,
        std,
        sequence: market.clock.sequence,
        timestamp_ms: market.clock.last_mid_ms,
    });
}

fun write_result<T>(
    market: &mut IndexMarket<T>,
    vault: &mut Vault<T>,
    registry: &DeployerRegistry,
    result: u64,
    timestamp_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(timestamp_ms > market.clock.last_signed_ms, ETimestamp);
    assert!(timestamp_ms <= clock.timestamp_ms(), ETimestamp);
    let claims = sum_claims(market, result);
    let premiums = sum_premiums(market);
    clear_live(market, vault);
    let (loss, gain) = if (claims > premiums) { (claims - premiums, 0) } else { (0, premiums - claims) };
    market.result = option::some(result);
    market.voided = false;
    market.phase = market_phase::settlement();
    market.clock.settled_at_ms = option::some(clock.timestamp_ms());
    market.clock.last_signed_ms = timestamp_ms;
    market.owed = claims;
    split_held_fee(market, vault, registry, loss, gain, ctx);
    event::emit(Settled { market_id: object::id(market), result, owed: market.owed });
}

fun assert_trading<T>(market: &IndexMarket<T>, registry: &DeployerRegistry) {
    assert!(market.phase == market_phase::live(), EPhase);
    assert!(!market.admin_paused, EPaused);
    assert!(!market.deployer_paused, EPaused);
    assert!(!registry.paused(market.deployer_id), EPaused);
    assert!(!registry.stopped(market.deployer_id), EPaused);
}

fun end<T>(market: &mut IndexMarket<T>, clock: &Clock) {
    assert!(market.phase == market_phase::live() || market.phase == market_phase::paused(), EPhase);
    market.phase = market_phase::pending();
    let ended_at_ms = clock.timestamp_ms();
    market.clock.ended_at_ms = option::some(ended_at_ms);
    event::emit(Ended { market_id: object::id(market), ended_at_ms });
}

fun void_market<T>(market: &mut IndexMarket<T>, clock: &Clock, ctx: &TxContext) {
    assert!(market.phase != market_phase::settlement(), EPhase);
    market.voided = true;
    market.result = option::none();
    market.phase = market_phase::settlement();
    market.clock.settled_at_ms = option::some(clock.timestamp_ms());
    market.owed = sum_open_cash(market);
    let fee_value = market.held_fees.value();
    let fees = market.held_fees.split(fee_value);
    market.cash.join(fees);
    event::emit(Voided { market_id: object::id(market), owed: market.owed, sender: ctx.sender() });
}

fun split_held_fee<T>(
    market: &mut IndexMarket<T>,
    vault: &mut Vault<T>,
    registry: &DeployerRegistry,
    loss: u64,
    gain: u64,
    ctx: &mut TxContext,
) {
    let fee_value = market.held_fees.value();
    let fee = market.held_fees.split(fee_value);
    if (loss == 0 && gain == 0 && fee.value() == 0) {
        fee.destroy_zero();
        return
    };
    vault.account_result(registry, loss, gain, market.terms.wallet_fee_bps, balance::zero(), fee, ctx);
}

fun drop_ticket<T>(market: &mut IndexMarket<T>, ticket: &Ticket) {
    let ticket_id = index_ticket::id(ticket);
    remove_open_id(&mut market.open_ids, ticket_id);
    let Obligation { .. } = market.obligations.remove(ticket_id);
}

fun spendable<T>(market: &IndexMarket<T>): u64 {
    market.cash.value()
}

fun sum_claims<T>(market: &IndexMarket<T>, result: u64): u64 {
    let ids = market.open_ids;
    let mut i = 0;
    let mut total = 0;
    while (i < ids.length()) {
        let ob = market.obligations.borrow(ids[i]);
        let pay = if (ob.side == SHORT) {
            index_curve::short_payout(ob.size, ob.floor, ob.cap, result)
        } else {
            index_curve::claim_payout(ob.size, ob.floor, ob.cap, result)
        };
        total = total + pay;
        i = i + 1;
    };
    total
}

fun sum_premiums<T>(market: &IndexMarket<T>): u64 {
    let ids = market.open_ids;
    let mut i = 0;
    let mut total = 0;
    while (i < ids.length()) {
        total = total + market.obligations.borrow(ids[i]).premium;
        i = i + 1;
    };
    total
}

fun assert_fresh<T>(market: &IndexMarket<T>, clock: &Clock) {
    assert!(market.has_quote, EQuote);
    let now = clock.timestamp_ms();
    assert!(now >= market.clock.last_mid_ms, EWindow);
    assert!(now - market.clock.last_mid_ms <= market.terms.freshness_ms, EWindow);
}

fun assert_pending<T>(market: &IndexMarket<T>, vault: &Vault<T>, clock: &Clock) {
    assert!(market.phase == market_phase::pending(), EPhase);
    assert!(object::id(vault) == market.vault_id, EDeployer);
    let ended = *market.clock.ended_at_ms.borrow();
    assert!((clock.timestamp_ms() as u128) >= (ended as u128) + (market.terms.pending_window_ms as u128), EWindow);
}

fun bounds<T>(market: &IndexMarket<T>, side: u8, bound: u64): (u64, u64) {
    if (side == LONG) {
        assert!(bound >= market.terms.lower && bound < market.terms.upper, EFloor);
        (bound, market.terms.upper)
    } else {
        assert!(bound > market.terms.lower && bound <= market.terms.upper, EFloor);
        (market.terms.lower, bound)
    }
}

fun price_of<T>(market: &IndexMarket<T>, side: u8, floor: u64, cap: u64, size: u64): u64 {
    if (side == SHORT) {
        index_curve::short_price(market.mid, floor, cap, market.std, size)
    } else {
        index_curve::spread_price(market.mid, floor, cap, market.std, size)
    }
}

fun take_fee<T>(
    market: &mut IndexMarket<T>,
    registry: &DeployerRegistry,
    side: u8,
    fee: Option<FeeOverride>,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    if (fee.is_none()) {
        fee.destroy_none();
        if (side == SHORT) { market.terms.bid_fee_bps } else { market.terms.ask_fee_bps }
    } else {
        let FeeOverride { fee_bps, expiry_ms, nonce, signature } = fee.destroy_some();
        assert!(fee_bps <= BPS, EBps);
        assert!(clock.timestamp_ms() < expiry_ms, EFee);
        let trader = ctx.sender();
        let quote = FeeQuote {
            fee_bps,
            trader,
            market_id: object::id(market),
            expiry_ms,
            nonce,
        };
        let pk = registry.fee_public_key(market.deployer_id);
        assert!(pk.length() == SIGNER_KEY_LEN, ESignature);
        assert!(ed25519::ed25519_verify(&signature, &pk, &bcs::to_bytes(&quote)), ESignature);
        record_nonce(market, trader, nonce);
        fee_bps
    }
}

fun record_nonce<T>(market: &mut IndexMarket<T>, trader: address, nonce: u64) {
    if (!market.nonces.contains(trader)) {
        market.nonces.add(trader, vector[]);
        market.nonce_traders.push_back(trader);
    };
    let used = market.nonces.borrow_mut(trader);
    let mut i = 0;
    while (i < used.length()) {
        assert!(used[i] != nonce, EFee);
        i = i + 1;
    };
    used.push_back(nonce);
}

fun sync_mark<T>(market: &mut IndexMarket<T>, vault: &mut Vault<T>) {
    let (gain, loss) = book_mark(market);
    vault.replace_live(market.live_gain, market.live_loss, gain, loss);
    market.live_gain = gain;
    market.live_loss = loss;
}

fun clear_live<T>(market: &mut IndexMarket<T>, vault: &mut Vault<T>) {
    vault.replace_live(market.live_gain, market.live_loss, 0, 0);
    market.live_gain = 0;
    market.live_loss = 0;
}

fun book_mark<T>(market: &IndexMarket<T>): (u64, u64) {
    let mut gain = 0;
    let mut loss = 0;
    let mut i = 0;
    while (i < market.open_ids.length()) {
        let ob = market.obligations.borrow(market.open_ids[i]);
        let price = price_of(market, ob.side, ob.floor, ob.cap, ob.size);
        if (ob.premium >= price) {
            gain = gain + (ob.premium - price);
        } else {
            loss = loss + (price - ob.premium);
        };
        i = i + 1;
    };
    (gain, loss)
}

fun public_void_open<T>(market: &IndexMarket<T>, registry: &DeployerRegistry, clock: &Clock): bool {
    if (market.phase == market_phase::settlement()) return false;
    if (registry.stopped(market.deployer_id)) return true;
    if ((market.admin_paused || market.deployer_paused) && market.clock.pause_started_ms.is_some()) {
        let started = *market.clock.pause_started_ms.borrow();
        if ((clock.timestamp_ms() as u128) >= (started as u128) + (market.terms.pause_max_ms as u128)) {
            return true
        };
    };
    if (market.phase == market_phase::pending() && market.clock.ended_at_ms.is_some()) {
        let ended = *market.clock.ended_at_ms.borrow();
        let wait = (market.terms.pending_window_ms as u128) + (market.terms.void_window_ms as u128);
        if ((clock.timestamp_ms() as u128) >= (ended as u128) + wait) return true;
    };
    false
}

fun note_pause<T>(market: &mut IndexMarket<T>, clock: &Clock) {
    if (market.clock.pause_started_ms.is_none()) {
        market.clock.pause_started_ms = option::some(clock.timestamp_ms());
    };
    if (market.phase == market_phase::live()) {
        market.phase = market_phase::paused();
    };
}

fun note_resume<T>(market: &mut IndexMarket<T>) {
    if (!market.admin_paused && !market.deployer_paused) {
        market.clock.pause_started_ms = option::none();
        if (market.phase == market_phase::paused()) {
            market.phase = market_phase::live();
        };
    }
}

fun drop_nonces(mut traders: vector<address>, mut nonces: Table<address, vector<u64>>) {
    while (!traders.is_empty()) {
        let trader = traders.pop_back();
        let _used = nonces.remove(trader);
    };
    traders.destroy_empty();
    nonces.destroy_empty();
}

fun sum_open_cash<T>(market: &IndexMarket<T>): u64 {
    let ids = market.open_ids;
    let mut i = 0;
    let mut total = 0;
    while (i < ids.length()) {
        total = total + market.obligations.borrow(ids[i]).open_cash;
        i = i + 1;
    };
    total
}

fun remove_open_id(ids: &mut vector<ID>, id: ID) {
    let mut i = 0;
    let n = ids.length();
    while (i < n) {
        if (ids[i] == id) {
            ids.swap_remove(i);
            return
        };
        i = i + 1;
    };
    abort ETicket
}

/// The most USDC the open tickets can claim at one result.
/// Each bound is a kink. The max of a straight line between kinks sits on a kink.
fun max_claims<T>(market: &IndexMarket<T>): u64 {
    let mut best = claims_at(market, market.terms.lower);
    best = higher(best, claims_at(market, market.terms.upper));
    let mut i = 0;
    while (i < market.open_ids.length()) {
        let ob = market.obligations.borrow(market.open_ids[i]);
        let floor = ob.floor;
        let cap = ob.cap;
        best = higher(best, claims_at(market, floor));
        best = higher(best, claims_at(market, cap));
        i = i + 1;
    };
    best
}

/// `max_claims` as it would read after one more ticket, before that ticket is stored.
fun max_claims_with<T>(market: &IndexMarket<T>, side: u8, floor: u64, cap: u64, size: u64): u64 {
    let mut best = claims_at(market, market.terms.lower) + leg_at(side, floor, cap, size, market.terms.lower);
    best = higher(best, claims_at(market, market.terms.upper) + leg_at(side, floor, cap, size, market.terms.upper));
    best = higher(best, claims_at(market, floor) + leg_at(side, floor, cap, size, floor));
    best = higher(best, claims_at(market, cap) + leg_at(side, floor, cap, size, cap));
    let mut i = 0;
    while (i < market.open_ids.length()) {
        let ob = market.obligations.borrow(market.open_ids[i]);
        let ob_floor = ob.floor;
        let ob_cap = ob.cap;
        best = higher(best, claims_at(market, ob_floor) + leg_at(side, floor, cap, size, ob_floor));
        best = higher(best, claims_at(market, ob_cap) + leg_at(side, floor, cap, size, ob_cap));
        i = i + 1;
    };
    best
}

fun claims_at<T>(market: &IndexMarket<T>, result: u64): u64 {
    let mut i = 0;
    let mut total = 0;
    while (i < market.open_ids.length()) {
        let ob = market.obligations.borrow(market.open_ids[i]);
        total = total + leg_at(ob.side, ob.floor, ob.cap, ob.size, result);
        i = i + 1;
    };
    total
}

fun leg_at(side: u8, floor: u64, cap: u64, size: u64, result: u64): u64 {
    if (side == SHORT) {
        index_curve::short_payout(size, floor, cap, result)
    } else {
        index_curve::claim_payout(size, floor, cap, result)
    }
}

fun higher(left: u64, right: u64): u64 {
    if (right > left) { right } else { left }
}

/// Restores spendable cash to `owed` after an exit pays a trader.
/// Removing a hedge can pay cash out while the worst claim stays put.
fun cover_owed<T>(market: &mut IndexMarket<T>, vault: &mut Vault<T>) {
    let owed = max_claims(market);
    market.owed = owed;
    let have = spendable(market);
    if (owed > have) {
        let need = owed - have;
        assert!(vault.cash() >= need, ECash);
        market.cash.join(vault.split_cash(need));
    }
}

fun band_target(owed: u64, market_cap: u64, bps: u64): u64 {
    let from_owed = mul_div(owed, BPS + bps, BPS);
    let from_cap = mul_div(market_cap, bps, BPS);
    let target = if (from_owed > from_cap) { from_owed } else { from_cap };
    if (target > market_cap) { market_cap } else { target }
}

fun band_upper(owed: u64, bps: u64): u64 {
    mul_div(owed, BPS + 2 * bps, BPS)
}

fun mul_div(a: u64, b: u64, denominator: u64): u64 {
    (((a as u128) * (b as u128)) / (denominator as u128)) as u64
}
