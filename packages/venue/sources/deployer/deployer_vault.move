// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Holds a deployer's idle cash and the receipts that claim it.
/// The ex-fee share price is `nav / total_shares`.
/// `nav` is equity plus the live book gain, minus the live book loss.
/// Volume fees sit in `fee_index` and stay outside that price.
module venue::deployer_vault;

use account::{account::{Self, AccountWrapper}, account_registry::AccountRegistry};
use sui::{balance::{Self, Balance}, event};
use venue::{admin::AdminCap, deployer_registry::DeployerRegistry};

const EStopped: u64 = 0;
const EAmount: u64 = 1;
const EVaultCap: u64 = 2;
const EEmptyNav: u64 = 3;
const EZeroShares: u64 = 4;
const EReceipt: u64 = 5;
const EBoth: u64 = 6;

const SCALE: u64 = 1_000_000_000;
const BPS: u64 = 10_000;

public struct Vault<phantom T> has key {
    id: UID,
    deployer_id: ID,
    cash: Balance<T>,
    equity: u64,
    total_shares: u64,
    fee_index: u128,
    retained: u64,
    live_gain: u64,
    live_loss: u64,
}

public struct VaultDeposit<phantom T> has key {
    id: UID,
    vault_id: ID,
    shares: u64,
    mark: u64,
    fee_index: u128,
}

public struct Deposited has copy, drop {
    vault_id: ID,
    shares: u64,
    total_shares: u64,
    equity: u64,
    sender: address,
}

public struct Withdrawn has copy, drop {
    vault_id: ID,
    shares: u64,
    total_shares: u64,
    equity: u64,
    paid: u64,
    sender: address,
}

public struct BookAccounted has copy, drop {
    vault_id: ID,
    loss: u64,
    gain: u64,
    fee: u64,
    equity: u64,
    fee_index: u128,
    wallet_paid: u64,
    retained: u64,
}

/// Admits `admin` and shares that deployer's vault.
public fun admit<T>(
    registry: &mut DeployerRegistry,
    cap: &AdminCap,
    admin: address,
    type_ids: vector<ID>,
    enclave_ids: vector<ID>,
    vault_cap: u64,
    fee_public_key: vector<u8>,
    fee_recipient: address,
    wallet_fee_bps: u64,
    withdraw_share_bps: u64,
    deposit_fee_bps: u64,
    rebalance_bps: u64,
    market_cap_ceiling: Option<u64>,
    ctx: &mut TxContext,
): ID {
    let deployer_id = registry.admit(
        cap,
        admin,
        type_ids,
        enclave_ids,
        vault_cap,
        fee_public_key,
        fee_recipient,
        wallet_fee_bps,
        withdraw_share_bps,
        deposit_fee_bps,
        rebalance_bps,
        market_cap_ceiling,
        ctx,
    );
    let vault = Vault<T> {
        id: object::new(ctx),
        deployer_id,
        cash: balance::zero(),
        equity: 0,
        total_shares: 0,
        fee_index: 0,
        retained: 0,
        live_gain: 0,
        live_loss: 0,
    };
    let vault_id = object::id(&vault);
    registry.attach_vault(deployer_id, vault_id);
    transfer::share_object(vault);
    deployer_id
}

public fun deployer_id<T>(vault: &Vault<T>): ID { vault.deployer_id }

public fun equity<T>(vault: &Vault<T>): u64 { vault.equity }

/// Ex-fee value per the whole vault. Share price is this number divided by `total_shares`.
public fun nav<T>(vault: &Vault<T>): u64 {
    let up = vault.equity + vault.live_gain;
    if (up > vault.live_loss) { up - vault.live_loss } else { 0 }
}

public fun total_shares<T>(vault: &Vault<T>): u64 { vault.total_shares }

public fun fee_index<T>(vault: &Vault<T>): u128 { vault.fee_index }

public fun cash<T>(vault: &Vault<T>): u64 { vault.cash.value() }

public fun retained<T>(vault: &Vault<T>): u64 { vault.retained }

/// Pulls `amount` from the sender's account and mints a receipt to the sender.
public fun deposit<T>(
    vault: &mut Vault<T>,
    registry: &DeployerRegistry,
    _accounts: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    amount: u64,
    ctx: &mut TxContext,
) {
    assert!(!registry.stopped(vault.deployer_id), EStopped);
    assert!(amount > 0, EAmount);
    let fee = mul_div(amount, registry.deposit_fee_bps(vault.deployer_id), BPS);
    let net = amount - fee;
    assert!(net > 0, EAmount);
    assert!(vault.equity + net <= registry.vault_cap(vault.deployer_id), EVaultCap);
    let auth = account::generate_auth(ctx);
    let coin = wrapper.load_account_mut(auth).withdraw<T>(amount, ctx);
    vault.cash.join(coin.into_balance());
    if (fee > 0) {
        let fee_coin = vault.cash.split(fee).into_coin(ctx);
        transfer::public_transfer(fee_coin, registry.fee_recipient(vault.deployer_id));
    };
    let (shares, mark) = shares_for(vault, net);
    vault.equity = vault.equity + net;
    vault.total_shares = vault.total_shares + shares;
    let receipt = VaultDeposit<T> {
        id: object::new(ctx),
        vault_id: object::id(vault),
        shares,
        mark,
        fee_index: vault.fee_index,
    };
    transfer::transfer(receipt, ctx.sender());
    event::emit(Deposited {
        vault_id: object::id(vault),
        shares,
        total_shares: vault.total_shares,
        equity: vault.equity,
        sender: ctx.sender(),
    });
}

/// Returns the depositor payout and the performance-fee payout for this receipt.
public fun quote<T>(
    vault: &Vault<T>,
    registry: &DeployerRegistry,
    receipt: &VaultDeposit<T>,
): (u64, u64) {
    let (to_lp, to_wallet, _, _) = payout(
        vault,
        receipt,
        registry.withdraw_share_bps(vault.deployer_id),
    );
    (to_lp, to_wallet)
}

/// Burns the receipt. Pays the sender's account and sends the performance fee to the fee recipient.
public fun withdraw<T>(
    vault: &mut Vault<T>,
    registry: &DeployerRegistry,
    _accounts: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    receipt: VaultDeposit<T>,
    ctx: &mut TxContext,
) {
    let bps = registry.withdraw_share_bps(vault.deployer_id);
    let (to_lp, to_wallet, ex_fee, credit) = payout(vault, &receipt, bps);
    let VaultDeposit { id, shares, .. } = receipt;
    id.delete();
    vault.equity = vault.equity.saturating_sub(ex_fee);
    vault.total_shares = vault.total_shares - shares;
    vault.retained = vault.retained.saturating_sub(credit);
    if (to_wallet > 0) {
        let wallet = vault.cash.split(to_wallet).into_coin(ctx);
        transfer::public_transfer(wallet, registry.fee_recipient(vault.deployer_id));
    };
    if (to_lp > 0) {
        let auth = account::generate_auth(ctx);
        let coin = vault.cash.split(to_lp).into_coin(ctx);
        wrapper.load_account_mut(auth).deposit(coin);
    };
    event::emit(Withdrawn {
        vault_id: object::id(vault),
        shares,
        total_shares: vault.total_shares,
        equity: vault.equity,
        paid: to_lp,
        sender: ctx.sender(),
    });
}

/// Applies a book result. A loss is paid from `fee` first. The remainder of the fee splits.
/// A gain is added to ex-fee equity, and the whole fee splits.
public(package) fun account_result<T>(
    vault: &mut Vault<T>,
    registry: &DeployerRegistry,
    loss: u64,
    gain: u64,
    wallet_fee_bps: u64,
    gain_cash: Balance<T>,
    fee: Balance<T>,
    ctx: &mut TxContext,
) {
    assert!(loss == 0 || gain == 0, EBoth);
    let fee_value = fee.value();
    if (loss == 0 && gain == 0 && fee_value == 0 && gain_cash.value() == 0) {
        gain_cash.destroy_zero();
        fee.destroy_zero();
        return
    };
    vault.cash.join(gain_cash);
    vault.cash.join(fee);
    let rest = if (loss > 0) {
        let covered = if (fee_value < loss) { fee_value } else { loss };
        vault.equity = vault.equity.saturating_sub(loss - covered);
        fee_value - covered
    } else {
        vault.equity = vault.equity + gain;
        fee_value
    };
    let wallet_paid = mul_div(rest, wallet_fee_bps, BPS);
    let kept = rest - wallet_paid;
    if (wallet_paid > 0) {
        let coin = vault.cash.split(wallet_paid).into_coin(ctx);
        transfer::public_transfer(coin, registry.fee_recipient(vault.deployer_id));
    };
    if (vault.total_shares == 0) {
        vault.equity = vault.equity + kept;
    } else if (kept > 0) {
        vault.fee_index = vault.fee_index + (kept as u128) * (SCALE as u128) / (vault.total_shares as u128);
        vault.retained = vault.retained + kept;
    };
    event::emit(BookAccounted {
        vault_id: object::id(vault),
        loss,
        gain,
        fee: fee_value,
        equity: vault.equity,
        fee_index: vault.fee_index,
        wallet_paid,
        retained: kept,
    });
}

public(package) fun split_cash<T>(vault: &mut Vault<T>, amount: u64): Balance<T> {
    vault.cash.split(amount)
}

public(package) fun join_cash<T>(vault: &mut Vault<T>, cash: Balance<T>) {
    vault.cash.join(cash);
}

/// Replaces one market's live mark. Cash does not move.
public(package) fun replace_live<T>(
    vault: &mut Vault<T>,
    old_gain: u64,
    old_loss: u64,
    new_gain: u64,
    new_loss: u64,
) {
    vault.live_gain = vault.live_gain - old_gain + new_gain;
    vault.live_loss = vault.live_loss - old_loss + new_loss;
}

/// Books a realized option result into equity. The fee split stays on `account_result`.
public(package) fun realize<T>(vault: &mut Vault<T>, loss: u64, gain: u64) {
    assert!(loss == 0 || gain == 0, EBoth);
    if (loss > 0) {
        vault.equity = vault.equity.saturating_sub(loss);
    } else {
        vault.equity = vault.equity + gain;
    }
}

fun shares_for<T>(vault: &Vault<T>, net: u64): (u64, u64) {
    if (vault.total_shares == 0) {
        assert!(vault.equity == 0, EEmptyNav);
        (net, SCALE)
    } else {
        let value = nav(vault);
        assert!(value > 0, EEmptyNav);
        let mark = mul_div(value, SCALE, vault.total_shares);
        let shares = mul_div(net, vault.total_shares, value);
        assert!(shares > 0, EZeroShares);
        (shares, mark)
    }
}

fun payout<T>(
    vault: &Vault<T>,
    receipt: &VaultDeposit<T>,
    withdraw_share_bps: u64,
): (u64, u64, u64, u64) {
    assert!(receipt.vault_id == object::id(vault), EReceipt);
    assert!(vault.total_shares > 0, EEmptyNav);
    let ex_fee = mul_div(receipt.shares, nav(vault), vault.total_shares);
    let mark_value = mul_div(receipt.shares, receipt.mark, SCALE);
    let above = ex_fee.saturating_sub(mark_value);
    let to_wallet = mul_div(above, withdraw_share_bps, BPS);
    let credit = ((receipt.shares as u128) * (vault.fee_index - receipt.fee_index) / (SCALE as u128)) as u64;
    (ex_fee - to_wallet + credit, to_wallet, ex_fee, credit)
}

fun mul_div(a: u64, b: u64, denominator: u64): u64 {
    (((a as u128) * (b as u128)) / (denominator as u128)) as u64
}
