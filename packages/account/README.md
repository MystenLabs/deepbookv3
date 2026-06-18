# account

`account` is a reusable account package for the DeepBook ecosystem. It gives each
owner one canonical account identity for custody, app-local data, and event
attribution, while using a separate shared wrapper object to control who can borrow
the account mutably.

The package is intentionally app-agnostic. It does not know about orders, markets,
LP requests, or other protocol-specific state. Apps receive an `&mut Account` only
after the account package or registry has checked the appropriate authority.

## Modules

### `account::account`

Owns the account state and the APIs that operate on loaded accounts.

```move
public struct AccountWrapper has key {
    id: UID,
    account: Account,
}

public struct Account has store {
    account_id: UID,
    owner: address,
    balances: Bag,
    settlements: Bag,
}
```

`AccountWrapper` is the shared object users and apps pass into entrypoints that need
to load an account. `Account` is embedded inside it and is not a standalone shared
object.

`Account.account_id()` returns the canonical account ID. This is also the object
address used for accumulator settlement and the dynamic-field root used for app
data. `Account.receive_address()` returns the same identity as an address, suitable
for `balance::send_funds`.

### `account::account_registry`

Owns the derivation root and the app whitelist.

The registry creates canonical accounts:

```move
public fun new(registry: &mut AccountRegistry, ctx: &mut TxContext): AccountWrapper
public fun new_self_owned(
    registry: &mut AccountRegistry,
    owner_uid: &mut UID,
    ctx: &mut TxContext,
): AccountWrapper
```

The returned wrapper must be shared with `account::share`.

The registry exposes both derived addresses:

```move
public fun derived_address(registry: &AccountRegistry, owner: address): address
public fun derived_wrapper_address(registry: &AccountRegistry, owner: address): address
```

`derived_address` is the canonical account identity. Use it for events,
account-local storage, and accumulator delivery. `derived_wrapper_address`
identifies the shared wrapper object that must be passed to load the account.
Call `.to_id()` on either address when an object ID is needed.

## Identity Model

Each owner gets two derived IDs under the registry root:

- canonical account ID: app data root, accumulator receive address, and event
  `account_id`
- wrapper ID: shared object handle that gates account loading

The canonical account ID is the account's public identity. The wrapper ID is an
implementation detail needed because Sui shared objects are what transactions pass
and borrow.

This split keeps LP fills and other accumulator-delivered funds consistent with
events: when an event emits `account_id`, that ID's address is also where coins are
delivered.

The wrapper model intentionally serializes mutable access to one account: two
transactions that both need the same `AccountWrapper` cannot mutate that account in
parallel. Independent accounts still execute independently, and app state stays
co-located with custody for account-level invariants.

## Authority Model

Account mutation authority is represented by an `Auth` hot potato that is consumed
to borrow `&mut Account` from an `AccountWrapper`.

There is no `Proof`, `DataProof`, `Vault`, or `OwnerCap` in the current model. Those
were earlier designs and are not part of the source package.

Owner-controlled auth:

```move
public fun load_account(wrapper: &AccountWrapper): &Account
public fun generate_auth(ctx: &TxContext): Auth
public fun generate_auth_as_object(uid: &mut UID): Auth
public fun load_account_mut(wrapper: &mut AccountWrapper, auth: Auth): &mut Account
```

`generate_auth` proves the transaction sender. `generate_auth_as_object` proves the
caller has mutable access to an owning object's `UID`. `load_account_mut` consumes
the auth hot potato and checks it against the wrapper's account owner.

App-controlled auth:

```move
public fun generate_auth_as_app<App>(
    registry: &AccountRegistry,
    permit: Permit<App>,
): Auth
```

The `Permit<App>` proves the call is executing in the module that defines `App`.
The registry whitelist decides whether that app is allowed to generate app auth.

Once a caller has `&mut Account`, coin movement and app-data mutation need no extra
account-level proof. The mutable borrow is the authority boundary.

## Coin Balances

Account balances are stored per coin type in a `Bag`. The account also supports Sui
address-balance delivery through the funds accumulator.

Read path:

```move
public fun balance<T>(account: &Account, root: &AccumulatorRoot, clock: &Clock): u64
```

This returns stored balance plus unsettled accumulator funds unless this coin type
has already been settled in the current timestamp.

Write paths:

```move
public fun deposit<T>(
    account: &mut Account,
    coin: Coin<T>,
    root: &AccumulatorRoot,
    clock: &Clock,
)

public fun withdraw<T>(
    account: &mut Account,
    amount: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T>
```

Both write paths first passively settle accumulator-delivered funds for `T` into the
stored balance. Settlement records the last timestamp per coin type in a `Bag`; if
another parallel transaction tries to settle the same coin in the same timestamp,
the later transaction skips settlement instead of trying to withdraw the same
accumulator funds again.

## App Data

Apps can attach one opaque data slot per app witness type:

```move
public fun attach<App, Data: store>(account: &mut Account, permit: Permit<App>, data: Data)
public fun has_data<App>(account: &Account): bool
public fun borrow_data<App, Data: store>(account: &Account): &Data
public fun borrow_data_mut<App, Data: store>(
    account: &mut Account,
    permit: Permit<App>,
): &mut Data
public fun detach<App, Data: store>(account: &mut Account, permit: Permit<App>): Data
```

The slot is keyed by `DataKey<App>` under the canonical account ID. Reads are open
because on-chain state is public. Writes require `Permit<App>`, so only the app's
own module can mutate its slot.

Apps that want lazy account-local state should put the ensure/create logic inside
their own account-data helper. Callers should not have to know whether the app data
has already been attached.

## App Whitelist

The registry admin controls which app witness types can mutably load accounts:

```move
public fun authorize_app<App>(registry: &mut AccountRegistry, cap: &AccountAdminCap)
public fun deauthorize_app<App>(registry: &mut AccountRegistry, cap: &AccountAdminCap)
public fun is_app_authorized<App>(registry: &AccountRegistry): bool
public fun assert_app_is_authorized<App>(registry: &AccountRegistry)
```

The whitelist is intentionally registry-scoped and ecosystem-wide. It is not a
per-account opt-in list.

## Typical Flow

EOA-owned account:

```move
let wrapper = registry.new(ctx);
wrapper.share();

// Later, in a PTB or app entrypoint:
let auth = account::generate_auth(ctx);
let account = wrapper.load_account_mut(auth);
some_app::do_something(account, ...);
```

Object-owned account:

```move
let wrapper = registry.new_self_owned(&mut owner_uid, ctx);
wrapper.share();

// Later, from the owner object's module:
let auth = account::generate_auth_as_object(&mut owner_uid);
let account = wrapper.load_account_mut(auth);
some_app::do_something(account, ...);
```

Whitelisted app:

```move
let auth = registry.generate_auth_as_app<MyApp>(permit<MyApp>());
let account = wrapper.load_account_mut(auth);
```

## Build

```bash
sui move build --path packages/account --warnings-are-errors
```

## Tests

Account has dedicated unit tests in `tests/account_tests.move`. This PR keeps the
package on the repo-standard stable/testnet Sui framework, which does not yet
expose the accumulator root constructor used by the custody tests. The
root-dependent deposit/withdraw cases are therefore disabled on this branch.

```bash
sui move test --path packages/account --gas-limit 100000000000
```

See `ACCUMULATOR_TESTING_STATUS.md` for the current dependency choice, the
nightly verification path that can re-enable empty-root tests, and the remaining
accumulator-backed flows that still need stable framework or integration coverage
before mainnet.
