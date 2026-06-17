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
}
```

`AccountWrapper` is the shared object users and apps pass into entrypoints that need
to load an account. `Account` is embedded inside it and is not a standalone shared
object.

`Account.account_id()` returns the canonical account ID. This is also the
dynamic-field root used for app data. `Account.receive_address()` returns the same
identity as an address, suitable for address-balance delivery with
`balance::send_funds`.

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

The registry exposes both derived identities:

```move
public fun derived_address(registry: &AccountRegistry, owner: address): address
public fun derived_id(registry: &AccountRegistry, owner: address): ID
public fun derived_wrapper_address(registry: &AccountRegistry, owner: address): address
public fun derived_wrapper_id(registry: &AccountRegistry, owner: address): ID
```

`derived_address` / `derived_id` are the canonical account identity. Use these for
events, account-local storage, and address-balance delivery.
`derived_wrapper_address` / `derived_wrapper_id` identify the shared wrapper object
that must be passed to load the account.

## Identity Model

Each owner gets two derived IDs under the registry root:

- canonical account ID: app data root, address-balance receive address, and event
  `account_id`
- wrapper ID: shared object handle that gates account loading

The canonical account ID is the account's public identity. The wrapper ID is an
implementation detail needed because Sui shared objects are what transactions pass
and borrow.

This split keeps address-delivered funds consistent with events: when an event
emits `account_id`, that ID's address is also where coins are delivered.

## Authority Model

Account mutation authority is represented by a mutable borrow of `Account`.

There is no `Proof`, `DataProof`, `Vault`, or `OwnerCap` in the current model. Those
were earlier designs and are not part of the source package.

Owner-controlled loading:

```move
public fun load_account(wrapper: &AccountWrapper): &Account
public fun load_account_mut(wrapper: &mut AccountWrapper, ctx: &TxContext): &mut Account
public fun load_account_mut_as_object(
    wrapper: &mut AccountWrapper,
    uid: &mut UID,
): &mut Account
```

`load_account_mut` checks `ctx.sender() == account.owner`. `load_account_mut_as_object`
checks that the supplied mutable `UID` belongs to the owner object address, allowing
contract-owned accounts to act through their own object.

App-controlled loading:

```move
public fun load_account_mut_as_app<App>(
    registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    permit: Permit<App>,
): &mut Account
```

The `Permit<App>` proves the call is executing in the module that defines `App`.
The registry whitelist decides whether that app is allowed to mutably load ecosystem
accounts.

Once a caller has `&mut Account`, coin movement and app-data mutation need no extra
account-level proof. The mutable borrow is the authority boundary.

## Coin Balances

Account balances are stored per coin type in a `Bag`.

Read path:

```move
public fun balance<T>(account: &Account): u64
```

This returns the balance already stored inside the account.

Explicit address-balance claim path:

```move
public fun claimable<T>(account: &Account, root: &AccumulatorRoot): u64
public fun settle<T>(account: &mut Account, root: &AccumulatorRoot): u64
```

`claimable` reads settled address-balance funds for the account receive address.
`settle` withdraws those funds from the address balance and deposits them into
stored account custody.

Write paths:

```move
public fun deposit<T>(account: &mut Account, coin: Coin<T>)

public fun withdraw<T>(
    account: &mut Account,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T>
```

Both write paths operate only on stored balances. Address-delivered funds sent to
`receive_address()` are intentionally not folded into `balance`, `deposit`, or
`withdraw` in the current source; callers explicitly claim them with `settle`.

## Deferred Auto Settlement

Passive accumulator settlement is intentionally removed for now. The current source
keeps settlement as an explicit direct claim (`settle<T>`) because the Sui
framework requires callers to thread `AccumulatorRoot` explicitly, which would
otherwise leak settlement plumbing through every app entrypoint and helper that
might read or mutate coin balances.

Before mainnet, after Sui exposes the accumulator root through `TxContext`, Account
will reintroduce passive settlement behind the same account APIs. At that point,
coin reads and writes can incorporate address-delivered funds without adding an
explicit `AccumulatorRoot` parameter to Predict, Account, or other ecosystem app
surfaces.

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
let wrapper = account_registry::new(registry, ctx);
account::share(wrapper);

// Later, in a PTB or app entrypoint:
let account = account::load_account_mut(&mut wrapper, ctx);
some_app::do_something(account, ...);
```

Object-owned account:

```move
let wrapper = account_registry::new_self_owned(registry, &mut owner_uid, ctx);
account::share(wrapper);

// Later, from the owner object's module:
let account = account::load_account_mut_as_object(&mut wrapper, &mut owner_uid);
some_app::do_something(account, ...);
```

Whitelisted app:

```move
let account = account_registry::load_account_mut_as_app<MyApp>(
    registry,
    &mut wrapper,
    permit<MyApp>(),
);
```

## Build

```bash
sui move build --path packages/account --warnings-are-errors
```

The package currently has no dedicated unit tests.
