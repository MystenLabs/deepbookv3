# Predict math

`deepbook_predict_math` is a stateless Move library for [Predict](../predict/README.md). It holds Predict's pure pricing math, the decode of a packed order ID, and `LazerPrice`, a Pyth Lazer price built from a verified update.

The library exists because Sui caps a package at 102,400 bytes and Predict, which can only grow by compatible upgrade, is close to that limit. Moving pure functions here takes their bodies out of Predict while Predict keeps every check and every abort. It holds no objects, no balances, no capabilities, and no dynamic fields, emits no events, and takes no `TxContext`, so it cannot move value or read state.

## Modules

| Module | Contents |
| --- | --- |
| `math` | The SVI up-price with its roll-down (`roll_down`, `digital`), the pricing-safe input bounds and the minimum-variance checks as booleans (`inputs_ok`, `raw_var_ok`, `var_positive`), the Bernoulli trading-fee curve with its expiry ramp (`leg_fee`), the inventory-impact potential (`potential`), premium sizing (`max_qty`), the builder fee (`builder_fee`), the three cash-need formulas of queued orders (`need_qty`, `need_budget`, `need_sell`), and `order_terms`, which decodes a packed order ID into its ticks and quantity |
| `lazer_price` | `LazerPrice`, its one constructor `from_update`, its getters, and the fixed-rate channel macros |

Predict imports `math` as `pmath`. Every function takes and returns primitives or `fixed_math` values. Where a check fails, the library returns a boolean, `none`, or a numeric code, and Predict asserts with its own error constant, so a pricing, fee, or admission abort reports the same module and code as before the move. The bodies were moved unchanged from Predict.

`order_terms` reads Predict's frozen order-ID layout (30-bit ticks at bits 70 and 40, and a 32-bit count of 10,000-unit lots at bit 100). It validates nothing, so it is only for order IDs Predict issued. The order-flow companion [`deepbook_predict_orders`](../predict_orders/README.md) uses it to size early sells.

## `LazerPrice`

```move
public struct LazerPrice has copy, drop {
    feed_id: u32,
    channel: u8,
    envelope_us: u64,
    generation_us: u64,
    spot: u64,
}
```

`lazer_price::from_update(update: &Update, feed_id: u32): Option<LazerPrice>` decodes one feed of a verified `pyth_lazer::update::Update`. `envelope_us` is the update's timestamp and `generation_us` is the feed's own update time. `spot` is the price normalized to Predict's 1e9 scale, rounded down when the source is finer, positive, and at most Predict's pricing-safe ceiling of `u64::MAX / 100`.

- Only this module can build a `LazerPrice`, and its one constructor takes an `Update`, which only Pyth's verifier produces. Holding one therefore proves a Pyth signature over its feed, channel, both timestamps, and price.
- It has `copy` and `drop` but not `store`, so it lives within one transaction. It states a signed fact, so reusing it inside the transaction is harmless.
- `from_update` returns `none` when the feed's price or update time is empty at that tick, or when the price does not normalize to a pricing-safe spot. The caller leaves that order waiting.
- It aborts when the caller passed the wrong update: `EFeedMissing` when the update does not carry the feed, `EPropertyNotRequested` when the feed lacks the price, exponent, or update-time property, and `EGenerationAfterEnvelope` when the feed claims an update time after the envelope that carries it.
- Channels are Lazer's fixed-rate channel ids: `channel_fixed_rate_50ms!()` is 2 and `channel_fixed_rate_200ms!()` is 3. Any other channel decodes as 1 (real-time), which Predict never accepts.
- It reads Lazer's v1 `Update`, which Pyth marked deprecated on Mainnet but still serves. A later library upgrade adds a constructor for the v2 format.

Predict's `expiry_market::commit` takes a `&LazerPrice` and checks it against the order's receipt: the feed, the channel, an envelope at exactly the order's τ or one tick of its channel later, a generation time between τ and the envelope, an envelope at or before the clock, and a pricing-safe spot. Predict's public API names no Pyth type, so a Lazer format change touches this library and the companion but not Predict. See [delayed execution](../predict/docs/concepts/delayed-execution.md#commit).

## Dependencies and upgrades

The dependency direction is one way: `deepbook_predict_orders` → `deepbook_predict` → `deepbook_predict_math` → `fixed_math`, and the companion also depends on this library directly. The library depends on `fixed_math` and Pyth Lazer. Its `Move.toml` carries the same `[dep-replacements.mainnet]` entry for Pyth Lazer as Predict's, so both packages resolve one dependency graph on every network.

A package runs the dependency versions it linked when it was published. A library fix therefore reaches Predict only through a Predict upgrade that links the new library version, and the companion and Sessions relink with it ([architecture](../predict/docs/design/architecture.md#version-gating)). The library carries no version floor of its own. `LazerPrice` keeps its type identity across library upgrades, so a new constructor for a new Lazer format needs no Predict upgrade.

A library upgrade has the reach of a Predict upgrade: it could change what a fill is priced at, or build a `LazerPrice` that Pyth never signed. Its upgrade authority needs the same custody as Predict's.

## Build and test

From the repository root:

```sh
sui move build --path packages/predict_math --warnings-are-errors
sui move test --path packages/predict_math --gas-limit 100000000000 --package-size 64
sui move test --path packages/predict_math --build-env mainnet --gas-limit 100000000000 --package-size 64
```

The pricing math's behavioral tests stay in Predict, which calls it through its public pricing, fee, and admission paths. This package's own tests cover the Lazer decode and normalization and the order-ID decode.
