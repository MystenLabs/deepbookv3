# Predict live-simulations (testnet)

A real random-trade integration harness that drives the **already-deployed testnet**
predict stack. Sibling to `../simulations` (the localnet/Python parity harness) — but where
that one publishes its own packages, mints DUSDC, and pushes its own oracle updates, this one:

- targets the live testnet package ids (read from the `deploy/deployment.testnet.json` files),
- uses the **deployer's real DUSDC** (split from the largest owned coin), and
- relies on the **live propbook price-pusher** for fresh Pyth + Block Scholes feeds (no oracle writes here).

It acts as the deployer's canonical account, then runs a randomized loop of `mint` /
`redeem` / LP `supply` around the live spot, recording per-action gas. It is an end-to-end
integration test: it exercises the real account framework (auth + AccumulatorRoot `0xacc`),
the oracle, and the pool.

## Run

```bash
cd packages/predict/live-simulations
pnpm install   # or npm install
ITERATIONS=16 pnpm sim
```

Env: `ITERATIONS` (default 16), `RPC_URL` (default testnet fullnode), `SUI_KEYSTORE`
(default `~/.sui/sui_config/sui.keystore`). The signer is the deployer recorded in the
predict deployment json; its key must be in the keystore.

Outputs: `state.testnet.json` (persisted wrapper id + funded flag, so re-runs reuse the
account) and `results.testnet.json` (per-action gas min/avg/max + success counts).

## Scope / limitations

- **No withdraw / no flush.** LP shares (PLP) are delivered to the account only at a
  privileged pool flush (cron: `plp::start_pool_valuation` → `value_expiry` → `finish_flush`),
  which this sim does not drive — so `request_withdraw` is omitted (it would have no PLP to pull).
  `supply` escrows DUSDC into the queue; the PLP fill lands at the next flush.
- Strikes are chosen within ~±1.5% of the live ATM tick to stay inside the market's
  creation-centered grid; out-of-grid / under-backed mints are recorded as failures, not retried.
- Leverage is fixed at 1x (no floor); extend `sim.ts` for leverage tiers.
