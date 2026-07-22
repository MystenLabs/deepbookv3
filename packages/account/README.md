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
    receive_address: address,
    balances: Bag,
    settlements: Bag,
}
```

`AccountWrapper` is the shared object users and apps pass into entrypoints that need
to load an account. `Account` is embedded inside it and is not a standalone shared
object.

`Account.account_id()` returns the canonical account ID: the dynamic-field root
used for app data and the identity events emit. `Account.receive_address()` returns
the **wrapper object's address** — the accumulator/funds-receive anchor. Coins are
delivered to and settled from the wrapper address, because only a real shared
object's UID can back an address-balance withdrawal (the nested `account_id` UID
never can). Use `receive_address` for `balance::send_funds`, never the account ID.

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

`derived_address` is the canonical account identity. Use it for events and
account-local storage. `derived_wrapper_address` identifies the shared wrapper
object that must be passed to load the account — and, because the wrapper is the
funds-receive anchor, its address is also where accumulator funds are delivered.
Call `.to_id()` on either address when an object ID is needed.

## Identity Model

Each owner gets two derived IDs under the registry root:

- canonical account ID: app data root and event `account_id`
- wrapper ID: shared object handle that gates account loading; its address is the
  accumulator/funds-receive anchor (`Account.receive_address`)

The canonical account ID is the account's public identity. The wrapper ID is an
implementation detail needed because Sui shared objects are what transactions pass
and borrow — and, for the same reason, the only identity that can anchor
address-balance custody.

LP fills and other accumulator-delivered funds therefore land at the wrapper
address (`receive_address`), not at the `account_id` address: an event's
`account_id` names *which* account, and `receive_address` (read it off the account,
or derive it via `derived_wrapper_address`) names *where* that account's coins are
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

App auth is deliberately full-account authority. It is not scoped by account
owner, coin type, app data slot, protocol, or per-user opt-in. A whitelisted app
that can generate app auth can mutably load any `AccountWrapper` it is handed and
can then use the normal `Account` APIs for all balances and account-local data it
is otherwise permitted to touch. This replaces the old `BalanceManager`-style
product custody boundary with shared account infrastructure for DeepBook products.

Treat a whitelisted app as trusted account infrastructure, not as a narrow plugin.
Any user-facing permissioning, solvency checks, market membership, liquidation
eligibility, or protocol-specific limits must live inside that app's own
entrypoints before it mutates the loaded account. This is intentional for future
cross-product systems such as account margining, where one authorized app may need
to evaluate and liquidate the full account across multiple products.

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

Write paths. The bare `deposit`/`withdraw` operate on stored balance only — the
caller settles accumulator funds at the flow boundary via `settle`:

```move
public fun deposit<T>(self: &mut Account, coin: Coin<T>)

public fun withdraw<T>(self: &mut Account, amount: u64, ctx: &mut TxContext): Coin<T>

public fun settle<T>(wrapper: &mut AccountWrapper, root: &AccumulatorRoot, clock: &Clock)
```

The PTB-callable entrypoints `deposit_funds`/`withdraw_funds` fold
settle → authorize → load → write into one call, taking an `Auth` and the
`AccumulatorRoot`/`Clock`:

```move
public fun deposit_funds<T>(
    wrapper: &mut AccountWrapper,
    auth: Auth,
    coin: Coin<T>,
    root: &AccumulatorRoot,
    clock: &Clock,
)

public fun withdraw_funds<T>(
    wrapper: &mut AccountWrapper,
    auth: Auth,
    amount: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T>
```

`settle` records the last timestamp per coin type in a `Bag`; if another parallel
transaction tries to settle the same coin in the same timestamp, the later
transaction skips settlement instead of trying to withdraw the same accumulator
funds again.

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
per-account opt-in list, per-coin permission map, or per-app user grant. Adding
that kind of dependency-aware user grant system is a separate design problem: for
example, a future margin app would need to prevent revoking another app while open
margin obligations depend on that app remaining liquidatable.

`deauthorize_app` is the admin break-glass path for stopping future app-auth
account loading by one app type. It does not represent a user-level revoke and it
does not unwind obligations already created by higher-level protocols.

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

Account has dedicated unit tests in `tests/account_tests.move`. The current Sui
framework lock exposes the empty-root accumulator test constructor, so stored
balance deposit/withdraw custody tests run in-package.

```bash
sui move test --path packages/account --gas-limit 100000000000
```

See `ACCUMULATOR_TESTING_STATUS.md` for the remaining accumulator-backed flows
that still need framework support or integration coverage before mainnet.
