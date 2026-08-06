# Sessions

`deepbook_sessions` lets the owner of a canonical DeepBook Account authorize an ephemeral address to submit a limited set of Predict transactions for that Account until a fixed expiration time.

The package is an Account app. It stores session grants in the Account's app-local data and generates Account app authorization only inside its Predict wrapper functions. Session callers never receive a reusable `account::Auth`, and the package exposes no withdrawal or arbitrary Account mutation entrypoint.

## Authority model

The Account registry administrator must authorize `SessionsApp` before any wrapper can generate app authorization. This registry-level authorization makes the package trusted Account infrastructure; it does not itself grant a session for any user.

An Account owner opts in by calling `authorize_session` on the Account's shared `AccountWrapper`. Owner authorization is derived from the transaction sender, so this flow supports EOA-owned Accounts and does not authorize object-owned Accounts.

A session grant contains only the session address and its expiration timestamp in milliseconds. Each Account may store at most 20 session addresses. The requested duration must be greater than zero and no more than 30 days. Expiration is calculated from the on-chain `Clock` at execution time, and reauthorizing the same address replaces its stored expiration without consuming another slot.

Every Predict wrapper requires both of these conditions:

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

## Predict wrappers

An active session may call these wrappers:

- `mint_exact_quantity`
- `mint_exact_amount`
- `redeem_live`
- `redeem_settled`

Each wrapper validates the session against the supplied Account, generates app authorization internally, and immediately passes that authorization into the corresponding Predict function. All market parameters remain caller-selected and are validated by Predict.

The session can therefore submit adverse trades for the Account until it expires or is revoked. A grant should be treated as trading authority, not read-only access. Revocation and expiration stop future wrapper calls but do not unwind positions or transactions that already executed.

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

Expiration emits no event, and a no-op revocation emits no event. Predict continues to emit the underlying mint and redeem events; the wrappers do not duplicate them.

## Integration requirements

Before Sessions can be used, the package must be published against the intended Account, Predict, and Propbook package lineage, and `SessionsApp` must be authorized in the corresponding Account registry. Publication, registry configuration, SDK transaction construction, ephemeral-key storage, indexing, and deployment are outside this package.

If the package is published with an upgrade capability, custody of that capability is part of the trust boundary because an upgrade can change the behavior of an authorized Account app.

## Build and test

From the repository root:

```sh
sui move build --path packages/sessions --warnings-are-errors
sui move test --path packages/sessions --gas-limit 100000000000
```
