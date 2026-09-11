# Sessions

`deepbook_sessions` lets the owner of a canonical DeepBook Account authorize an ephemeral address to submit a limited set of Predict and DeepBook spot transactions for that Account until a fixed expiration time.

The package is an Account app. It stores session grants in the Account's app-local data and generates Account app authorization only inside its trading wrapper functions. Session callers never receive a reusable `account::Auth`, and the package exposes no direct Account withdrawal or arbitrary mutation entrypoint.

## Authority model

The Account registry administrator must authorize `SessionsApp` before any wrapper can generate app authorization. This registry-level authorization makes the package trusted Account infrastructure; it does not itself grant a session for any user.

An Account owner opts in by calling `authorize_session` on the Account's shared `AccountWrapper`. Owner authorization is derived from the transaction sender, so this flow supports EOA-owned Accounts and does not authorize object-owned Accounts.

A session grant contains the session address, its expiration timestamp in milliseconds, and the DeepBook pool IDs that session may trade. Each Account may store at most 20 session addresses, and each grant may list at most 20 pool IDs. Duplicate pool IDs abort. An empty pool list is valid and means the session cannot call any spot wrapper. The requested duration must be greater than zero and no more than 30 days. Expiration is calculated from the on-chain `Clock` at execution time, and reauthorizing the same address replaces its stored expiration and pool allowlist without consuming another slot.

Every trading wrapper requires both of these conditions:

- The executing Sessions package version is at or above the shared `SessionsConfig.version_watermark`.
- The transaction sender has a stored session grant for the supplied Account.
- The current clock timestamp is strictly less than the stored expiration.

DeepBook spot wrappers also require the supplied pool's ID to be in that grant's allowlist.

At the exact expiration timestamp, the session is no longer authorized.

## Session lifecycle

```move
public fun session_expiration_ms(
    wrapper: &AccountWrapper,
    session: address,
): Option<u64>

public fun session_allowed_pools(
    wrapper: &AccountWrapper,
    session: address,
): Option<vector<ID>>

public fun authorize_session(
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    session: address,
    duration_ms: u64,
    allowed_pools: vector<ID>,
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

`session_allowed_pools` returns the stored DeepBook pool allowlist for a known session and `none` for a session that was never authorized or has been revoked. An empty vector means the session cannot call spot wrappers.

The shared `AccountWrapper` can be supplied as an object input in a programmable transaction block and borrowed immutably for the session getters. SDKs may also use the functions through dev-inspect reads.

Revoking a known session removes it from the session map immediately, whether it is active or already expired, and frees its slot for another address. Once the Sessions app-data slot has been attached to an Account, it remains attached even when the session map becomes empty. Revoking an unknown session is a no-op. Expired entries are not removed automatically because time passing does not execute Move code; they continue to count toward the 20-session limit until the owner revokes them, while reauthorization replaces the expiration and pool allowlist in place.

Session reads and revocation remain available after a package version is retired so owners can inspect and remove grants without using a trading-capable package version.

## Version governance

Publishing Sessions creates a shared `SessionsConfig` at the package's compiled-in version and transfers a `SessionsAdminCap` to the publisher. `authorize_session` and every trading wrapper require the shared config and reject package versions below its watermark.

Each package upgrade must increment `current_version!()`. After clients have moved to the new package, the `SessionsAdminCap` holder calls that package's `bump_version_watermark`; the function derives the target from the executing package and only advances the watermark, so callers cannot select an arbitrary version or use an older package to retire a newer one.

Advancing the watermark retires authorization and trading entrypoints in older package versions. Account-level deauthorization of `SessionsApp` remains the lineage-wide emergency stop because it prevents every version of the app from generating Account authorization.

## Predict wrappers

An active session may call these wrappers:

- `mint_exact_quantity`
- `mint_exact_amount`
- `redeem_live`
- `redeem_settled`

Each wrapper validates the package version and session against the supplied Account, generates app authorization internally, and immediately passes that authorization into the corresponding Predict function. All market parameters remain caller-selected and are validated by Predict.

## DeepBook spot wrappers

An active session may call these Account-backed DeepBook spot wrappers:

- `place_limit_order`
- `place_market_order`
- `cancel_live_order`
- `cancel_live_orders`
- `withdraw_settled_amounts`

Each wrapper validates the package version and session against the supplied Account, checks that the supplied pool ID is in the grant allowlist, generates app authorization internally, and immediately passes it into the corresponding `deepbook_core_account` function. Order parameters remain caller-selected and are validated by the Account wrapper and DeepBook core. The permissionless settled-amount withdrawal is not duplicated here because it does not require session authority.

A grant with an empty pool list can still submit adverse Predict trades. A grant with listed pools can submit adverse spot trades on those pools only, cancel the Account's orders there, and sweep settled proceeds from those pools. A grant should be treated as trading authority for Predict and for the listed pools, not read-only access. Revocation and expiration stop future wrapper calls but do not unwind positions, orders, or transactions that already executed.

## Events

`SessionAuthorized` is emitted for both a new grant and a reauthorization:

```move
public struct SessionAuthorized has copy, drop {
    account_id: ID,
    session: address,
    expires_at_ms: u64,
    allowed_pools: vector<ID>,
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

Before Sessions can be used, the package must be published against the intended Account, Predict, Propbook, DeepBook core, and `deepbook_core_account` package lineages. Integrations must discover the published shared `SessionsConfig` and supply it to session authorization and every trading wrapper. `SessionsApp` must be authorized in the corresponding Account registry, while `DeepbookCoreAccountApp` must be authorized in the supplied DeepBook registry for spot order placement. Publication, registry configuration, SDK transaction construction, ephemeral-key storage, indexing, and deployment are outside this package.

Custody of `SessionsAdminCap` and any package upgrade capability is part of the trust boundary: the admin cap can retire older package versions, while an upgrade can change the behavior of an authorized Account app.

## Build and test

From the repository root:

```sh
sui move build --path packages/sessions --warnings-are-errors
sui move test --path packages/sessions --gas-limit 100000000000
```
