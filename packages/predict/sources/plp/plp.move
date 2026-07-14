// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PLP token and pool vault.
///
/// PoolVault owns the PLP treasury cap, the pooled DEEP staked by accounts, idle
/// DUSDC, the protocol reserve, sponsor-funded fee incentives, per-expiry cash
/// accounting, and the async LP supply/withdraw queues. It coordinates per-market
/// NAV refreshes (`refresh_expiry_nav` walks one market's payout tree and stores a
/// valuation mark on it), the full-pool flush (a hot-potato completeness proof
/// that reads every active market's stored mark without walking any tree), and
/// the unified per-market cash flow (initial funding, live rebalance/sweep, and
/// settled-market sweep with terminal profit materialization). LPs queue
/// supply/withdraw requests routed through a loaded Account; the flush
/// (`finish_flush`) drains them at the frozen pool NAV, minting/burning PLP and
/// delivering fills to each account via the balance accumulator. PLP incentives
/// moved to a separate staking contract; DEEP staking is an unrelated trading
/// feature.
module deepbook_predict::plp;

use account::{account::{Account, AccountWrapper, Auth}, account_registry::AccountRegistry};
use deepbook_predict::{
    admin::AdminCap,
    constants,
    expiry_market::ExpiryMarket,
    lp_book::{Self, LpBook},
    market_lifecycle_cap::MarketLifecycleProof,
    pool_accounting::{Self, Ledger},
    predict_account,
    pricing::Pricer,
    protocol_config::ProtocolConfig,
    vault_events
};
use dusdc::dusdc::DUSDC;
use fixed_math::math;
use propbook::{pyth_feed::PythFeed, registry::OracleRegistry};
use sui::{
    accumulator::AccumulatorRoot,
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::{Self, MetadataCap}
};
use token::deep::DEEP;

const EExpiryMarketNotActive: u64 = 0;
const EExpiryMarketAlreadyValued: u64 = 1;
const EWrongPoolVault: u64 = 2;
const EMissingExpiryValuation: u64 = 3;
const ENotBootstrapped: u64 = 4;
const EAlreadyBootstrapped: u64 = 5;
const EBelowMinBootstrapLiquidity: u64 = 6;
const EBelowMinFeeIncentiveSponsorship: u64 = 7;
const EMarketNotSettled: u64 = 8;
const EMaxLiveExpiryMarketsExceeded: u64 = 9;
const EValuationMarkStale: u64 = 10;
const ECashMovedDuringValuation: u64 = 11;

/// One-time witness type for Predict LP token registration.
public struct PLP has drop {}

/// Pool-level vault state.
public struct PoolVault has key {
    id: UID,
    /// Protocol-owned DUSDC (the materialized terminal-profit cut) excluded from
    /// PLP redemption.
    protocol_reserve_balance: Balance<DUSDC>,
    /// Sponsor-funded DUSDC reserved for taker fee sponsorship, excluded from PLP NAV.
    fee_incentive_reserve: Balance<DUSDC>,
    /// Pooled DEEP staked by all accounts for trading benefits. Per-account
    /// active/inactive amounts are mirrored in Predict account data.
    staked_deep: Balance<DEEP>,
    /// PLP share issuance plus queued supply/withdraw escrow.
    lp: LpBook<PLP>,
    /// Idle DUSDC custody, registered expiries, and per-expiry cash-flow rows.
    expiry_accounting: Ledger,
}

/// Transaction-local full-pool flush completeness proof.
///
/// `start_pool_valuation` snapshots the active expiry set; each `collect_expiry_nav`
/// folds one market's stored valuation mark into `total_nav` exactly once, reading
/// the market read-only (the payout-tree walk ran in that market's
/// `refresh_expiry_nav`, so the flush loads no per-order objects and stays under
/// the per-transaction object budget); `finish_flush` proves every snapshotted
/// market was counted, returns the LP-attributable pool NAV, and drains the LP
/// queues against it. Has no abilities, so it must be consumed by the finisher.
public struct PoolValuation {
    pool_vault_id: ID,
    /// Active expiry markets snapshotted at start; every one must be counted.
    expected_expiry_markets: vector<ID>,
    /// Markets counted so far this flow; folded against `expected` at finish.
    valued_expiry_markets: vector<ID>,
    /// Running Σ of each counted market's live free cash. Kept separate from the
    /// liability sum (raw atoms, no per-market netting or floor) so underwater
    /// markets net against the whole pool and the single zero floor is applied
    /// once, in `lp_pool_value`.
    total_free_cash: u64,
    /// Running Σ of each counted market's marked liability.
    total_liability: u64,
    /// Running Σ of each counted market's measured worst-case drift, in DUSDC —
    /// the dollar amount pool NAV could be off by from marks aging against
    /// moving feeds. Becomes the flush mark's half-spread at `finish_flush`:
    /// supplies price at the mid NAV plus it, withdrawals at the mid minus it.
    total_drift: u64,
    /// The vault ledger's cash revision at `start_pool_valuation`. `finish_flush`
    /// asserts it unchanged: the potato reads each market's cash at its collect
    /// and idle at finish, so an internal cash move interleaved between those
    /// reads (only the flush PTB's own commands can do this — PTBs are atomic)
    /// would double- or under-count the moved amount in the priced NAV.
    cash_revision: u64,
}

// === Package Initializer ===

/// Register PLP metadata and create the pool vault on package publish.
fun init(witness: PLP, ctx: &mut TxContext) {
    let (_, metadata_cap) = init_plp(witness, ctx);
    transfer_metadata_cap(metadata_cap, ctx);
}

fun init_plp(witness: PLP, ctx: &mut TxContext): (ID, MetadataCap<PLP>) {
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        witness,
        6,
        b"PLP".to_string(),
        b"Predict LP".to_string(),
        b"LP token representing shares in the Predict pool vault".to_string(),
        b"".to_string(),
        ctx,
    );
    let metadata_cap = initializer.finalize(ctx);
    let vault_id = create_and_share_vault(treasury_cap, ctx);
    (vault_id, metadata_cap)
}

#[allow(lint(self_transfer))]
fun transfer_metadata_cap(metadata_cap: MetadataCap<PLP>, ctx: &TxContext) {
    transfer::public_transfer(metadata_cap, ctx.sender());
}

fun create_and_share_vault(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): ID {
    let vault = PoolVault {
        id: object::new(ctx),
        protocol_reserve_balance: balance::zero(),
        fee_incentive_reserve: balance::zero(),
        staked_deep: balance::zero(),
        lp: lp_book::new(treasury_cap, ctx),
        expiry_accounting: pool_accounting::new(ctx),
    };
    let vault_id = vault.id();
    transfer::share_object(vault);
    vault_id
}

// === Public Functions ===

/// Return the pool vault object ID.
public fun id(vault: &PoolVault): ID {
    vault.id.to_inner()
}

/// Return DEEP staked by accounts and held in custody by the pool.
public fun staked_deep(vault: &PoolVault): u64 {
    vault.staked_deep.value()
}

/// Return idle DUSDC held by the pool (available for funding and withdrawals).
public fun idle_balance(vault: &PoolVault): u64 {
    vault.expiry_accounting.idle_balance()
}

/// Return protocol-owned DUSDC excluded from PLP redemption.
public fun protocol_reserve_balance(vault: &PoolVault): u64 {
    vault.protocol_reserve_balance.value()
}

/// Return sponsor-funded DUSDC available for future fee-incentive allocation.
public fun fee_incentive_reserve(vault: &PoolVault): u64 {
    vault.fee_incentive_reserve.value()
}

/// Return the total PLP share supply outstanding.
public fun plp_total_supply(vault: &PoolVault): u64 {
    vault.lp.total_supply()
}

/// Return the count of pending (un-drained) LP supply requests.
public fun supply_requests_pending(vault: &PoolVault): u64 {
    vault.lp.supply_requests_pending()
}

/// Return the count of pending (un-drained) LP withdraw requests.
public fun withdraw_requests_pending(vault: &PoolVault): u64 {
    vault.lp.withdraw_requests_pending()
}

/// Return the expiry markets still contributing active pool valuation/risk.
public fun active_expiry_markets(vault: &PoolVault): vector<ID> {
    vault.expiry_accounting.active_expiry_markets()
}

/// Return the count of active pre-expiry markets that require live NAV valuation.
public fun active_live_expiry_count(vault: &PoolVault, clock: &Clock): u64 {
    vault.expiry_accounting.active_live_expiry_count(clock.timestamp_ms())
}

/// Return the pricing debit side of the aggregate expiry profit basis.
public fun profit_basis_debits(vault: &PoolVault): u64 {
    vault.expiry_accounting.profit_basis_debits()
}

/// Return the pricing credit side of the aggregate expiry profit basis.
public fun profit_basis_credits(vault: &PoolVault): u64 {
    vault.expiry_accounting.profit_basis_credits()
}

/// Return the materialized protocol cut still awaiting a physical move to the reserve.
public fun pending_protocol_profit(vault: &PoolVault): u64 {
    vault.expiry_accounting.pending_protocol_profit()
}

/// Refresh one live market's stored valuation mark as a market deployer, using a
/// registry-generated `MarketLifecycleProof` and a `Pricer` loaded in this
/// transaction (`expiry_market::load_live_pricer`, like every priced flow). The
/// market is rebalanced to target, its exact per-order liability recomputed at
/// the pricer's oracle inputs, and the mark stored for `collect_expiry_nav` to
/// read. Several markets may be refreshed in one PTB subject to the
/// per-transaction object budget (each refresh walks its market's payout tree).
///
/// Live-markets-only by construction: a `Pricer` cannot outlive its transaction
/// and `load_live_pricer` rejects past-expiry markets, so holding one proves the
/// market is pre-expiry here — no settle branch needed. Terminal markets are
/// settled and swept out of the active set by `rebalance_expiry_cash`.
///
/// PRIVILEGED like the flush start (audit L8): the mark's refresh instant prices
/// the pool NAV the queues later drain at, and Pyth updates are permissionless —
/// so refresh authority carries the same oracle-timing trust as the flush itself.
public fun refresh_expiry_nav(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    lifecycle_proof: MarketLifecycleProof,
    config: &ProtocolConfig,
    pricer: &Pricer,
    clock: &Clock,
) {
    config.assert_version();
    lifecycle_proof.destroy_proof();
    let expiry_market_id = market.id();
    vault.expiry_accounting.assert_registered_expiry(expiry_market_id);
    vault.rebalance_live_expiry(market, expiry_market_id);
    let liability = market.record_valuation_mark(pricer, clock);
    vault_events::emit_nav_refreshed(
        vault.id(),
        expiry_market_id,
        liability,
        clock.timestamp_ms(),
    );
}

/// Begin a full-pool flush (stored-mark aggregation + LP queue drain) as a market
/// deployer, using a registry-generated `MarketLifecycleProof`. This is the sole
/// flush start: it is cron-driven and PRIVILEGED, not permissionless (audit L8).
/// Snapshots the active expiry set every `collect_expiry_nav` must cover; the hot
/// potato can only be created here, so gating the start gates the whole flush.
///
/// The flush prices the pool NAV off marks refreshed at operator-chosen instants
/// and `finish_flush` drains the LP queues at that mark, and Pyth updates
/// (`pyth_feed::update`) are permissionless — so a cap-holder who manipulates the
/// live oracle before refreshing, then flushes, could fill their own queued
/// supply/withdraw request at a mark they chose. The start is therefore gated on
/// both current registry allowlisting and trust in every flush-capable holder not
/// to manipulate the live oracle. The revocable `MarketLifecycleCap` (not the root
/// `AdminCap`) carries this authority; admin retains a break-glass route by
/// minting itself a lifecycle cap.
public fun start_pool_valuation(
    config: &ProtocolConfig,
    vault: &PoolVault,
    lifecycle_proof: MarketLifecycleProof,
): PoolValuation {
    config.assert_version();
    lifecycle_proof.destroy_proof();
    assert!(vault.lp.total_supply() > 0, ENotBootstrapped);
    PoolValuation {
        pool_vault_id: vault.id(),
        expected_expiry_markets: vault.expiry_accounting.active_expiry_markets(),
        valued_expiry_markets: vector[],
        total_free_cash: 0,
        total_liability: 0,
        total_drift: 0,
        cash_revision: vault.expiry_accounting.cash_revision(),
    }
}

/// Fold one snapshotted market's flush facts into the running pool aggregates,
/// using a `Pricer` loaded in this transaction (the live oracle inputs its
/// drift is measured against). The market must be in the snapshot and not
/// already counted (the exactly-once proof), and is a READ-ONLY input: no cash
/// moves, no settlement, no tree walk. Three facts are collected — live free
/// cash, the stored marked liability, and the mark's measured dollar drift —
/// and only one gate applies here: the mark must be younger than the freshness
/// ceiling (the sole guard a stalled feed cannot fool). Drift is never
/// rejected — `finish_flush` prices the aggregate as the flush mark's bid/ask
/// half-spread, borne by the transacting party.
///
/// A settled or past-expiry market cannot produce the pricer this read requires
/// (`load_live_pricer` rejects past-expiry): sweep it via `rebalance_expiry_cash`
/// so it leaves the active set, then start a new flush. There is still no
/// solvency-safe substitute mark for an unsettled expired market; the abort
/// clears once anyone lands the exact spot.
public fun collect_expiry_nav(
    valuation: &mut PoolValuation,
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    pricer: &Pricer,
    clock: &Clock,
) {
    config.assert_version();
    let expiry_market_id = market.id();
    valuation.assert_expiry_ready_to_value(expiry_market_id);
    assert!(
        clock.timestamp_ms() - market.mark_computed_at_ms()
            <= config.valuation_config().nav_mark_freshness_ms(),
        EValuationMarkStale,
    );
    valuation.valued_expiry_markets.push_back(expiry_market_id);
    valuation.total_free_cash = valuation.total_free_cash + market.free_cash();
    valuation.total_liability = valuation.total_liability + market.marked_liability();
    valuation.total_drift = valuation.total_drift + market.mark_drift(pricer);
}

/// Finish a full-pool valuation and run the LP flush: prove every snapshotted market
/// was counted exactly once, price the pool NAV, then drain the supply/withdraw queues
/// at that frozen mark (mint PLP for supplies, burn PLP and pay DUSDC for
/// withdrawals), consume the potato, and return the LP-attributable pool-wide DUSDC
/// NAV (idle + Σ active NAV, net of the pending-protocol-profit exclusion priced
/// from the aggregate profit basis).
///
/// `supply_budget` / `withdraw_budget` bound how many requests each queue may
/// process this flush (`None` = unbounded). Filled heads, protocol-refunded
/// non-executable heads, and live limit misses count as processed; a live limit
/// miss remains queued and stops that queue for the flush. A withdrawal whose
/// quote is valid but exceeds idle carries without spending budget. The operator
/// sizes the budgets to the gas left after valuing the snapshotted markets. The
/// budgets are independent, so a supply backlog never starves withdrawals.
public fun finish_flush(
    valuation: PoolValuation,
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    supply_budget: Option<u64>,
    withdraw_budget: Option<u64>,
    ctx: &mut TxContext,
): u64 {
    config.assert_version();
    valuation.assert_pool_vault(vault);
    assert_all_expected_valued(
        &valuation.expected_expiry_markets,
        &valuation.valued_expiry_markets,
    );
    assert!(
        vault.expiry_accounting.cash_revision() == valuation.cash_revision,
        ECashMovedDuringValuation,
    );
    let PoolValuation {
        total_free_cash,
        total_liability,
        total_drift,
        valued_expiry_markets,
        ..,
    } = valuation;

    let idle_balance_before = vault.expiry_accounting.idle_balance();
    let pool_nav = lp_pool_value(
        vault,
        config.protocol_reserve_profit_share(),
        total_free_cash,
        total_liability,
    );
    let total_supply = vault.lp.total_supply();
    let market_count = valued_expiry_markets.length();

    // Price the two-sided mark: the counted marks' combined worst-case drift is
    // the half-spread — supplies price the pool at the mid plus it, withdrawals
    // at the mid minus it — so the true pool value provably sits between the
    // sides and the transacting party bears the marks' staleness. No drift
    // threshold: a wide spread self-resolves through each request's own
    // min-out limit (miss, carry, refund), and fully fresh marks collapse the
    // spread to an exact single mark.
    let vault_id = vault.id();
    let mark = lp_book::new_flush_mark(
        pool_nav + total_drift,
        pool_nav.saturating_sub(total_drift),
        total_supply,
    );
    let drain_summary = vault
        .lp
        .drain(
            &mut vault.expiry_accounting,
            mark,
            vault_id,
            supply_budget,
            withdraw_budget,
            ctx,
        );
    vault_events::emit_flush_executed(
        vault_id,
        ctx.epoch(),
        pool_nav,
        total_supply,
        total_free_cash,
        total_liability,
        total_drift,
        market_count,
        idle_balance_before,
        drain_summary.supplies_filled(),
        drain_summary.withdrawals_filled(),
        drain_summary.requests_processed(),
        vault.expiry_accounting.idle_balance(),
    );
    pool_nav
}

/// Stake DEEP for trading benefits. The DEEP is held in the pool vault; the
/// amount is recorded as inactive on the account and activates next epoch
/// (`predict_account::roll_active_stake`, run by trade/claim flows). Callable
/// anytime, any number of times.
public fun stake_deep(
    vault: &mut PoolVault,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    amount: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_version();
    wrapper.settle<DEEP>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let deep = account.withdraw<DEEP>(amount, ctx);
    predict_account::roll_active_stake(account, ctx);
    predict_account::add_inactive_stake(account, amount, ctx);
    vault.staked_deep.join(deep.into_balance());
    vault_events::emit_deep_staked(
        vault.id(),
        account.account_id(),
        amount,
        predict_account::active_stake(account),
        predict_account::inactive_stake(account),
    );
}

/// Withdraw all staked DEEP (active and inactive) at any time, no penalty.
public fun unstake_deep(
    vault: &mut PoolVault,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_version();
    wrapper.settle<DEEP>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let amount = predict_account::remove_all_stake(account, ctx);
    if (amount > 0) {
        let deep = vault.staked_deep.split(amount).into_coin(ctx);
        account.deposit<DEEP>(deep);
    };
    vault_events::emit_deep_unstaked(vault.id(), account.account_id(), amount);
}

/// Move cash between pool idle liquidity and one expiry market.
///
/// Permissionless and standalone: anyone may call it at any cadence. Handles all
/// three per-market cases — initial funding of a freshly registered (unfunded)
/// market, ongoing live rebalance/surplus-sweep toward target, and the
/// settled-market sweep (deactivate, return all free cash, materialize profit).
/// Mint asserts backing but never pulls pool cash, so this is what makes a market
/// mintable. The market must already be registered to this vault
/// (`registry::create_and_share_expiry_market`). Cash moves need no valuation-mark
/// maintenance: the flush reads free cash live.
public fun rebalance_expiry_cash(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    clock: &Clock,
) {
    config.assert_version();
    let expiry_market_id = market.id();
    vault.expiry_accounting.assert_registered_expiry(expiry_market_id);
    vault.settle_or_rebalance_expiry(market, config, propbook_registry, pyth, clock);
}

/// Resolve the caller-owned account's settled trading-loss rebate.
public fun claim_trading_loss_rebate(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_version();
    wrapper.settle<DUSDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    vault.claim_trading_loss_rebate_internal(
        market,
        account,
        config,
        propbook_registry,
        pyth,
        clock,
        ctx,
    );
}

/// Permissionlessly resolve one account's settled trading-loss rebate using Predict
/// app auth. `deauthorize_app<PredictApp>` disables this automation; owners can
/// still use `claim_trading_loss_rebate` with owner auth.
public fun claim_trading_loss_rebate_permissionless(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    wrapper: &mut AccountWrapper,
    account_registry: &AccountRegistry,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_version();
    wrapper.settle<DUSDC>(root, clock);
    let auth = predict_account::generate_auth_as_app(account_registry);
    let account = wrapper.load_account_mut(auth);
    vault.claim_trading_loss_rebate_internal(
        market,
        account,
        config,
        propbook_registry,
        pyth,
        clock,
        ctx,
    );
}

/// Sponsor taker fee incentives with DUSDC. Anyone may contribute; the payment
/// joins a pool-level reserve that is excluded from PLP NAV and later allocated to
/// expiry markets by the normal rebalance flow.
public fun sponsor_fee_incentives(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    payment: Coin<DUSDC>,
    ctx: &TxContext,
) {
    config.assert_version();
    let amount = payment.value();
    assert!(
        amount >= constants::min_fee_incentive_sponsorship!(),
        EBelowMinFeeIncentiveSponsorship,
    );
    vault.fee_incentive_reserve.join(payment.into_balance());
    vault_events::emit_fee_incentives_sponsored(
        vault.id(),
        ctx.sender(),
        amount,
        vault.fee_incentive_reserve.value(),
    );
}

/// Bootstrap the pool exactly once: permanently lock `payment` DUSDC of minimum
/// liquidity. Mints matching PLP (1:1) into the book's locked balance — never
/// withdrawable, so the caller receives no shares — and joins the DUSDC into idle.
/// This keeps `total_supply > 0` for the life of the pool, making the supply==0
/// bootstrap branch unreachable and the residual-idle re-bootstrap brick impossible.
/// Callable only by the operator and only while the pool is pristine
/// (`total_supply == 0`), so it runs exactly once; all supply/withdraw/flush flows
/// abort `ENotBootstrapped` until it has.
public fun lock_capital(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    _admin_cap: &AdminCap,
    payment: Coin<DUSDC>,
) {
    config.assert_version();
    assert!(vault.lp.total_supply() == 0, EAlreadyBootstrapped);
    let amount = payment.value();
    assert!(amount >= constants::min_bootstrap_liquidity!(), EBelowMinBootstrapLiquidity);
    vault.expiry_accounting.receive_idle(payment.into_balance());
    vault.lp.mint_locked_liquidity(amount);
    vault_events::emit_capital_locked(vault.id(), amount);
}

/// Queue a supply request: pull `amount` DUSDC from account custody into queue
/// escrow, recording the account's receive address as the fill recipient. The pull
/// auto-settles any flush-delivered DUSDC first. The account receives minted PLP
/// only if a future flush can mint at least `min_plp_out`; after three limit misses
/// the request is cancelled and refunded. Returns the queue index, the handle used
/// to cancel before the flush.
public fun request_supply(
    vault: &mut PoolVault,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    amount: u64,
    min_plp_out: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    config.assert_version();
    assert!(vault.lp.total_supply() > 0, ENotBootstrapped);
    wrapper.settle<DUSDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let payment = account.withdraw<DUSDC>(amount, ctx);
    let vault_id = vault.id();
    let account_id = account.account_id();
    let recipient = account.receive_address();
    let index = vault.lp.request_supply(payment, account_id, recipient, min_plp_out);
    vault_events::emit_supply_requested(
        vault_id,
        account_id,
        recipient,
        index,
        amount,
        min_plp_out,
    );
    index
}

/// Queue a withdraw request: pull `amount` PLP shares from account custody into
/// queue escrow, recording the account's receive address as the fill recipient.
/// The pull auto-settles any flush-delivered PLP first. The request fills only if a
/// future flush can pay at least `min_dusdc_out`; after three limit misses the
/// request is cancelled and refunded. Returns the queue index used to cancel before
/// the flush.
public fun request_withdraw(
    vault: &mut PoolVault,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    amount: u64,
    min_dusdc_out: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    config.assert_version();
    assert!(vault.lp.total_supply() > 0, ENotBootstrapped);
    wrapper.settle<PLP>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let lp = account.withdraw<PLP>(amount, ctx);
    let vault_id = vault.id();
    let account_id = account.account_id();
    let recipient = account.receive_address();
    let index = vault.lp.request_withdraw(lp, account_id, recipient, min_dusdc_out);
    vault_events::emit_withdraw_requested(
        vault_id,
        account_id,
        recipient,
        index,
        amount,
        min_dusdc_out,
    );
    index
}

/// Cancel a still-pending supply request, refunding its escrowed DUSDC straight into
/// the requesting account. `account` must be the request's recorded recipient.
public fun cancel_supply_request(
    vault: &mut PoolVault,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    index: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_version();
    let vault_id = vault.id();
    wrapper.settle<DUSDC>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let recipient = account.receive_address();
    let (account_id, amount, refund) = vault.lp.cancel_supply_request(recipient, index);
    account.deposit<DUSDC>(refund.into_coin(ctx));
    vault_events::emit_request_cancelled(
        vault_id,
        account_id,
        recipient,
        index,
        amount,
        true,
        constants::request_cancel_reason_user!(),
    );
}

/// Cancel a still-pending withdraw request, refunding its escrowed PLP straight into
/// the requesting account. `account` must be the request's recorded recipient.
public fun cancel_withdraw_request(
    vault: &mut PoolVault,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    config: &ProtocolConfig,
    index: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    config.assert_version();
    let vault_id = vault.id();
    wrapper.settle<PLP>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let recipient = account.receive_address();
    let (account_id, amount, refund) = vault.lp.cancel_withdraw_request(recipient, index);
    account.deposit<PLP>(refund.into_coin(ctx));
    vault_events::emit_request_cancelled(
        vault_id,
        account_id,
        recipient,
        index,
        amount,
        false,
        constants::request_cancel_reason_user!(),
    );
}

/// Register a freshly created expiry market with the pool as an accounting row.
/// No cash moves: the market is not mintable until `rebalance_expiry_cash` funds
/// it. Called by `registry::create_and_share_expiry_market`.
public(package) fun register_expiry(
    vault: &mut PoolVault,
    expiry_market_id: ID,
    expiry_ms: u64,
    max_expiry_allocation: u64,
    initial_expiry_cash: u64,
    clock: &Clock,
) {
    let now_ms = clock.timestamp_ms();
    if (expiry_ms > now_ms) {
        assert!(
            vault
                .expiry_accounting
                .active_live_expiry_count(now_ms) < constants::max_live_expiry_markets!(),
            EMaxLiveExpiryMarketsExceeded,
        );
    };
    vault
        .expiry_accounting
        .register_expiry(expiry_market_id, expiry_ms, max_expiry_allocation, initial_expiry_cash);
}

// === Private Functions ===

fun claim_trading_loss_rebate_internal(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    account: &mut Account,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let vault_id = vault.id();
    let expiry_market_id = market.id();
    vault.expiry_accounting.assert_registered_expiry(expiry_market_id);
    assert!(market.ensure_settled(propbook_registry, pyth, clock), EMarketNotSettled);
    let settlement_price = market.settlement_price();
    let account_id = account.account_id();
    let (residual_cash, rebate_amount) = market.claim_trading_loss_rebate(account, config, ctx);
    let residual_returned = residual_cash.value();
    let returned_cash_amount = vault
        .expiry_accounting
        .receive_expiry_cash(residual_cash, expiry_market_id);
    if (returned_cash_amount > 0) {
        vault_events::emit_expiry_cash_received(
            vault_id,
            expiry_market_id,
            settlement_price,
            returned_cash_amount,
        );
        vault.materialize_expiry_profit(config, expiry_market_id);
    };
    vault_events::emit_trading_loss_rebate_claimed(
        vault_id,
        expiry_market_id,
        account_id,
        rebate_amount,
        residual_returned,
    );
}

/// LP-attributable DUSDC pool value used to price PLP supply/withdraw.
///
/// Assets and liabilities arrive as raw per-market sums (no per-market netting or
/// floor — see `FlushAtoms`): `gross = idle_balance + Σ free_cash`, owing
/// `Σ liability`. NAV prices the protocol's not-yet-materialized profit share
/// before terminal materialization and excludes it from LP value:
/// `exclusion = share * max(0, (credits + Σ free_cash) - (debits + Σ liability))`
/// (live cash returns update credits, but reserve custody waits for terminal
/// profit). A cut already materialized but not yet physically moved (idle was
/// deployed elsewhere) has left that debit-basis exclusion, so the carried
/// `pending_protocol_profit` is subtracted separately to keep it out of LP value
/// until it is drained into the reserve.
fun lp_pool_value(
    vault: &PoolVault,
    protocol_reserve_profit_share: u64,
    total_free_cash: u64,
    total_liability: u64,
): u64 {
    let idle_balance = vault.expiry_accounting.idle_balance();
    let profit_basis_credits = vault.expiry_accounting.profit_basis_credits();
    let profit_basis_debits = vault.expiry_accounting.profit_basis_debits();
    let pending_protocol_profit = vault.expiry_accounting.pending_protocol_profit();
    let gross_pool_value = idle_balance + total_free_cash;
    let aggregate_credits = profit_basis_credits + total_free_cash;
    let aggregate_debits = profit_basis_debits + total_liability;
    let exclusion = math::mul(
        aggregate_credits.saturating_sub(aggregate_debits),
        protocol_reserve_profit_share,
    );
    // THE single policy floor for pool NAV — per-market values are deliberately
    // never floored (an underwater market at backing lambda < 1 is a legitimate
    // transient that must net against the rest of the pool). Two ways the
    // subtraction can exceed gross: an aggregate-underwater book, and the sticky
    // realized `credits - debits` term (it does not shrink when LPs withdraw idle
    // cash, so a later mark collapse can push the held-out total past gross). LP
    // value can never be negative, so floor at 0; a 0/dust pool NAV makes
    // non-executable LP queue heads refund inside `lp_book::drain`, rather than
    // aborting the flush.
    gross_pool_value.saturating_sub(total_liability + exclusion + pending_protocol_profit)
}

/// Shared settle-or-rebalance dispatch: passively settle the market off Propbook's
/// exact-expiry Pyth print if available and sweep it terminal, else rebalance its
/// live expiry cash. Returns true when the market is settled/swept.
fun settle_or_rebalance_expiry(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    clock: &Clock,
): bool {
    let expiry_market_id = market.id();
    if (market.ensure_settled(propbook_registry, pyth, clock)) {
        vault.sweep_settled_expiry(market, config);
        true
    } else {
        vault.rebalance_live_expiry(market, expiry_market_id);
        false
    }
}

fun rebalance_live_expiry(vault: &mut PoolVault, market: &mut ExpiryMarket, expiry_market_id: ID) {
    vault.sync_fee_incentives(market, expiry_market_id);

    let initial_expiry_cash = vault.expiry_accounting.initial_expiry_cash(expiry_market_id);
    let (cash_balance, target_cash, sweep_threshold_cash) = expiry_rebalance_cash_terms(
        market,
        initial_expiry_cash,
    );
    if (cash_balance < target_cash) {
        vault.top_up_live_expiry_cash(market, expiry_market_id, cash_balance, target_cash);
    } else if (cash_balance > sweep_threshold_cash) {
        vault.sweep_live_expiry_surplus(market, expiry_market_id, cash_balance, target_cash);
    };
}

fun top_up_live_expiry_cash(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    expiry_market_id: ID,
    cash_balance: u64,
    target_cash: u64,
) {
    let requested_top_up = target_cash - cash_balance;
    let funding_room = vault.expiry_accounting.available_expiry_funding(expiry_market_id);
    let top_up = requested_top_up.min(vault.expiry_accounting.idle_balance()).min(funding_room);
    if (top_up == 0) return;

    let cash = vault.expiry_accounting.send_expiry_cash(expiry_market_id, top_up);
    market.receive_pool_cash(cash);
    vault_events::emit_expiry_cash_rebalanced(
        vault.id(),
        expiry_market_id,
        top_up,
        true,
        target_cash,
        0,
    );
}

fun sweep_live_expiry_surplus(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    expiry_market_id: ID,
    cash_balance: u64,
    target_cash: u64,
) {
    let returned_cash = market.release_pool_cash(cash_balance - target_cash);
    let returned_cash_amount = vault
        .expiry_accounting
        .receive_expiry_cash(returned_cash, expiry_market_id);
    // Surplus just returned to idle — realize any protocol cut a prior settled
    // sweep could not cover because idle was deployed in other active markets.
    let realized_profit = vault.expiry_accounting.realize_pending_protocol_profit();
    let protocol_profit_realized = realized_profit.value();
    vault.protocol_reserve_balance.join(realized_profit);
    vault_events::emit_expiry_cash_rebalanced(
        vault.id(),
        expiry_market_id,
        returned_cash_amount,
        false,
        target_cash,
        protocol_profit_realized,
    );
}

fun sync_fee_incentives(vault: &mut PoolVault, market: &mut ExpiryMarket, expiry_market_id: ID) {
    let max_expiry_allocation = vault.expiry_accounting.max_expiry_allocation(expiry_market_id);
    let requested_allocation = math::mul(
        max_expiry_allocation,
        constants::fee_incentive_live_target_rate!(),
    )
        .saturating_sub(market.fee_incentive_balance())
        .min(vault.fee_incentive_reserve.value());
    if (requested_allocation == 0) return;

    let (allocation, allocated_after) = vault
        .expiry_accounting
        .record_fee_incentives_allocated_up_to(
            expiry_market_id,
            math::mul(
                max_expiry_allocation,
                constants::fee_incentive_lifetime_cap_rate!(),
            ),
            requested_allocation,
        );
    if (allocation == 0) return;

    let incentives = vault.fee_incentive_reserve.split(allocation);
    market.receive_fee_incentives(incentives);
    vault_events::emit_fee_incentives_allocated(
        vault.id(),
        expiry_market_id,
        allocation,
        vault.fee_incentive_reserve.value(),
        market.fee_incentive_balance(),
        allocated_after,
    );
}

/// Current cash, the target cash to hold, and the upper sweep band for one expiry.
///
/// `target_cash` adds one buffer above the expiry-cash required backing and
/// `sweep_threshold_cash` adds two, both floored at the per-expiry initial cash
/// target. Below target the pool tops up to target; above the sweep band it
/// returns the excess over target.
fun expiry_rebalance_cash_terms(market: &ExpiryMarket, initial_expiry_cash: u64): (u64, u64, u64) {
    let required_cash = market.required_cash();
    let target_buffer = math::mul(required_cash, constants::expiry_rebalance_pct!());
    let target_cash = (required_cash + target_buffer).max(initial_expiry_cash);
    let sweep_threshold_cash = (required_cash + target_buffer + target_buffer).max(
        initial_expiry_cash,
    );
    (market.cash_balance(), target_cash, sweep_threshold_cash)
}

/// Settled-market sweep: deactivate the expiry, return its free cash to idle,
/// materialize its terminal profit, and return unused fee incentives to the pool
/// reserve. Idempotent — a settled market already swept returns zero cash and
/// recognizes no further profit, so a second pass is a no-op.
fun sweep_settled_expiry(
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
) {
    let expiry_market_id = market.id();
    let deactivated = vault.expiry_accounting.deactivate_expiry_if_present(expiry_market_id);
    let (returned_cash, settlement_price) = market.release_settled_pool_cash();
    let returned_cash_amount = vault
        .expiry_accounting
        .receive_expiry_cash(returned_cash, expiry_market_id);
    if (deactivated || returned_cash_amount > 0) {
        vault_events::emit_expiry_cash_received(
            vault.id(),
            expiry_market_id,
            settlement_price,
            returned_cash_amount,
        );
    };
    vault.materialize_expiry_profit(config, expiry_market_id);
    let returned_incentives = market.release_fee_incentives();
    let returned_incentive_amount = returned_incentives.value();
    vault.fee_incentive_reserve.join(returned_incentives);

    if (returned_incentive_amount > 0) {
        vault_events::emit_fee_incentives_returned(
            vault.id(),
            expiry_market_id,
            returned_incentive_amount,
            vault.fee_incentive_reserve.value(),
        );
    };
}

/// Materialize one terminal expiry's unapplied profit and split it: the protocol
/// cut is realized from idle into the protocol reserve — capped at available idle,
/// with any remainder carried in `pending_protocol_profit` and realized on a later
/// sweep — while the LP cut stays in idle.
fun materialize_expiry_profit(
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    expiry_market_id: ID,
) {
    let profit = vault.expiry_accounting.materialize_expiry_profit(expiry_market_id);
    if (profit == 0) {
        return
    };
    let protocol_profit = math::mul(profit, config.protocol_reserve_profit_share());
    let lp_profit = profit - protocol_profit;
    let realized = vault.expiry_accounting.realize_protocol_profit(protocol_profit);
    vault.protocol_reserve_balance.join(realized);
    vault_events::emit_expiry_profit_materialized(
        vault.id(),
        expiry_market_id,
        lp_profit,
        protocol_profit,
        vault.protocol_reserve_balance.value(),
        vault.expiry_accounting.profit_basis_debits(),
        vault.expiry_accounting.pending_protocol_profit(),
    );
}

/// Abort unless this valuation belongs to `vault`.
fun assert_pool_vault(valuation: &PoolValuation, vault: &PoolVault) {
    assert!(valuation.pool_vault_id == vault.id(), EWrongPoolVault);
}

/// Abort unless the market is in the snapshot and not already valued (exactly-once).
fun assert_expiry_ready_to_value(valuation: &PoolValuation, expiry_market_id: ID) {
    assert!(valuation.expected_expiry_markets.contains(&expiry_market_id), EExpiryMarketNotActive);
    assert!(
        !valuation.valued_expiry_markets.contains(&expiry_market_id),
        EExpiryMarketAlreadyValued,
    );
}

/// The exactly-once completeness proof: the counted set must equal the snapshot
/// (a missed market means a wrong pool NAV). `collect_expiry_nav` already rejects
/// non-snapshot and duplicate ids, so equal lengths plus full coverage suffice.
fun assert_all_expected_valued(expected: &vector<ID>, valued: &vector<ID>) {
    assert!(valued.length() == expected.length(), EMissingExpiryValuation);
    expected.do_ref!(|id| assert!(valued.contains(id), EMissingExpiryValuation));
}

// === Test-Only Functions ===

#[test_only]
/// Register PLP in tests.
public fun init_for_testing(ctx: &mut TxContext): ID {
    let (vault_id, metadata_cap) = init_plp(PLP {}, ctx);
    transfer_metadata_cap(metadata_cap, ctx);
    vault_id
}
