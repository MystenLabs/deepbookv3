---
paths:
  - "packages/**/*.move"
---

# Sui Move Instructions

**Update this file** when you discover new Move patterns, gotchas, or best practices during sessions.

- Comments are opt-in, not a coverage requirement. Use comments to explain module responsibility, public API contracts, ownership boundaries, invariants, unit/scaling conventions, lifecycle state, sequencing requirements, gas/storage tradeoffs, external dependency quirks, or non-obvious math.

- Do not add comments that restate a function name, narrate obvious code, explain Move syntax, describe simple assignments, or repeat names already clear from types. If deleting a comment would not make the code harder to use or safely modify, delete it.

- For struct fields, comment selectively. Config structs are strong candidates for field comments because they encode policy, units, and economic meaning. Non-config structs should only comment fields with non-obvious mapping semantics, custody/ownership, timestamps, lifecycle state, sentinel values, units, or invariants.

- A struct-level doc can cover a group of obvious fields that share one convention. Do not duplicate the same explanation above every field.

- When changing behavior, update nearby comments in the same edit. Stale comments are worse than missing comments.

- Sui is an object-oriented blockchain. Sui smart contracts are written in the Move language.

- Sui's object ownership model guarantees that the sender of a transaction has permission to use the objects it passes to functions as arguments.

- Sui object ownership model in a nutshell:
  - Single owner objects: owned by a single address - granting it exclusive control over the object.
  - Shared objects: any address can use them in transactions and pass them to functions.
  - Immutable objects: like Shared objects, any address can use them, but they are read-only.

- Abilities are a Move typing feature that control what actions are permissible on a struct:
  - `key`: the struct can be used as a key in storage. If an struct does not have the key ability, it has to be stored under another struct or destroyed before the end of the transaction.
  - `store`: the struct can be stored inside other structs. It also relaxes transfer restrictions.
  - `drop`: the struct can be dropped or discarded. Simply allowing the object to go out of scope will destroy it.
  - `copy`: the struct can be copied.

- Structs can only be created within the module that defines them. A module exposes functions to determine how its structs can be created, read, modified and destroyed.

- Similarly, the `transfer::transfer/share/freeze/receive/party_transfer` functions can only be called within the module that defines the struct being transferred. However, if the struct has the `store` ability, the `transfer::public_transfer/public_share/etc` functions can be called on that object from other modules.

- All numbers are unsigned integers (u8, u16, u32, u64, u128, u256).

- Functions calls are all or nothing (atomic). If there's an error, the transaction is reverted.

- Race conditions are impossible.

- It is allowed to compare a reference to a value using == or !=. The language automatically borrows the value if one operand is a reference and the other is not.

- Integer overflows/underflows are automatically reverted. Any transaction that causes an integer overflow/underflow cannot succeed. E.g. `std::u64::max_value!() + 1` raises an arithmetic error.

- Don't worry about "missing imports", because the compiler includes many std::/sui:: imports by default.

- When using `sui::dynamic_field`, always define `use fun` aliases for method syntax on UID:
```move
use sui::dynamic_field as df;

use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
use fun df::borrow_mut as UID.borrow_mut;
use fun df::exists_ as UID.exists_;
```
Then call as `self.id.exists_(key)`, `self.id.add(key, value)`, `self.id.borrow(key)`, `self.id.borrow_mut(key)` instead of `df::exists_(&self.id, key)` etc.

- Prefer receiver (method) syntax over module-qualified calls when available. Move auto-resolves `x.fn(...)` whenever `fn` is defined in the module that declares `x`'s type (including across packages — e.g. `feed.price()` resolves to `pyth_lazer::feed::price(&feed)`, `inner.magnitude()` resolves to `predict_math::i64::magnitude(&inner)`). No `use fun` alias is needed for this case; it's only required when the function lives in a *different* module from the type (as with `dynamic_field` on `UID`). Receiver syntax lets you drop the module alias entirely when it was only used for those calls — check for and remove the now-unused `Self` import (the compiler warns `unused alias`).

- Don't worry about emitting additional events.

- Prefer macros over constants.

- Function ordering within a module (top to bottom):
  1. `public fun` - external API functions
  2. `public(package) fun` - package-internal functions
  3. `fun` - private/internal helper functions

  Within each visibility group, put read-only/query functions before mutating/write functions. Place private helpers after the function that first makes the call when that does not conflict with the visibility grouping; if read/write ordering and adjacency conflict, preserve the broader read-before-write grouping.

  Exception: `init` function typically comes early (after struct definitions).

- Function inputs should be ordered by role: mutable domain objects first, immutable domain objects second, primitive/domain values third, execution context last. `clock: &Clock` is execution context and should be second-to-last when present; `ctx: &mut TxContext` is always last. Constructors with only primitive grid inputs should use natural domain order such as `min_strike, tick_size, max_strike, ctx`. Private algorithm helpers may keep traversal/key ordering when changing it would make the algorithm less readable, but public and package APIs should not put primitive values before object references.

- Utility and math modules should only guard local mathematical or data-structure preconditions (division by zero, invalid precision, insufficient balance/quantity, invalid ranges). They should not encode application-level policy decisions like "this state shouldn't happen" or "this user type gets different treatment." Application-level guards belong in the calling module.

- Do not add explicit overflow, underflow, or numeric-cast asserts solely to replace Move's primitive VM aborts. Move arithmetic and numeric casts already abort atomically on overflow. Keep named assertions for semantic domain bounds, division by zero when the module has a meaningful named zero error, solvency/accounting invariants, authorization, lifecycle, and gas-bounded iteration.

- Bounding one input only proves the bound it names. For example, `pow10(shift)` can guard its exponent, while callers that need a semantic maximum normalized price should assert that semantic price bound explicitly. Do not add a second assert merely to give primitive multiplication overflow a custom abort code.

- When two code paths can drive the same terminal state transition (e.g. an oracle settlement frozen by either a permissionless feed update or a privileged operator update), make sure both paths apply the same validation. A first-writer-wins race is a hidden authorization decision: if the privileged path can race the trustworthy path during a degraded state (stale feed, paused upstream), the privileged actor can unilaterally write the terminal value with weaker checks. Either gate the privileged path on the trustworthy path's freshness, or require the trustworthy path for terminal transitions.

- Admin setters that don't bound away from "no-op" values are a defense-in-depth gap. A circuit-breaker deviation cap that accepts up to 100%, or absolute bounds with no floor/ceiling, lets a single bad admin call silently disable the protection without any error. When a setter exists primarily to tighten a safety check, give it a hard ceiling tighter than the trivially-disabling value (e.g. cap deviation at 50%, bound `min_basis`/`max_basis` within an absolute envelope) so admin error or compromise can't turn the guard into a no-op.

- Don't move leaf-level semantic guards to callers because "the current caller validates first." That reasoning creates a cross-module invariant. Leaf primitives in `public(package)` data structures should remain self-consistent for the domain facts they own, such as valid ranges, sufficient quantity, or balance availability. Primitive arithmetic overflow does not need a duplicate semantic wrapper unless the wrapper enforces a real domain bound.

- Converse of the leaf-guard rule: caller-side guards that merely duplicate a leaf semantic check (same bound, same intent) are clutter, not defense-in-depth. Two exceptions worth keeping the duplicate for: (a) the caller can supply a semantically richer error for a different business precondition; (b) the caller's bound is strictly tighter than the leaf's. Otherwise delete the caller-side assert and let the leaf be the single source of truth.

- Timestamp fields should have clear semantics. If `timestamp` means "last price update", don't bump it on unrelated updates (e.g., SVI param changes). Muddled semantics break staleness checks.

- Distinguish on-chain landing time from source-data time in the field name itself. A bare `lazer_timestamp` is ambiguous — does it mean the publisher's timestamp embedded in the verified payload, or `clock.timestamp_ms()` captured when the payload landed on chain? Use a unit suffix that encodes both the unit and the source: `*_timestamp_ms` for `clock.timestamp_ms()` values (on-chain landing time, always milliseconds in Sui), and `*_published_at_us` (or similar explicit phrase) for timestamps that come from the data being pushed. Same convention for event payload fields and getter names. Bulk renames across an entire package are safe with `perl -i -pe 's/\bX\b/Y/g'` since `\b` correctly skips compound identifiers like `lazer_X_ms`.

- Validate before mutate means contract-owned facts, not broad application preflighting. A function must validate the mutation-independent facts it owns before mutating state: flow gates, authorization, object binding, branch/lifecycle policy, static creation inputs, and facts that decide whether the function may start its transition. Do not duplicate another module's leaf guard just to avoid a later abort; preflight another module's fact only when the caller must know it before mutating a different state owner. If accounting or pricing intentionally depends on post-mutation state, make that dependency obvious and validate mutation-independent facts first. Always validate before consuming irreversible resources such as burning coins or destroying objects.

- In multi-object flows, a mid-function assertion is often a phase boundary. Prefer extracting that phase into a helper where the helper starts with its own mutation-independent preconditions, performs one coherent state transition, and ends with the postconditions for the resources it changed. Keep postcondition helpers named by the resource they protect, such as allocation backing versus cash backing, and only combine them when they are always meaningful at the same point.

- Emit events after the state transition and postconditions they report have completed, unless the event intentionally reports an attempted action rather than a completed one.

- If a flow branches on another object's lifecycle or state, validate the object binding before using that state for branch selection, unless that branch intentionally does not require the object.

- Prefer explicit loop bounds over `while (true)` when the iteration range is easy to express. If a loop naturally means "from `min_page` to `max_page` inclusive" or "while `slot <= end_slot`", write that directly instead of using `while (true)` plus interior `break`s.

- Avoid deprecated Sui framework functions. Use the current recommended API (e.g., `coin_registry::new_currency_with_otw` instead of `coin::create_currency`). If a deprecated function must be used, add a comment explaining why the replacement doesn't work for this case.

- `create_and_share` constructors should accept tunable per-instance config as constructor parameters rather than seeding defaults that the admin must immediately overwrite. After `share_object` the only way to reconfigure is a separate setter tx, so a default-only constructor forces a two-tx admin flow whenever an instance needs non-default values. Take the params directly, validate them with the same `assert_*` helpers the setter uses (so creation and update share one validation path), and use defaults only when the config is genuinely the same for every instance.

## Tool Calling Instructions

- `sui move build` to build the package, must be run in a directory with Move.toml in it
- `sui move test --gas-limit 100000000000` to run tests, must be run in a directory with Move.toml in it. The high gas limit is needed because sui 1.66+ lowered the default test gas budget, causing complex tests to time out.
- When `sui move test` shows warnings (e.g., unused `mut` modifiers, unused variables), fix them immediately before proceeding
- Before claiming Move or protocol work is complete, run the relevant package test suite(s) and confirm they pass with zero failures. If the change affects multiple packages or local package manifests, run each impacted package's tests.
- can pass `--skip-fetch-latest-git-deps` if the dependencies haven't changed after an initial successful build
- when you have completed making changes, run `bunx prettier-move -c *.move --write` on any files that are modified to format them correctly.

# Move Code Quality Checklist

The rapid evolution of the Move language and its ecosystem has rendered many older practices
outdated. This guide serves as a checklist for developers to review their code and ensure it aligns
with current best practices in Move development.

## Code Organization

Some of the issues mentioned in this guide can be fixed by using
[Move Formatter](https://www.npmjs.com/package/@mysten/prettier-plugin-move) either as a CLI tool,
or [as a CI check](https://github.com/marketplace/actions/move-formatter), or
[as a plugin for VSCode (Cursor)](https://marketplace.visualstudio.com/items?itemName=mysten.prettier-move).

## Package Manifest

### Use Right Edition

All of the features in this guide require Move 2024 Edition, and it has to be specified in the
package manifest.

```toml
[package]
name = "my_package"
edition = "2024.beta" # or (just) "2024"
```

### Implicit Framework Dependency

Starting with Sui 1.45 you no longer need to specify framework dependency in the `Move.toml`:

```toml
# old, pre 1.45
[dependencies]
Sui = { ... }

# modern day, Sui, Bridge, MoveStdlib and SuiSystem are imported implicitly!
[dependencies]
```

### Prefix Named Addresses

If your package has a generic name (e.g., `token`) – especially if your project includes multiple
packages – make sure to add a prefix to the named address:

```toml
# bad! not indicative of anything, and can conflict
[addresses]
math = "0x0"

# good! clearly states project, unlikely to conflict
[addresses]
my_protocol_math = "0x0"
```

### Keep Local Package Style Consistent

If an old-style package depends on another local package, do not migrate only one side of that
dependency edge. In this repo, `packages/margin_liquidation` still depends on old-style
`packages/deepbook_margin`, so removing `[addresses] deepbook_margin = "0x0"` from
`packages/deepbook_margin/Move.toml` breaks dependents with
`Packages with old-style Move.toml files cannot depend on new-style packages`.

## Imports, Module and Constants

### Using Module Label

```move
// bad: increases indentation, legacy style
module my_package::my_module {
    public struct A {}
}

// good!
module my_package::my_module;

public struct A {}
```

### No Single `Self` in `use` Statements

```move
// correct, member + self import
use my_package::other::{Self, OtherMember};

// bad! `{Self}` is redundant
use my_package::my_module::{Self};

// good!
use my_package::my_module;
```

### All `use` Statements at Module Top Level

```move
// bad! function-local imports
fun my_function() {
    use my_package::my_module;
    // ...
}

// good! all imports at module top level
use my_package::my_module;

fun my_function() {
    // ...
}
```

### Group `use` Statements with `Self`

```move
// bad!
use my_package::my_module;
use my_package::my_module::OtherMember;

// good!
use my_package::my_module::{Self, OtherMember};
```

### Error Constants are in `EPascalCase`

```move
// bad! all-caps are used for regular constants
const NOT_AUTHORIZED: u64 = 0;

// good! clear indication it's an error constant
const ENotAuthorized: u64 = 0;
```

### Regular Constant are `ALL_CAPS`

```move
// bad! PascalCase is associated with error consts
const MyConstant: vector<u8> = b"my const";

// good! clear indication that it's a constant value
const MY_CONSTANT: vector<u8> = b"my const";
```

## Structs

### Capabilities are Suffixed with `Cap`

```move
// bad! if it's a capability, add a `Cap` suffix
public struct Admin has key, store {
    id: UID,
}

// good! reviewer knows what to expect from type
public struct AdminCap has key, store {
    id: UID,
}
```

### No `Potato` in Names

```move
// bad! it has no abilities, we already know it's a Hot-Potato type
public struct PromisePotato {}

// good!
public struct Promise {}
```

### Events Should Be Named in Past Tense

```move
// bad! not clear what this struct does
public struct RegisterUser has copy, drop { user: address }

// good! clear, it's an event
public struct UserRegistered has copy, drop { user: address }
```

### Emit Events From the Owning Module

- Emit an event from the module that owns the lifecycle or action being reported.
- Name event fields semantically from that event domain. Prefer `expiry_market_id`, `pool_vault_id`, or `market_oracle_id` over generic names like `owner_id`, `object_id`, or `config_id`.
- Do not thread IDs through unrelated helper or leaf modules only to provide event context.
- Embedded accounting/helper modules should not emit parent-scoped events unless the parent identity is part of their own domain model. If a parent-scoped event needs helper-computed values, return a summary and emit the event in the parent/action module.

### Use Positional Structs for Dynamic Field Keys + `Key` Suffix

```move
// not as bad, but goes against canonical style
public struct DynamicField has copy, drop, store {}

// good! canonical style, Key suffix
public struct DynamicFieldKey() has copy, drop, store;
```

## Functions

### No `public entry`, Only `public` or `entry`

```move
// bad! entry is not required for a function to be callable in a transaction
public entry fun do_something() { /* ... */ }

// good! public functions are more permissive, can return value
public fun do_something_2(): T { /* ... */ }
```

### Write Composable Functions for PTBs

```move
// bad! not composable, harder to test!
public fun mint_and_transfer(ctx: &mut TxContext) {
    /* ... */
    transfer::transfer(nft, ctx.sender());
}

// good! composable!
public fun mint(ctx: &mut TxContext): NFT { /* ... */ }

// good! intentionally not composable
entry fun mint_and_keep(ctx: &mut TxContext) { /* ... */ }
```

### Keep Return Tuples Small and Semantic

- Across module boundaries, return only values the caller cannot already derive.
- Avoid wide positional tuples, especially 4+ items or repeated primitive types with domain meaning.
- If several values need to travel together, either reduce the return shape or use a named package-only summary struct.
- Private, tightly local algorithm helpers can use tuples when destructuring names make the meaning clear.
- When a struct repeats the exact field group of another local struct and helpers only copy values between them, prefer embedding the named struct directly. This keeps the real data shape visible and removes projection boilerplate such as `to_summary` / `write_summary` helpers.

### Objects Go First (Except for Clock)

```move
// bad! hard to read!
public fun call_app(
    value: u8,
    app: &mut App,
    is_smth: bool,
    cap: &AppCap,
    clock: &Clock,
    ctx: &mut TxContext,
) { /* ... */ }

// good!
public fun call_app(
    app: &mut App,
    cap: &AppCap,
    value: u8,
    is_smth: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) { /* ... */ }
```

### Capabilities Go Second

```move
// bad! breaks method associativity
public fun authorize_action(cap: &AdminCap, app: &mut App) { /* ... */ }

// good! keeps Cap visible in the signature and maintains `.calls()`
public fun authorize_action(app: &mut App, cap: &AdminCap) { /* ... */ }
```

### Getters Named After Field + `_mut`

```move
// bad! unnecessary `get_`
public fun get_name(u: &User): String { /* ... */ }

// good! clear that it accesses field `name`
public fun name(u: &User): String { /* ... */ }

// good! for mutable references use `_mut`
public fun details_mut(u: &mut User): &mut Details { /* ... */ }
```

## Function Body: Struct Methods

### Common Coin Operations

```move
// bad! legacy code, hard to read!
let paid = coin::split(&mut payment, amount, ctx);
let balance = coin::into_balance(paid);

// good! struct methods make it easier!
let balance = payment.split(amount, ctx).into_balance();

// even better (in this example - no need to create temporary coin)
let balance = payment.balance_mut().split(amount);

// also can do this!
let coin = balance.into_coin(ctx);
```

### Do Not Import `std::string::utf8`

```move
// bad! unfortunately, very common!
use std::string::utf8;

let str = utf8(b"hello, world!");

// good!
let str = b"hello, world!".to_string();

// also, for ASCII string
let ascii = b"hello, world!".to_ascii_string();
```

### UID has `delete`

```move
// bad!
object::delete(id);

// good!
id.delete();
```

### `ctx` has `sender()`

```move
// bad!
tx_context::sender(ctx);

// good!
ctx.sender()
```

### Vector Has a Literal. And Associated Functions

```move
// bad!
let mut my_vec = vector::empty();
vector::push_back(&mut my_vec, 10);
let first_el = vector::borrow(&my_vec);
assert!(vector::length(&my_vec) == 1);

// good!
let mut my_vec = vector[10];
let first_el = my_vec[0];
assert!(my_vec.length() == 1);
```

### Collections Support Index Syntax

```move
let x: VecMap<u8, String> = /* ... */;

// bad!
x.get(&10);
x.get_mut(&10);

// good!
&x[&10];
&mut x[&10];
```

## Option -> Macros

### Destroy And Call Function

```move
// bad!
if (opt.is_some()) {
    let inner = opt.destroy_some();
    call_function(inner);
};

// good! there's a macro for it!
opt.do!(|value| call_function(value));
```

### Destroy Some With Default

```move
let opt = option::none();

// bad!
let value = if (opt.is_some()) {
    opt.destroy_some()
} else {
    abort EError
};

// good! there's a macro!
let value = opt.destroy_or!(default_value);

// for the "assert-then-extract" case, prefer assert! + destroy_some over
// destroy_or!(abort E) — keeps named error codes consistent with the rest
// of the function and avoids mixing assert and abort styles.
assert!(opt.is_some(), ECannotBeEmpty);
let value = opt.destroy_some();
```

## Loops -> Macros

### Do Operation N Times

```move
// bad! hard to read!
let mut i = 0;
while (i < 32) {
    do_action();
    i = i + 1;
};

// good! any uint has this macro!
32u8.do!(|_| do_action());
```

### New Vector From Iteration

```move
// harder to read!
let mut i = 0;
let mut elements = vector[];
while (i < 32) {
    elements.push_back(i);
    i = i + 1;
};

// easy to read!
vector::tabulate!(32, |i| i);
```

### Do Operation on Every Element of a Vector

```move
// bad!
let mut i = 0;
while (i < vec.length()) {
    call_function(&vec[i]);
    i = i + 1;
};

// good!
vec.do_ref!(|e| call_function(e));
```

### Destroy a Vector and Call a Function on Each Element

```move
// bad!
while (!vec.is_empty()) {
    call(vec.pop_back());
};

// good!
vec.destroy!(|e| call(e));
```

### Fold Vector Into a Single Value

```move
// bad!
let mut aggregate = 0;
let mut i = 0;

while (i < source.length()) {
    aggregate = aggregate + source[i];
    i = i + 1;
};

// good!
let aggregate = source.fold!(0, |acc, v| {
    acc + v
});
```

### Filter Elements of the Vector

> Note: `T: drop` in the `source` vector

```move
// bad!
let mut filtered = [];
let mut i = 0;
while (i < source.length()) {
    if (source[i] > 10) {
        filtered.push_back(source[i]);
    };
    i = i + 1;
};

// good!
let filtered = source.filter!(|e| e > 10);
```

## Other

### Ignored Values In Unpack Can Be Ignored Altogether

```move
// bad! very sparse!
let MyStruct { id, field_1: _, field_2: _, field_3: _ } = value;
id.delete();

// good! 2024 syntax
let MyStruct { id, .. } = value;
id.delete();
```

## Testing

### Merge `#[test]` and `#[expected_failure(...)]`

```move
// bad!
#[test]
#[expected_failure]
fun value_passes_check() {
    abort
}

// good!
#[test, expected_failure]
fun value_passes_check() {
    abort
}
```

### Do Not Clean Up `expected_failure` Tests

```move
// bad! clean up is not necessary
#[test, expected_failure(abort_code = my_app::EIncorrectValue)]
fun try_take_missing_object_fail() {
    let mut test = test_scenario::begin(@0);
    my_app::call_function(test.ctx());
    test.end();
}

// good! easy to see where test is expected to fail
#[test, expected_failure(abort_code = my_app::EIncorrectValue)]
fun try_take_missing_object_fail() {
    let mut test = test_scenario::begin(@0);
    my_app::call_function(test.ctx());

    abort // will differ from EIncorrectValue
}
```

### Do Not Prefix Tests With `test_` in Testing Modules

```move
// bad! the module is already called _tests
module my_package::my_module_tests;

#[test]
fun test_this_feature() { /* ... */ }

// good! better function name as the result
#[test]
fun this_feature_works() { /* ... */ }
```

### Do Not Use `TestScenario` Where Not Necessary

```move
// bad! no need, only using ctx
let mut test = test_scenario::begin(@0);
let nft = app::mint(test.ctx());
app::destroy(nft);
test.end();

// good! there's a dummy context for simple cases
let ctx = &mut tx_context::dummy();
app::mint(ctx).destroy();
```

### Do Not Use Abort Codes in `assert!` in Tests

```move
// bad! may match application error codes by accident
assert!(is_success, 0);

// good!
assert!(is_success);
```

### Use `assert_eq!` Whenever Possible

```move
// bad! old-style code
assert!(result == b"expected_value", 0);

// good! will print both values if fails
use std::unit_test::assert_eq;

assert_eq!(result, expected_value);
```

### Use "Black Hole" `destroy` Function

```move
// bad!
nft.destroy_for_testing();
app.destroy_for_testing();

// good! - no need to define special functions for cleanup
use sui::test_utils::destroy;

destroy(nft);
destroy(app);
```

## Comments

### Doc Comments Start With `///`

```move
// bad! tooling doesn't support JavaDoc-style comments
/**
 * Cool method
 * @param ...
 */
public fun do_something() { /* ... */ }

// good! will be rendered as a doc comment in docgen and IDE's
/// Cool method!
public fun do_something() { /* ... */ }
```

### Complex Logic? Leave a Focused Comment `//`

Use inline comments only when they explain a non-obvious invariant, sequencing
requirement, external dependency quirk, or gas/storage tradeoff. Do not narrate
the next line of code.

```move
// good!
// Note: can underflow if a value is smaller than 10.
// TODO: add an `assert!` here
let value = external_call(value, ctx);
```
