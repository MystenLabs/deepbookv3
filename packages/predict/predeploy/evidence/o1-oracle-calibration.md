# Near-Expiry Oracle Calibration Finding

**Item:** O-1 · **Instrument:** offline + on-chain calibration study · **Date:** 2026-06-21

Status: confirmed offline and on-chain on 2026-06-21.

Severity: High if near-expiry markets are enabled without recalibration.

Scope: near-expiry markets only, observed with time-to-expiry below 15 minutes on
5-minute BTC up/down markets. Longer-dated markets were not tested by this
finding.

## Finding

Predict's binary-option oracle, built from Pyth spot plus the Block Scholes/SVI
surface, was miscalibrated near expiry. A contract priced by the oracle at
probability `p` did not win `p` of the time. Realized outcomes were more extreme
than the oracle's probabilities:

- high-priced contracts, roughly `p = 0.60..0.95`, were underpriced and won more
  often than priced;
- low-priced contracts, roughly `p = 0.05..0.40`, were overpriced and won less
  often than priced.

The signature is consistent with implied volatility being too high near expiry:
the surface priced in more uncertainty than the final minutes actually carried.

## Evidence

Offline reliability over 577 distinct expiries:

| Oracle price | Realized win frequency | Gap |
| --- | --- | --- |
| 0.30 | 0.202 | -0.098 |
| 0.50 | 0.458 | -0.042 |
| 0.70 | 0.760 | +0.060 |
| 0.85 | 0.927 | +0.077 |
| 0.93 | 0.972 | +0.047 |

Exploit rule: buy oracle-priced contracts in `[0.60, 0.95)` and hold to
settlement.

Bootstrapped per-expiry PnL:

- +0.050 per contract at 0% fee
- +0.040 per contract at 1% fee
- +0.030 per contract at 2% fee

On-chain confirmation across 5 fresh deployments / 25 markets / 149 settled
positions:

- exploit arm `[0.60, 0.95)`: +0.141 notional, 70/74 wins;
- control arm `[0.05, 0.40)`: -0.124 notional, 7/75 wins;
- off-chain reference price matched the on-chain oracle to about 1e-3.

## Recommendation

Recalibrate the near-expiry volatility surface. Candidate fixes include a
near-expiry volatility floor/decay change or a time-to-expiry treatment that does
not overstate short-dated implied variance.

After any fix, rerun the reliability framework and require the near-expiry curve
to collapse onto the diagonal before enabling the affected market shape.

## Reproduction Outline

1. Capture Propbook events per expiry: Pyth `RawSpot` plus BS surface data.
2. Build the engine CSVs: `oracles.csv`, `oracle_prices.csv`,
   `oracle_svi.csv`.
3. Run the calibration verifier with cluster bootstrap by expiry.
4. Render the reliability chart and compare realized win frequency to oracle
   price buckets.

The original scratch implementation generalized the existing single-expiry
oracle-accuracy harness to many expiries.

## Related Bug

The live BS feed chained-getter helper `u64FromReturn` in the sandbox
measurement path mis-indexed `returnValues`. Check any live oracle parity or
collector code that still imports that helper.
