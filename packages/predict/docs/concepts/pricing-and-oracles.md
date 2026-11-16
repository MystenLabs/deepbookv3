# Pricing and oracles

Predict prices its range digitals (binary options) off signed Pyth Lazer and Block Scholes data and turns them into the probabilities that drive queued fills, settlement, and net asset value (NAV). The transaction that needs a price carries the signed data inline, and Predict checks it against the underlying's oracle binding on `ProtocolConfig`. This document describes that data and the binding, how a range probability is derived from the SVI parameters, how each flow picks the instant it prices at, and which module owns each check.

## Signed oracle data

Since package version 6, no Predict transaction reads a Propbook object, as decided 2026-11-16 in the design doc. A caller passes the observations a flow needs as typed values that only the [`deepbook_predict_math`](../../../predict_math/README.md) library builds, and only from updates their provider's on-chain verifier accepted earlier in the same transaction: Pyth's Lazer verifier for a price, and the `bs_oracle` signature verifier, whose batch types only it can mint, for Block Scholes values. The relayer that lands an update is untrusted, and so is the keeper that passes the values on.

| Value | Built by | What it carries |
| --- | --- | --- |
| `LazerPrice` | `lazer_price::from_update(update, feed_id)` | One Lazer feed's price normalized to 1e9, the feed id, the channel, the envelope time, and the price's generation time, both in microseconds |
| `BsVol` | `block_scholes::vols` or `block_scholes::vol_at`, over verified value and SVI updates | For one expiry, a Block Scholes spot and forward stamped at one source time (`value_ms`), and an SVI tuple stamped at its own (`svi_ms`), with the base asset, SVI model, and decimals they were decoded under |
| `BsSpot` | `block_scholes::spot_at`, over verified value updates | A Block Scholes spot and its source time |

The generation time is when Pyth produced the price, which is not always when the envelope carrying it was published: when Pyth has no new aggregate it carries the previous price forward under a newer envelope. Every flow checks both. The Block Scholes series ids are derived through the provider-owned `bs_sid` package from the base asset, the expiry, and for SVI the model and decimals, the same ids Propbook's stores accepted, so a decode reads exactly the series it names.

### The oracle binding

Each underlying's binding names the data that prices, settles, and values its markets. `protocol_config::set_oracle_binding` sets it, admin-gated, as a dynamic field on `ProtocolConfig` keyed by the Propbook underlying id, and emits `OracleBindingUpdated`. `protocol_config::oracle_binding` reads it.

| Field | Meaning |
| --- | --- |
| `lazer_feed_id` | The Pyth Lazer feed of the underlying's spot |
| `lazer_channel` | The fixed-rate Lazer channel settlement, the reference tick, and the flush read, `2` (50 ms) or `3` (200 ms). A queued order keeps the channel it was placed on |
| `block_scholes_base_asset` | The provider's base-asset spelling for the spot, forward, and SVI series |
| `svi_model`, `svi_decimals` | The SVI series the provider signs for the underlying, and the decimals it signs them at, `9` or `18` |

Creating a market requires a binding (`EOracleBindingMissing`), and every flow that takes signed data checks it against the binding that is current when it runs. A new binding therefore also applies to orders already waiting, so it is changed under a mint pause. Propbook remains a separate package: Predict still links it because its version 5 signatures name Propbook types, and those entry points now abort `EUseV2` or, for placement, ignore the Propbook arguments.

### SVI parameters

The SVI curve is described by five stochastic-volatility-inspired parameters, signed source-native (`u128` magnitude-plus-sign) and narrowed to Predict's pricing widths where the `Pricer` is built:

| Param | Pricing type | Role in `w(k)` |
| --- | --- | --- |
| `a` | `I64` (signed) | Added directly to total variance |
| `b` | `u64` | Scales the wing term |
| `rho` | `I64` (signed) | Multiplies `(k − m)` inside the wing term |
| `m` | `I64` (signed) | Subtracted from `k` (smile center offset) |
| `sigma` | `u64` | Enters under the square root with `(k − m)²` |

`a`, `rho`, and `m` are signed because the baseline variance, wing tilt, and smile-center offset can each point either direction. `b` and `sigma` remain unsigned. `I64` is the signed fixed-point type from the shared `fixed_math` package, a magnitude-plus-sign type with normalized zero. (The "Role" column describes each parameter's place in the variance formula below. The standard raw-SVI reading, `a` baseline variance, `b` wing slope, `rho` skew, `m` horizontal shift, `sigma` curvature, is consistent with it.) A `BsVol` keeps `a` and `b` at 1e18 exactly as signed and rounds `rho`, `m`, and `sigma` half up to 1e9.

## From SVI to a range probability

A Predict range contract pays a fixed notional if the asset's settlement price lands inside a strike interval. Its fair value is therefore the probability of that event read off the distribution the SVI curve encodes — the defining identity of an undiscounted digital, whose price per unit notional equals the risk-neutral probability of its payout event.

`Pricer.range_price(lower, higher)` returns a `RangePrice` containing both finite boundary UP probabilities. Its `probability()` getter returns the combined range probability; `lower_up()` and `higher_up()` return `None` only for infinite boundaries. Mint and live-close terms retain this pricing result for per-boundary fees.

The derivation, conceptually:

1. **Forward and SVI.** Take the forward `F`, the signed spot re-anchored on the Block Scholes basis (see [Queued orders](#queued-orders)), and roll the raw SVI tuple from its source time to the remaining time-to-expiry at the pricing instant (see below).
2. **Total variance at a strike.** For a strike `K`, compute log-moneyness `k = ln(K / F)`, then evaluate the SVI total-variance function `w(k) = a + b·(rho·(k − m) + sqrt((k − m)² + sigma²))`. This expresses the smile as variance: how much dispersion is priced at that moneyness.
3. **One-sided (UP) tail probability.** Convert `(k, w)` into the option-pricing distance `d2 = −((k + w/2) / sqrt(w))`, then apply the SVI strike-skew adjustment to the digital price: `up_price(K) = clamp01(N(d2) − phi(d2)·w'(k)/(2·sqrt(w)))`, where `w'(k) = b·(rho + (k − m)/sqrt((k − m)² + sigma²))`. This is the smile-aware probability the settlement price ends **at or above** `K` — the price of a one-sided "UP" claim struck at `K`, i.e. a cash-or-nothing digital call.
4. **Range probability by differencing.** The probability of landing in the half-open interval `(lower, higher]` is the difference between the two one-sided digital prices, floored at zero so fixed-point dust or a clamped/non-monotone segment of the adjusted digital cannot abort a live quote. Block Scholes guarantees its published SVI surfaces are monotone and butterfly-arbitrage-free; Predict retains the active-book NAV guard as defense in depth (response policy RP-15):

       range_probability = max(up_price(lower) − up_price(higher), 0)

   the value of a contract that pays out only inside the range — a digital call spread — expressed as a 1e9-scaled probability.

The endpoints carry sentinel handling so open-ended ranges work without special-casing: a strike equal to `neg_inf` (the raw value `0`) has UP price `1.0` (the whole distribution is above it), and a strike equal to `pos_inf` (`u64::MAX`) has UP price `0`. A one-sided contract is the difference against the appropriate sentinel.

### SVI remaining-time roll-down

The provider's SVI `a` and `b` values describe variance over the horizon identified by the tuple's signed `svi_timestamp`. Let `T_source` be that time (`svi_ms`), `T_expiry` the market expiry, and `t` the pricing instant: the committed tick for a fill, and the price's instant for a flush mark. Before evaluating any strike, Predict derives:

    remaining_ms = T_expiry - t
    anchor_tte_ms = T_expiry - T_source
    a_eff_1e18 = sign(a) × floor(abs(a_1e18) × remaining_ms / anchor_tte_ms)
    b_eff_1e18 = floor(b_1e18 × remaining_ms / anchor_tte_ms)

`a_1e18` and `b_1e18` are the tuple's `a` and `b` at 1e18: the signed values exactly when the binding's SVI decimals are 18, or the 9-decimal values times `1e9`. The multiplications use `u256` intermediates and produce 1e18-scaled `u128` magnitudes. Both magnitudes round down, so signed `a` rounds toward zero. `rho`, `m`, and `sigma` are copied unchanged. At the source anchor the tuple is unchanged at 1e18 precision. As `t` advances, `a_eff` and `b_eff` decrease. A commit refuses an SVI tuple more than 120 seconds older than the order's τ, and nothing prices at or after expiry.

The raw tuple must pass Predict's pricing envelope before roll-down. If fixed-point flooring makes the effective per-strike total variance non-positive before expiry, the tuple builds no pricer, which refunds a fill and aborts a flush mark. This policy addresses the age of an unchanged variance-to-expiry tuple; it does not claim that the provider's near-expiry calibration is accurate.

### Price tails

Because strikes are absolute integer ticks against a forward that can drift far outside the encodable strike ladder (see [markets and positions](./markets-and-positions.md)), the UP-price math must stay live in both deep tails rather than aborting. Log-moneyness is therefore taken as a **difference of logarithms**, `k = ln(strike) - ln(forward)`, never as `ln` of a fixed-point ratio: forming `strike * 1e9 / forward` first floors the quotient to zero below a ratio of `1e-9` and past `u64` above `1.8e10`, destroying exactly the tails it is being asked about. `ln` is defined across the whole positive `u64` domain, so the difference stays well-conditioned over every representable pair (`|k| <= 44.4`).

Both tails still converge on their limits — `P(settle > strike) -> 1` deep-ITM and `-> 0` deep-OTM — but they are **computed**, reached through `d2`'s normal-CDF clamp, rather than asserted by a branch on the ratio. That distinction is load-bearing: the digital limits are exact only while total variance is small, so a branch returning them without reading the surface is wrong on a high-variance one, in either direction (`predeploy/response-policies.md` RP-26). The range-price differencing is still saturating, so a thin or far-OTM range with ~0 true probability and a 1-ulp fixed-point inversion prices `0` rather than aborting a legitimate trade.

Most of the math runs in 1e9 fixed point. The remaining-time roll-down is the exception: it produces `a_eff` and `b_eff` at `u128`/1e18 with `u256` intermediates, and total variance remains at 1e18 through the integer square-root input. `sqrt(w)` and `d2` return at 1e9 for the rest of the formula. Carrying the rolled values in the wider domain avoids discarding most of the signal on a short-dated surface — a five-minute market's total variance is only about ten raw units at 1e9, and `d2` is ill-conditioned in it. The smile root `sqrt((k − m)² + sigma²)` takes the same route: both squares are exact `u128` products at 1e18 and the root returns at 1e9. Squaring at 1e9 leaves `sigma²` a few raw units for one-minute SSVI slices, whose `sigma` reaches 4.7e-5 with the smile's vertex at the money, and floors it to zero below about 3.2e-5. Everything outside those islands — log-moneyness, the rest of the SVI geometry, the smile-slope correction, and the normal CDF/PDF — stays at 1e9. The signed intermediates use the `fixed_math` `I64` type (`rho`, `m`, `k`, `k − m`, `d2`) and guard the real preconditions: positive forward, non-negative SVI wing term, and positive total variance. The read-time envelope puts no bound on `a` of its own, in sign or magnitude, beyond the provider's `u64` width. It checks only that the raw analytical minimum variance `a + b·sigma·sqrt(1 − rho²)` is positive: at 1e9 with its floors for a 9-decimal binding. For an 18-decimal binding every parameter rounds half up to 1e9 for the snapshot and the envelope, which keeps enough digits for `rho`, `m`, and `sigma`, and the check runs at 1e18, where the increment is not floored to a raw unit, so a final-seconds SSVI slice whose `a` rounds to zero still shows its positive minimum. It runs on both forms of the tuple: the 1e18 `a` and `b` a fill or flush prices with, and the snapshot's rounded ones, so every committed snapshot can also price on its own before roll-down. That rejects source surfaces whose signed baseline over-offsets the SVI wing before any mint, redeem, or NAV path can divide by `sqrt(w)`. The deep `ENonPositiveVariance` check remains the effective per-strike backstop, including when remaining-time roll-down floors a valid raw surface to non-positive variance before expiry.

For single order/range quotes, range-price differencing is saturating: if a clamped or non-monotone adjusted digital segment would make `up_price(lower) < up_price(higher)`, that order prices at zero rather than aborting the trade path. NAV valuation has an additional active-book check. The payout-tree walk prices finite boundaries in ascending tick order and compares each UP price with the lowest one seen so far. A rise within `pricing::price_monotonicity_tolerance` (2 raw units at 1e9) is treated as the pricer's own fixed-point dust: on a tail plateau `N(d2)` and the skew correction floor independently, so adjacent strikes step up by a raw unit on a valid surface, and every rise measured on the committed surfaces is exactly that one unit. The walk keeps the quoted price, charges the rise (rounded up) on the quantity ending at that boundary, and continues, so the mark never understates the per-order liability beyond boundary rounding and overstates it by at most the rise times that quantity, rounded up. A larger rise is treated as a non-monotone surface — a genuinely arbitrageable one, or a valid one so close to the butterfly-arbitrage boundary that the pricer's rounding no longer keeps up — and the walk aborts with `strike_payout_tree::ENonMonotonePrice` instead of netting it into an overstated `current_nav` (response policy RP-15).

> The full closed-form SVI and normal-CDF/PDF implementation, including the fixed-point `ln`, `sqrt_down`, `normal_cdf`, and `normal_pdf` helpers, lives in the `pricing` and `fixed_math` modules. The formulas above are the model, not a reproduction of every rounding step.

## Live pricing, retired

Up to package version 5, quotes, valuation reads, and the flush loaded a live `Pricer` from the newest stored observations, under freshness windows and the `use_pyth_spot_for_forward` selector. Since version 6, no transaction can build one: `load_live_pricer`, `current_nav`, `live_order_value`, the `quote_mint` family, and `quote_close` keep their signatures and abort `EUseV2`. Every price now comes from signed data stamped at a stated instant:

| Flow | Instant | Inputs |
| --- | --- | --- |
| Queued fill (`commit_v2`, then `try_fill`) | The order's committed tick | `LazerPrice` at τ or its backup tick, and a `BsVol` at τ's slots |
| Settlement (`try_settle_v2`) | Expiry | `LazerPrice` at expiry, or after the grace a `BsSpot` at expiry |
| Reference tick (`set_reference_tick_v2`) | The period start, `reference_tick_source_timestamp_ms` | `LazerPrice` at that time |
| Flush mark (`plp::snapshot_expiry_pricer_v2`) | The price's instant, within the flush window | `LazerPrice` and a `BsVol` both stamped at that instant |

Each `Pricer` is built the same way: `forward = spot × bs_forward / bs_spot`, the Block Scholes basis re-anchored on the signed Lazer spot, with the SVI tuple rolled down to the pricing instant. The selector and the Pyth and SVI freshness windows remain in `PricingConfig`, and no version 6 path reads them. The flush window reads `block_scholes_price_freshness_ms`.

## Queued orders

A queued mint or early sell is priced at its committed tick rather than at the clock of any transaction (see [delayed execution](./delayed-execution.md)). Placement reads no oracle. Admission records only the binding's Lazer feed in the order's receipt (`VolSnapshot`), and every price input arrives at commit.

- **The spot.** Commit attaches Pyth's verified price for the order's τ as a `LazerPrice`. Predict accepts it only for the order's feed and channel, stamped at τ or one channel tick later, generated at or after τ, with its envelope at or before the clock, and pricing-safe (`EWrongPrice`).
- **The Block Scholes inputs.** Commit also attaches a `BsVol`. Which slots an order takes is the companion's rule (see [delayed execution](./delayed-execution.md#commit)): by default the spot and forward stamped at the 500 ms boundary at or before `τ − 500 ms` and the SVI at the 1,000 ms boundary at or before `τ − 1,000 ms`, so both were published before τ. Predict accepts the inputs only under the market's binding (base asset, SVI model, and decimals) and for its expiry, with both source times at or before τ and at most 120 seconds before it (`EWrongVol`), and copies them into the receipt.

A fill rebuilds a `Pricer` from the two: `forward = committed_spot × bs_forward / bs_spot`, and the SVI tuple rolled down to the committed tick by the remaining-time rule above. The snapshot stores `a` and `b` at 1e9 because its layout is fixed, so when the binding's decimals are 18 the commit also records the full-precision tuple in the market's SVI cache, a dynamic field `pricing` keeps on the market's UID (`SviKey`): a map from SVI source time to tuple holding the last 64 its commits recorded. A source time that arrives with a second, different tuple is held by neither, so every order on it prices from its own 1e9 values. The fill prices the entry for the snapshot's SVI source time when it is the snapshot's whole calibration, its `a` and `b` rounding to the snapshot's and its `rho`, `m`, and `sigma` equal to them, and otherwise the snapshot's 1e9 values. An order fills or refunds by its deadline, a few seconds after its τ, so an entry normally outlives every order on it.

The rebuild never aborts. It yields no pricer at or past expiry, on a zero forward, outside the pricing envelope, or when the rolled surface's minimum total variance is not positive, and the order is then refunded with reason 10 (`constants::fill_reason_no_vol!()`) and its order fee returned. Range prices at the tick use non-aborting forms of the digital prices, so a surface that would abort a quote refunds the order instead of aborting the fill. For a mint, commit also prices the order at the tick without subsidy and caps the subsidy it reserves at that quote's trading fee and the order's budget.

A rebuilt pricer never leaves the Predict function that built it, so a stored snapshot cannot price anything else ([RP-32](../../predeploy/response-policies.md#rp-32-the-flushs-stored-mark-cannot-reach-a-trade-path--pricer-is-non-store-frozenpricer-is-flush-only)). The SVI evaluation, the roll-down, the pricing-safe input checks, and the minimum-variance check are pure functions in the `deepbook_predict_math` library. Predict calls them and keeps every abort and error code.

## Ownership: binding checks vs. pricing

Resolving a price touches three facts, *does this signed data belong to this market's binding and expiry*, *is it stamped at the instant this flow prices at*, and *does it price*, and they are owned by different modules:

- **`protocol_config` owns the binding** and the package-level checks every flow uses against it: a `LazerPrice` on the binding's feed and channel at an exact envelope with at most 2 seconds of carry (`constants::max_settlement_carry_ms!()`), and a `BsVol` or `BsSpot` under the binding's base asset, model, and decimals.
- **`expiry_market` and `plp` own the flow.** Each decides which instant the flow prices at (τ, expiry, the period start, or the flush window), asks the binding checks, and aborts or returns without settling when they fail.
- **`pricing` owns the `Pricer`.** It builds the receipt snapshot from a `BsVol` and builds a `Pricer` from a snapshot and a spot at an instant, returning none outside the pricing-safe envelope.

## Freshness and price bounds

Signed data carries its own timestamps, so freshness is a property of the instant each flow names, not of a stored row:

- **Committed orders.** The Lazer price is stamped at τ or the backup tick. The Block Scholes inputs are at or before τ and at most 120 seconds older (`constants::max_svi_max_age_ms!()`).
- **Settlement and the reference tick.** The Lazer envelope is exactly the named time, and the price was generated at most 2 seconds before it.
- **The flush.** Each market's instant is at or before the flush start and at most `block_scholes_price_freshness_ms` before it (2 seconds by default, admin-tunable).

**Pricing envelope (Predict, not the provider).** Predict's `pricing` module decides whether the combined Block Scholes inputs are safe for Predict's fixed-point pricing math: `spot > 0`, `forward > 0`, bounded basis, `b <= 100`, `|m| <= 100`, `|rho| <= 1`, `1e-7 <= sigma <= 100`, and positive analytical minimum total variance. `a` has no bound of its own: any value of either sign is accepted when that minimum-variance condition holds, because only total variance has to be positive. The `sigma` floor is low because surfaces narrow `sigma` toward expiry, and pool valuation still prices the last seconds before expiry.

**No oracle writes during pool valuation.** The flush computes NAV against a frozen snapshot, so Predict's valuation lock blocks most admin changes mid-valuation, and trades are refused only inside the atomic snapshot transaction (see [liquidity and NAV](./liquidity-and-nav.md)). The flush operator is trusted to pass each market's data at an instant inside the window.

**Min/max entry probability bounds.** Mint admission at the tick requires the range probability and each finite leg's probability to lie within `[min_entry_probability, max_entry_probability]`. The lower leg uses ABOVE probability and the upper leg uses BELOW probability. Infinite sentinels are exempt. `StrikeExposureConfig` owns these snapshotted bounds: the template's at creation, or a narrower band the lifecycle-cap holder requested when it created the market. Pricing still produces probabilities for valuation and closes outside the entry band. Fees do not move a probability into eligibility. See [configuration](../design/configuration.md) for the bound values.

## Settlement

Terminal settlement records the signed price at exactly the market expiry. The market stores no settlement sample before expiry. Permissionless `expiry_market::try_settle_v2(market, config, price, spot, clock)` settles from `price`, a `LazerPrice` on the binding's feed and channel whose envelope is exactly the expiry and whose generation is at most 2 seconds before it. If no such price is passed and at least 30 seconds have elapsed since expiry (`constants::settlement_fallback_grace_ms!()`), it settles from `spot`, a Block Scholes spot of the binding's base asset stamped exactly at expiry.

Pyth is the exclusive source before `expiry + 30_000` and remains preferred afterward within one call. Once either source qualifies, `try_settle_v2` passes its price to `StrikeExposure::set_settled`, which records the terminal price and exact remaining payout liability together, and `MarketSettled.settlement_source` reports `0` for Pyth or `1` for Block Scholes. If neither qualifies, it returns false and the market remains unsettled. Settled redeem and the pool sweep consume only recorded state, and past-expiry valuation still aborts rather than substituting an approximate mark.

Both observations are exact: there is no latest, nearest, rounded, interpolated, or at-or-after fallback. Every supported cadence is a multiple of the 60-second resolution, so each expiry is a whole minute that every fixed-rate Lazer channel and the Block Scholes value grid land on. After the grace period the first valid transaction is final: a Block Scholes settlement may land before a transaction carrying the Pyth price. The trust and liveness consequences are documented in [risks](../risks.md).

For the trust assumptions behind each source and the privileged flush operator, see [risks](../risks.md).
