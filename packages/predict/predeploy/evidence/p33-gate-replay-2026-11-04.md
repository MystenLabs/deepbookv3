# P-33: SVI Decimals Gate Replay and Predict Package Size

**Item:** P-33 · **Instrument:** an integer Python port of `deepbook_predict_math::math::raw_var_ok` and `var_positive` and of the 18-decimal checks in `pricing::chk_inputs` (DBU-1152), run over Propbook's stored SVI rows; a floating-point SVI digital for price sensitivity; `sui move build` (sui 1.80.1) and Sui GraphQL reads of Predict's live linkage tables · **Date:** 2026-11-04

## What Was Measured

- How often the minimum-variance load gate refuses final-seconds slices at 1e9 and at 18 decimals.
- How far half a raw unit of 1e9 rounding moves a digital price: in `a` and `b`, which 18 decimals removes, and in `rho`, `m`, and `sigma`, which it keeps.
- Whether a Predict version from before the decimals would price an 18-decimal row it reads as 1e9.
- Predict's package size against Sui's 102,400-byte limit.

## Method

- **Data.** Every one-second bucket of the last 75 s before every one-minute expiry on Saturday 2026-10-31 UTC, on both networks: Testnet SSVI and Mainnet SVI, as Propbook stored them at 1e9. 197,342 rows; the gate table counts each SVI publication once per expiry.
- **Gate at 1e9.** `raw_var_ok(a, b, rho, sigma)` with integer `mul_down`, `sqrt_down`, and `smile_inner`, as on main.
- **Gate at 18 decimals.** `var_positive` at 1e18 on the snapshot's rounded tuple, the stored values times 1e9. That equals Predict's half-up rounding of an 18-decimal row when the provider rounds at 1e9. SSVI's `a = theta·(1 − rho²)/2` is never negative and its `b` is positive, so its full-precision minimum variance is positive whenever the rounded one is.
- **Price sensitivity.** The UP digital at strikes 0, ±0.33, and ±0.5 standard deviations of the ATM total variance, with each parameter moved by half a raw unit at 1e9 and the worst sign combination taken. SSVI `a` was kept non-negative. Every seventh slice.
- **Pre-decimals reader.** Each row scaled by 1e9, as an 18-decimal row, checked against main's `inputs_ok` and `narrow_input`.
- **Package size.** Sui's `MovePackage::size()`: 8, plus module bytes and names, plus 32 bytes and the module and type names per type origin, plus 72 bytes per linkage entry. Linkage counted on the live packages: Testnet Predict v8 (`0x7fc9677d…`) has 11 entries and Mainnet Predict v4 (`0x98235c58…`) has 13. Both include `0x1` and `0x2`, and Mainnet's Circle USDC brings two more dependencies. A localnet publish of `a87ad26d` failed with `MovePackageTooBig { object_size: 102539 }`, the 11-entry figure.

## Results

Share of slices the load gate refuses:

| Network, model | Published before expiry | Slices | 1e9 gate | 18-decimal gate |
|---|---|---|---|---|
| Testnet SSVI | 0–10 s | 13,123 | 81.2% | 0% |
| Testnet SSVI | 10–20 s | 13,127 | 26.8% | 0% |
| Testnet SSVI | 20–30 s | 13,134 | 3.9% | 0% |
| Testnet SSVI | 30–60 s | 39,338 | 0.1% | 0% |
| Mainnet SVI | 0–10 s | 13,191 | 58.1% | 0% |
| Mainnet SVI | 10–20 s | 13,181 | 3.5% | 0% |
| Mainnet SVI | 20–30 s | 13,195 | 0.1% | 0% |
| Mainnet SVI | 30–60 s | 39,563 | 0% | 0% |

The 18-decimal column checks the rounded tuple. For Mainnet SVI's negative-`a` slices the full-precision check depends on digits the 1e9 rows do not carry; there a slice is refused only if its true minimum variance is not positive.

Worst-case price move from half a raw unit of rounding, Testnet SSVI, in cents per $1 contract:

| Published before expiry | `a`, `b`: median | `a`, `b`: p99 | `a`, `b`: max | `rho`, `m`, `sigma`: max |
|---|---|---|---|---|
| 0–10 s | 6.3 | 18.8 | 21.0 | 0.004 |
| 10–20 s | 0.9 | 9.0 | 13.4 | 0.0014 |
| 20–30 s | 0.3 | 4.8 | 8.3 | 0.0009 |

Pre-decimals reader: all 197,342 rows, read 1e9 times too large, fail `inputs_ok` on both `rho` (at most 1e9 raw) and `sigma` (at most 100e9 raw), so the load aborts `EBlockScholesInputsInvalid`, or `EBlockScholesInputTooWide` for a value past `u64`, before any price. Passing would need |rho| below 1e-9 with `sigma`, `b`, and |m| all at most 1e-7.

Predict package size, in bytes:

| Build | Before linkage | 11 entries (Testnet, localnet) | 13 entries (Mainnet) |
|---|---|---|---|
| `a87ad26d`: decimals | 101,747 | 102,539 | 102,683 |
| `d0322b41`: 57 internal function names shortened | 101,199 | 101,991 | 102,135 |
