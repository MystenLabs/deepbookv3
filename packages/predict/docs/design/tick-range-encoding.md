# Tick range encoding

This is the design record for how Predict represents strikes. It describes the
shipped `range_codec` / tick-keyed order encoding, why it has the shape it does,
and the one principle the whole protocol reads strikes by.

## The one-strike-interpretation principle

**Protocol-wide, a strike has exactly one representation: an absolute integer tick
from zero, with `raw_strike = tick * tick_size`.** There is no second strike
representation anywhere in Predict — no market-local centered grid, no
boundary-relative indices, no two competing forms carried side by side. Public
entrypoints and events carry the tick pair `(lower_tick, higher_tick)` directly;
order IDs, the payout tree, and the liquidation book all key on ticks; raw `u64`
strikes are recovered only at the pricing/settlement boundary. The one and only
place ticks are packed into a single integer is the durable order ID. The
`strike_exposure/range_codec` module is the single owner of the tick↔raw
conversion and the settlement prefix threshold.

Predict positions are range digitals: each order pays if the settlement price
lands in `(lower, higher]`. Before this design the protocol carried three strike
forms at once — raw strikes at the public API, grid-relative boundary indices in
the order ID, and raw strikes again as the payout-treap keys — with a market-local
centered grid as the converter. That centered origin existed solely to page the
dense NAV matrix; once the matrix was deleted (LP flows went async, see
[architecture](./architecture.md)), the origin carried no protocol meaning and
only forced every order decode through `min_strike + index * tick_size`. Collapsing
to one representation makes a misaligned strike *unrepresentable* rather than
runtime-rejected, and makes strike analytics feed-global (tick `i` means
`i * tick_size` for every market on a feed).

## Canonical representation

Each market snapshots a feed-specific `tick_size` at creation. A finite strike is
an absolute tick from zero:

```text
finite_strike = tick * tick_size
```

The tick domain is 24 bits (`constants::tick_bits!() == 24`):

```text
pos_inf_tick = (1 << 24) - 1        // = 16_777_215; also the u24 mask
```

Finite ticks occupy `1 .. pos_inf_tick - 1`. As the **lower** tick, `0` is the
negative-infinity sentinel; as the **higher** tick, `pos_inf_tick` is the
positive-infinity sentinel. Finite tick `0` is deliberately not a strike — Predict
prices positive strikes only, and a lower bound open to zero is the `-inf`
sentinel.

Entrypoints and events carry the pair as two `u64` values, `lower_tick` and
`higher_tick`. There is no standalone packed range key; the only packed form is
inside the durable order ID (below).

Valid range shapes:

| Shape | Encoding |
| --- | --- |
| Down range `(-inf, strike]` | `lower_tick = 0`, `higher_tick = strike_tick` |
| Up range `(strike, +inf]` | `lower_tick = strike_tick`, `higher_tick = pos_inf_tick` |
| Finite range `(low, high]` | `0 < lower_tick < higher_tick < pos_inf_tick` |

Invalid shapes (rejected by `order::assert_valid_order_shape` when the ticks become
an order ID): `lower_tick >= higher_tick`; the full outcome space
`lower_tick == 0 && higher_tick == pos_inf_tick`; and, for a leveraged order, any
two-sided range — a leveraged order must have `lower_tick == 0` or
`higher_tick == pos_inf_tick`. All shape and per-tick-domain validity is `order`'s
concern — the ticks are validated once, in `order::new`, where they become a
durable id. `range_codec` is purely a converter and re-checks none of it.

## The `range_codec` module

`range_codec` is **stateless** — every conversion takes the owning market's
`tick_size`. It owns two things:

- `strikes_from_ticks(lower_tick, higher_tick, tick_size) -> (lower, higher)` — the
  tick→raw conversion at the pricing/settlement boundary, mapping the sentinels
  (`lower_tick == 0 ⇒ neg_inf`, `higher_tick == pos_inf_tick ⇒ pos_inf`).
- `prefix_limit_tick(settlement, tick_size) -> u64` — the settlement prefix
  threshold (below).

Keeping the half-open settlement rule and the raw conversion in one module means
the payout tree, the liquidation book, and settlement all share one source of
truth for tick semantics.

## Packed order ID

The order ID keeps its full term set; the two strike fields are the two `u24`
ticks. Field layout (232 bits total, MSB→LSB):

```text
quantity_lots (u32) | floor_shares (u64) | opened_at_ms (u48)
  | lower_tick (u24) | higher_tick (u24) | sequence (u40)
```

The surrounding fields and their order are unchanged from the previous
boundary-index layout, so **liquidation priority is preserved**: the quantity field
stores its complement, so an ascending `u256` sort over raw order IDs is
largest-quantity-first, then by complemented floor shares, then opened-at, then tick
range, then sequence — the book never decodes a field. `Order` exposes
`lower_tick` / `higher_tick` accessors; callers needing raw strikes go through the
owning market's `tick_size`. Mint-admission policy (leverage tiers, price
thresholds) stays out of the ID — it is structural contract terms only, so a future
policy change can never invalidate an existing packed id.

The two `u24` tick fields encode the *same* absolute ticks as the entrypoint
arguments, the payout-tree keys, and the `OrderMinted` event, so an order's strike
range is bit-identical wherever it is read — a lossless round-trip, not a
re-derivation.

## Internal indexes

The sparse exposure indexes key on ticks internally:

- **`StrikePayoutTree`** keys finite boundary nodes by tick. Pricing needs raw
  strikes, so the tree converts a tick to a raw strike only when it calls the pricer
  (`tick * tick_size`); subtree summaries track min/max ticks, and the walk converts
  only the extreme ticks it prices.
- **Settlement liability** uses the threshold tick. Settlement prices are raw oracle
  prices and may not be tick-aligned; a boundary at tick `t` is active in the prefix
  walk iff `t * tick_size < settlement`. Equivalently, `prefix_limit_tick(settlement,
  tick_size) = ceil(settlement / tick_size)` (computed as `settlement.div_ceil(
  tick_size)`), and finite boundaries with `tick < prefix_limit_tick` are included.
  This preserves the half-open `(lower, higher]` payoff: settlement exactly equal to
  a higher boundary does not apply the end boundary, so the order still wins at
  `higher`. `prefix_limit_tick` can legitimately exceed `pos_inf_tick` (settlement
  above the whole encodable range), so it is a plain `u64` comparison bound and is
  **never** run through tick-domain validation.
- **`LiquidationBook`** stores only packed order IDs; it decodes the order's tick
  range and converts to raw strikes only for live pricing.

## Market creation and `tick_size`

Because the tick domain is absolute, market creation needs no live spot — there is
no grid to center. `create_expiry_market` snapshots the caller-chosen market
`tick_size` and creates the market with zero cash; `MarketCreated` emits `tick_size`, not
min/max strike. A market cannot admit risk until the normal live-pricing freshness
gates pass, so a market created against an unwarmed feed is simply unmintable, not
malformed.

`Registry` owns each Propbook underlying's minimum tick size; the concrete market
tick size is fixed when the market is created and must be that minimum or a 10x
multiple above it. Market creation validates that the tick size is positive, inside
the protocol bounds, and small enough that the maximum finite strike cannot overflow
`u64`:

```text
max_finite_strike = (pos_inf_tick - 1) * tick_size      // must fit in u64
tick_size <= u64::MAX / pos_inf_tick                     // the config bound
```

There is deliberately **no** on-chain check that `tick_size` matches the asset's
price scale — such a check would need a creation-time spot read, the exact coupling
this design removes. Sizing `tick_size` to the feed's price scale is an operational
responsibility, and a mismatch fails loud at the first mint: a too-small tick pushes
at-the-money strikes outside the 24-bit domain, so order-ID construction
(`order::new`) rejects them; a too-large tick only coarsens granularity.

The tick size trades resolution for range. Some reference points:

| tick_size | resolution | max encodable strike |
| --- | --- | --- |
| $0.00001 (min) | $0.00001 | ~$168 |
| $0.01 | $0.01 | ~$168k |
| $1 | $1 | ~$16.8M |
| $100 | $100 | ~$1.68B |

Choose `tick_size` so the cap clears any strike to be listed. The 24-bit domain
(~16.78M ticks) is effectively a permanent commitment: the order ID has no spare
bits adjacent to the two `u24` tick slots, so widening ticks later would mean
repacking the ID (an order-format change). Confirm 24 bits gives enough
simultaneous resolution-and-range for the most volatile intended feed before the
deploy freeze.

## Pricing tail behavior

The absolute tick domain admits a wider set of strikes than the old centered grid,
so the deep tails of the pricing curve must stay live rather than abort. There are
two distinct limits; only the first is a real product bound.

**Encoding cap — the bound to design around.** A finite strike cannot exceed
`(pos_inf_tick - 1) * tick_size`. This is a clean fail-at-range-construction, and
`tick_size` is the lever (table above). A strike past the cap, or below one tick, is
simply not encodable.

**Pricing-conditioning limit — saturated, effectively unreachable.** `compute_nd2`
computes `strike / forward` in 1e9 fixed point. Reaching either tail needs the
forward to leave the *entire* encodable strike ladder by orders of magnitude, at
which point the market is economically dead. Rather than abort there, the pricer
**saturates**, computing the ratio in `u128`:

- a ratio that floors to `0` (deep-ITM up tail, `strike << forward`) returns
  `float_scaling` — `P(settle > strike) ≈ 1`, the same value as the `neg_inf`
  sentinel branch;
- a ratio exceeding `u64::MAX` (deep-OTM up tail, `strike >> forward`) returns `0` —
  `P ≈ 0`, the `pos_inf` limit.

Saturation is cheap insurance, not a gating fix: the abort it replaces is
unreachable for a sanely-sized `tick_size`. It matters because the NAV walk prices
*every* live boundary and redeem / liquidation re-price already-minted orders with
no admission band — one unpriceable order would otherwise brick NAV, redeem, and
liquidation for the whole market until settlement. The `[min_ask, max_ask]`
admission band, not an abort, is what keeps the protocol from writing a tail it
prices poorly; a standalone reject-at-mint strike-range guard was rejected as
redundant on mint and absent on the no-band re-pricing paths.

## Events and SDKs

`OrderMinted` carries the strike range as the two absolute ticks `lower_tick` /
`higher_tick` — the canonical form, not a transition aid. The indexer reads the
range directly, without depending on the packed-order-ID bit layout and without
re-deriving raw strikes. No raw `lower_strike` / `higher_strike` are emitted: those
are pure display (`tick * tick_size`) an indexer derives from `MarketCreated`'s
`tick_size`, and the open-ended ends would otherwise re-introduce the raw `u64`
sentinels into the event. Later order events rely on `order_id` (the ticks are
embedded in the ID, and replacement IDs preserve them). `MarketCreated` emits
`tick_size` and no strike bounds.

SDKs own the user-facing routing: load the market or feed `tick_size`, convert raw
strike inputs to finite ticks (rejecting unaligned values by default — a silent
floor/ceiling changes the economics of `(lower, higher]`), and submit the `up`,
`down`, or finite range as the `(lower_tick, higher_tick)` pair. On-chain
entrypoints take the two ticks directly, so there is no packed range key to build.

## What this design does not own

The pure-pricer / live-resolver split (making `pricing.move` import no feed types)
is **not** part of this design. Tick-range needs only the tail saturation and the
tick↔raw conversion at the boundary; the shipped `pricing.move` remains a
read + gate + math module that constructs a value-typed `Pricer` from the live feeds
(it reads the propbook feeds, gates surface freshness, and exposes
`up_price` / `range_price`). Current Propbook binding, pre-expiry live-pricing
liveness, forward-selection, freshness, and the pricing-safe envelope live there. See
[architecture](./architecture.md) and [pricing and oracles](../concepts/pricing-and-oracles.md).
