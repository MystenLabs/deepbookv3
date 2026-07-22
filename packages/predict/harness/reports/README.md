# nav-stress reports

Gas-scaling charts from the `nav-stress` harness strategy — measures the maximum leverage-book size
the on-chain NAV flush (`plp::value_expiry`) can value in one PTB.

## `navstress_gas.png`
From run `nav-stress-jun30-184711-22946` (single 1h market, low-leverage held book; run in progress).

- **Top — per-mint gas vs book size:** flat ~6.3M MIST (0.0063 SUI). Standalone mints are cheap and
  do NOT scale with the book — the old "100-mint PTB = 3-5B computation" was a *batching* artifact
  (100 public mints re-dirtying the same shared objects in one PTB), not per-mint scaling.
- **Bottom (log) — all ops vs book size:** the **flush** (NAV valuation) is the only op climbing
  toward the **5M-unit computation cap** (= 5e9 MIST @ RGP 1000). Linear ~1.07M MIST/order ⇒ OOG at
  **~4,650 orders (cheap branch)**, *below* the 5,000 per-market cap. Worst case **~1,372** via the
  near-ATM expensive `normal_cdf` branch. Liquidate is flat (~2.65M, bounded budget-24 scan).

**The computation cap is a protocol constant** (`max_gas_computation_bucket = 5,000,000` units on
testnet AND mainnet, verified via `getProtocolConfig`). The SUI cost differs by reference gas price
(testnet 5 SUI, mainnet 0.5 SUI), but the *work* cap — and thus the OOG book size — is
network-independent. `>30 SUI` txs are storage-heavy; the flush's NAV walk is pure computation.

Context: `packages/predict/predeploy/open-items.md` (`C-1`) and
`packages/predict/predeploy/evidence/c1-nav-stress-2026-06-30.md`.
