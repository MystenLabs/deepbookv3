# Sessions

`deepbook_sessions` lets the owner of a canonical DeepBook Account authorize an ephemeral address to submit a limited set of Predict and DeepBook spot transactions for that Account until a fixed expiration time. Predict orders go through Predict's order-flow companion, `deepbook_predict_orders`.

The package is an Account app. It stores session grants in the Account's app-local data and generates Account app authorization only inside its trading wrapper functions. Session callers never receive a reusable `account::Auth`, and the package exposes no direct Account withdrawal or arbitrary mutation entrypoint.

## Authority model

The Account registry administrator must authorize `SessionsApp` before any wrapper can generate app authorization. This registry-level authorization makes the package trusted Account infrastructure; it does not itself grant a session for any user.

An Account owner opts in by calling `authorize_session` on the Account's shared `AccountWrapper`. Owner authorization is derived from the transaction sender, so this flow supports EOA-owned Accounts and does not authorize object-owned Accounts.

A session grant contains only the session address and its expiration timestamp in milliseconds. Each Account may store at most 20 session addresses. The requested duration must be greater than zero and no more than 30 days. Expiration is calculated from the on-chain `Clock` at execution time, and reauthorizing the same address replaces its stored expiration without consuming another slot.

Every trading wrapper requires both of these conditions:

- The executing Sessions package version is at or above the shared `SessionsConfig.version_watermark`.
- The transaction sender has a stored session grant for the supplied Account.
- The current clock timestamp is strictly less than the stored expiration.

At the exact expiration timestamp, the session is no longer authorized.

## Session lifecycle

```move
public fun session_expiration_ms(
    wrapper: &AccountWrapper,
    session: address,
): Option<u64>

public fun authorize_session(
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    session: address,
    duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
)

public fun revoke_session(
    wrapper: &mut AccountWrapper,
    session: address,
    ctx: &mut TxContext,
)
```

`session_expiration_ms` returns the stored expiration for a known session and `none` for a session that was never authorized or has been revoked. It does not classify the timestamp as active or expired; callers that need that distinction must compare it with the current on-chain time.

The shared `AccountWrapper` can be supplied as an object input in a programmable transaction block and borrowed immutably for `session_expiration_ms`. SDKs may also use the function through dev-inspect reads.

Revoking a known session removes it from the session map immediately, whether it is active or already expired, and frees its slot for another address. Once the Sessions app-data slot has been attached to an Account, it remains attached even when the session map becomes empty. Revoking an unknown session is a no-op. Expired entries are not removed automatically because time passing does not execute Move code; they continue to count toward the 20-session limit until the owner revokes them, while reauthorization replaces the expiration in place.

Session reads and revocation remain available after a package version is retired so owners can inspect and remove grants without using a trading-capable package version.

## Version governance

Publishing Sessions creates a shared `SessionsConfig` at the package's compiled-in version and transfers a `SessionsAdminCap` to the publisher. `authorize_session` and every trading wrapper require the shared config and reject package versions below its watermark.

Each package upgrade must increment `current_version!()`. After clients have moved to the new package, the `SessionsAdminCap` holder calls that package's `bump_version_watermark`; the function derives the target from the executing package and only advances the watermark, so callers cannot select an arbitrary version or use an older package to retire a newer one.

Advancing the watermark retires authorization and trading entrypoints in older package versions. Account-level deauthorization of `SessionsApp` remains the lineage-wide emergency stop because it prevents every version of the app from generating Account authorization.

## Predict wrappers

An active session may call these wrappers, which place delayed-execution orders in a market's queue in the order-flow companion, `deepbook_predict_orders`:

- `enqueue_exact_quantity`
- `enqueue_exact_amount`
- `enqueue_exact_cost`
- `enqueue_redeem_open`
- the `_with_builder` version of each, for an order that names a Predict builder code and a fee per contract

Each calls the companion's `queue` function of the same name and returns the new record ID. Besides the market, the Account, and `ProtocolConfig`, each takes the market's `MarketQueue`, the companion's `OrderDesk`, Propbook's oracle registry, and the canonical Pyth and Block Scholes objects that Predict validates when it snapshots the order's pricing inputs. `enqueue_redeem_open` sells an Open record, a filled order that stays in its market's queue, by its record ID. Once placed, an order is committed, filled or refunded, and paid at settlement by calls that need no session or Account authority. See [delayed execution](../predict/docs/concepts/delayed-execution.md).

An active session may also call these wrappers:

- `mint_exact_quantity`
- `mint_exact_amount`
- `mint_exact_cost`
- `redeem_live`
- `redeem_settled`

The immediate `mint_exact_*` and `redeem_live` wrappers always abort through Predict, which retires those functions from package version 4. Predict package version 5 retires `redeem_settled` the same way, because settlement pays a queued fill's Open record and no fill enters the Account. The `redeem_settled` wrapper aborts once Sessions links that version. They keep their signatures so the upgrade stays compatible.

Each wrapper validates the package version and session against the supplied Account, generates app authorization internally, and immediately passes that authorization into the corresponding Predict or companion function. All market parameters remain caller-selected and are validated by the companion and Predict.

The queued wrappers were added by the Sessions upgrade that sets `current_version!()` to 3. That upgrade links Predict package version 4 and the companion, so it publishes after both. Sessions runs the Predict and companion versions it linked when it was published, so before Predict's version watermark retires the version it links, Sessions must be relinked to the new Predict. An unrelinked Sessions package's queued wrappers abort once Predict's watermark advances, while placing orders directly through the companion keeps working. `current_version!()` is now 4, the version the next Mainnet upgrade publishes, relinked to Predict 5 and Propbook 2.

## Builder approvals

A builder fee goes to the code the trade names, at the fee the trade names, and on a session-key trade the session holder builds the trade. So the Account owner approves the builder for each session:

```move
public fun approve_session_builder(
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    session: address,
    code_id: ID,
    max_fee_per_contract: u64,
    ctx: &mut TxContext,
)

public fun session_builder(wrapper: &AccountWrapper, session: address): Option<SessionBuilder>
```

`approve_session_builder` takes owner authorization from the transaction sender, like `authorize_session`, opens only once the `SessionsConfig` watermark reaches version 4 (`EBuilderApprovalsNotEnabled`), and works only for a session already authorized (`ESessionNotAuthorized`), so an app calls it right after `authorize_session` in the same transaction. It stores one builder code ID and a maximum fee per contract (in 1e9 scaling of a contract's $1 payout) for that session, and a later call replaces them. The approvals live in their own Account data slot, because `SessionsData` was published without them.

The four `_with_builder` wrappers run the session checks, then require the session to have an approval, the trade's code to be the approved code (`EBuilderNotApproved`), and the trade's fee to be at or below the approved maximum (`EBuilderFeeAboveApproved`). Predict then caps the fee at its own `builder_fee_cap`. A session trade that names no builder uses the plain wrappers and pays no builder fee.

`revoke_session` also removes the session's approval, so a session authorized again needs a new approval. Re-authorizing a session that was not revoked keeps its approval, including one that expired, because expiry does not remove a session. A new grant for an address that is not currently authorized clears any approval left on it, because the pre-upgrade `revoke_session` stays callable and removes a session without its approval. The pre-upgrade `authorize_session` would not clear it, which is why approvals wait for the watermark to retire that version. `session_builder` returns a session's approval, or `none`, for SDK and dev-inspect reads. It can still return an approval the pre-upgrade `revoke_session` left on a removed session. No trade can use that approval, and a new grant of the address or another `revoke_session` clears it. `approve_session_builder` emits `SessionBuilderApproved`, and every removal of an approval, by `revoke_session` or by a new grant, emits `SessionBuilderCleared`.

An approval caps the fee per contract, not the number of trades. A session holder that is also the approved builder can trade the account repeatedly and collect the fee on each trade, so owners should approve only a builder they trust, at the lowest fee they accept. This is the trust a session grant already carries.

## DeepBook spot wrappers

An active session may call these Account-backed DeepBook spot wrappers:

- `place_limit_order`
- `place_market_order`
- `cancel_live_order`
- `cancel_live_orders`
- `withdraw_settled_amounts`

Each wrapper validates the package version and session against the supplied Account, generates app authorization internally, and immediately passes it into the corresponding `deepbook_core_account` function. Order parameters remain caller-selected and are validated by the Account wrapper and DeepBook core. The permissionless settled-amount withdrawal is not duplicated here because it does not require session authority.

The session can therefore submit adverse Predict orders and spot trades, cancel the Account's spot orders, and sweep settled spot proceeds back into Account custody until it expires or is revoked. A grant should be treated as trading authority, not read-only access. Revocation and expiration stop future wrapper calls but do not unwind positions, orders, or transactions that already executed. A queued Predict order placed through a session still fills or refunds after the session ends.

## Events

`SessionAuthorized` is emitted for both a new grant and a reauthorization:

```move
public struct SessionAuthorized has copy, drop {
    account_id: ID,
    session: address,
    expires_at_ms: u64,
}
```

`SessionRevoked` is emitted only when an existing grant is removed:

```move
public struct SessionRevoked has copy, drop {
    account_id: ID,
    session: address,
    expires_at_ms: u64,
}
```

Expiration emits no event, and a no-op revocation emits no event. Predict and DeepBook core continue to emit their underlying trading events; the wrappers do not duplicate them.

## Integration requirements

Before Sessions can be used, the package must be published against the intended Account, Predict, `deepbook_predict_orders`, Propbook, DeepBook core, and `deepbook_core_account` package lineages. Integrations must discover the published shared `SessionsConfig` and supply it to session authorization and every trading wrapper. `SessionsApp` must be authorized in the corresponding Account registry, while `DeepbookCoreAccountApp` must be authorized in the supplied DeepBook registry for spot order placement. Publication, registry configuration, SDK transaction construction, ephemeral-key storage, indexing, and deployment are outside this package.

Custody of `SessionsAdminCap` and any package upgrade capability is part of the trust boundary: the admin cap can retire older package versions, while an upgrade can change the behavior of an authorized Account app.

## Build and test

From the repository root:

```sh
sui move build --path packages/sessions --warnings-are-errors
sui move test --path packages/sessions --gas-limit 100000000000 --package-size 64
```
