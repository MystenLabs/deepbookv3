# SVI Sigma Floor at 1e-7: Near-Vertex Accuracy and Monotonicity

**Item:** RP-5 (sigma floor) and P-35 · **Instrument:** scratch Move tests calling `deepbook_predict_math::math::digital` and `fixed_math::math::ln` on the DBU-1059 branch (sui 1.80.1), the SSVI true-math reference (`generate_ssvi_reference.py`), and Sui GraphQL reads of `ProtocolConfig` · **Date:** 2026-10-22

## What Was Measured

DBU-1059 lowers the pricing envelope's `sigma` floor from 1e-5 to 1e-7. That admits surfaces whose smile is only 100 raw units wide at 1e9. Three questions:
- How far is the contract's digital from true math near the smile vertex?
- Do such surfaces raise UP prices between neighbouring strikes, which would trip the active-book `ENonMonotonePrice` guard?
- Does the no-trade window keep these prices out of trades?

## Method

- **Surface.** The shape of backfill slice [0] from `generate_ssvi_reference.py`: `a = 4`, `b = 93_990`, `rho = 402_637` raw, roll ratio 1. `sigma` and `m` were varied:
  - 100 with `m = 0` (the new floor);
  - 10_000 with `m = 0` (the former floor);
  - 47_407 with `m = −19` (the slice as published).
- **Accuracy.** The three `surface_at_the_sigma_floor_*` tests in `pricing_exact_tests.move` printed the contract's price beside the reference and its budget. The reference and the budgets come from the generator, independent of the contract.
- **`k` error.** `fixed_math::math::ln(strike) − ln(forward)` at forward 66,875.41, for strikes ±$1 in $0.01 steps. Compared against Python `Decimal` `ln` at 50 digits.
- **Monotonicity.** Each ladder counted the neighbouring strikes where UP rises:
  - 1e-5 USD steps (the `market_tick_size_unit` minimum): 4,000 strikes up from forward 5,000. For the two larger sigmas, also 8,000 strikes starting 45 smile widths out.
  - $0.01 steps over ±$10 around a BTC forward.
  - $1 steps over ±$1,000 around a BTC forward.
- **No-trade window.** `no_trade_window_ms` on the Testnet (`0x422a45c3…`) and Mainnet (`0x5fa6efbe…`) `ProtocolConfig` objects.

## Results

Accuracy at the 1e-7 floor. Errors are contract minus reference, in raw units of 1e9 probability.

| Point | Reference | Error | Budget |
| --- | ---: | ---: | ---: |
| `floor_vertex`, one width below the vertex | 709,762,668 | −2,111,317 | 5,713,506 |
| `floor_vertex`, one width above the vertex | 289,973,971 | +2,113,268 | 5,713,514 |
| `floor_one_width`, vertex | 499,238,125 | +5,931,411 | 5,937,604 |
| `floor_one_width`, at the forward (`k = 0`, one width out) | 709,133,175 | +624,778 | 1,491,126 |
| `floor_wing`, vertex | 506,169,825 | −5,933,098 | 5,937,381 |
| `floor_wing`, at the forward (`k = 0`, ten widths out) | 208,327,503 | −291,297 | 304,527 |
| Every `d2 = ±1, ±2` point of the three slices | — | at most 881 in magnitude | 2,583–17,049 |

How to read the table:
- The vertex points are 1.19% relative.
- The ten-widths-out forward point is 0.14% relative.
- The forward points carry no `ln` error (`k` is exactly zero), so their error is the root's 1e9 floor and the rounding downstream of it.
- The unit-forward strikes next to 1.0 also carry `ln` error, because they sit across `ln`'s binade boundary at 1.0.

`k` error near the BTC forward, over ±$1 in $0.01 steps: −1.52 to +1.87 raw units.

Monotonicity:

| Ladder | `sigma` 100 | `sigma` 10,000 | `sigma` 47,407 |
| --- | --- | --- | --- |
| 1e-5 USD steps, 4,000 strikes up from the forward | 1 rise, 2,534 units (strike 5,000.02484, about 50 widths out) | 0 | 0 |
| 1e-5 USD steps, 8,000 strikes from 45 widths out | — | 2,705 rises, at most 57 units | 115 rises, at most 1 unit |
| $0.01 steps, ±$10 around 66,875.41 | 0 | 0 | 0 |
| $1 steps, ±$1,000 around 66,875 | 0 | 0 | 0 |

No-trade window: 10,000 ms on both Testnet and Mainnet. The contract default is 2,000 ms.

## Conclusions

- **Accuracy near the vertex.** At a 100-raw-unit smile width the digital is ill-conditioned there: it moves about 0.28 percentage points per raw unit of `k` or `m`.
  - The reference's near-vertex points carry two errors: the root's 1e9 floor, and `ln` error across the binade at 1.0. They are 0.21–0.59 percentage points off true math, past the ratified 0.1% contract-price ceiling.
  - The forward points carry the root alone. They are 0.03–0.06 percentage points off, up to 0.14% relative.
  - At a real strike, `k`'s measured error of up to about 2 raw units adds error of the same order as the vertex points.
  - The `d2 = ±1, ±2` points stay within 0.0001 of true math.
  - The former floor's slices stayed inside 0.1% at every point.
- **Monotonicity.** No ladder on the production admission grid raised a price at any sigma. That grid is $1, plus one reference tick on the $0.01 grid.
  - On a 1e-5 USD grid, wing rises appear at every sigma, so a grid that fine is P-35's problem with or without DBU-1059.
  - At 1e-7 those rises are rarer but larger: 2,534 units, against at most 57 at the former floor. A constant tolerance sized for the tail ripple would not cover them.
- **Valuation, not trades.** The provider reports `sigma` near 1e-5 only in the last 5–10 s, and both networks run a 10 s no-trade window. So the admitted surfaces reach the pool's valuation, not trades.
