# Predict

Predict is an expiry-based prediction market protocol on Sui.

For app engineers, the important model is:

- `Predict` is the shared protocol object. It holds vault balances, pricing config, risk config, quote-asset allowlist, oracle strike grids, and the PLP LP token treasury cap.
- `PredictManager` is the per-user account object. It holds a user's quote balances plus their position and range quantities.
- `OracleSVI` is the market state for one underlying and one expiry. It carries spot, forward, SVI params, activation status, and settlement price.
- `Position` and `Range` are not standalone objects. They are quantities stored inside a `PredictManager`, keyed by `MarketKey` and `RangeKey`.
- `PLP` is the LP share token minted when users supply collateral to the vault.

This README is an integration quickstart and concepts guide, not an operator runbook.

## Current Testnet Deployment

Use these as the current public integration targets:

- Public server: `https://predict-server.testnet.mystenlabs.com`
- Predict package: `0xf5ea2b3749c65d6e56507cc35388719aadb28f9cab873696a2f8687f5c785138`
- Predict object: `0xc8736204d12f0a7277c86388a68bf8a194b0a14c5538ad13f22cbd8e2a38028a`
- Current quote asset: `e95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC`

If you have old testnet package IDs in configs or scripts, ignore them. The package above is the current deployment.

## Integration Model

In practice, an app should use three read paths:

1. Public `predict-server` for indexed and render-ready data.
2. Sui checkpoint/event streaming for low-latency oracle updates.
3. Direct on-chain object reads for confirmation-critical state.

That split matters:

- Use the server to render lists, history, portfolio summaries, vault summaries, and current oracle state.
- Use live Sui subscriptions if you want second-level oracle freshness in the UI.
- Use direct on-chain reads right before or right after a transaction if you need authoritative object state for a wallet flow.

Do not build the UI by decoding raw Move events everywhere. The public server already gives you the useful indexed surface.

## Core Concepts

### Predict

`Predict` is the top-level shared object. It:

- accepts quote assets
- prices trades from oracle state plus vault exposure
- tracks vault balances and liabilities
- mints and burns `PLP`
- owns protocol pricing, risk, and withdrawal-limiter config

Most frontend pages should treat `Predict` as the market root.

### PredictManager

Each user creates one `PredictManager` and reuses it.

It holds:

- deposited quote balances
- long binary position quantities
- vertical range quantities

Important: positions and ranges are internal balances, not NFTs. If you are looking for "the position object", there is none. Read them from the manager object or from the indexed server surface.

### OracleSVI

Each oracle represents one underlying and one expiry. In the current setup that is BTC with rolling expiries.

An oracle carries:

- `spot`
- `forward`
- SVI parameters `a`, `b`, `rho`, `m`, `sigma`
- `expiry`
- lifecycle state

Lifecycle:

1. created
2. activated
3. updated with live prices and SVI
4. settled at expiry
5. compacted in the vault after settlement

Settlement freezes the settlement spot on-chain. Compaction does not delete history; it shrinks the vault-side exposure state for that oracle into constant-size settled state.

### Positions and Ranges

Predict supports:

- directional binary positions keyed by `(oracle_id, expiry, strike, is_up)`
- vertical ranges keyed by `(oracle_id, expiry, lower_strike, higher_strike)`

Positions and ranges both live inside `PredictManager`.

### PLP

LPs supply an accepted quote asset and receive `PLP` shares. `PLP` represents a proportional claim on the vault value, subject to vault utilization and withdrawal constraints.

## Data Sources

### 1. Public Server

Start here for almost everything:

- `GET /status`
- `GET /predicts/:predict_id/state`
- `GET /predicts/:predict_id/oracles`
- `GET /oracles/:oracle_id/state`
- `GET /predicts/:predict_id/vault/summary`
- `GET /predicts/:predict_id/vault/performance?range=ALL`
- `GET /managers`
- `GET /managers/:manager_id/summary`
- `GET /managers/:manager_id/positions/summary`
- `GET /managers/:manager_id/pnl?range=ALL`

History endpoints:

- `GET /oracles/:oracle_id/prices`
- `GET /oracles/:oracle_id/prices/latest`
- `GET /oracles/:oracle_id/svi`
- `GET /oracles/:oracle_id/svi/latest`
- `GET /positions/minted`
- `GET /positions/redeemed`
- `GET /ranges/minted`
- `GET /ranges/redeemed`
- `GET /lp/supplies`
- `GET /lp/withdrawals`
- `GET /trades/:oracle_id`

Useful config endpoints:

- `GET /predicts/:predict_id/quote-assets`
- `GET /predicts/:predict_id/state`
- `GET /oracles/:oracle_id/ask-bounds`

Examples:

```bash
curl https://predict-server.testnet.mystenlabs.com/status

curl https://predict-server.testnet.mystenlabs.com/predicts/0xc8736204d12f0a7277c86388a68bf8a194b0a14c5538ad13f22cbd8e2a38028a/oracles

curl https://predict-server.testnet.mystenlabs.com/oracles/0x3e9f34bb73cbcd2780296407221a0119063008aad5fb11a03769104426c3e819/state
```

Recommended page-level usage:

- trade page: `predict state` + `predict oracles` + `oracle state`
- vault page: `vault summary` + `vault performance`
- portfolio page: `manager summary` + `positions summary` + `pnl`

### 2. Live Sui Stream

Use Sui checkpoint/event streaming if you want live oracle tape in the browser.

Watch for:

- `oracle::OraclePricesUpdated`
- `oracle::OracleSVIUpdated`
- `oracle::OracleSettled`
- `oracle::OracleActivated`

Use the current package ID when filtering:

- `0xf5ea2b3749c65d6e56507cc35388719aadb28f9cab873696a2f8687f5c785138`

This path is for freshness, not for historical pagination. Use the server for history.

### 3. Direct On-Chain Reads

Use direct object reads when a wallet flow needs the current on-chain state of:

- the user's `PredictManager`
- the target `OracleSVI`
- a quote coin the user is about to spend
- transaction results after submit

Do not use direct chain reads as your primary list/query backend. It is slower, harder to paginate, and unnecessary for most UI rendering.

## Quickstart

### 1. Render current market state

Start from the public server:

1. fetch `GET /predicts/:predict_id/state`
2. fetch `GET /predicts/:predict_id/oracles`
3. pick an active oracle
4. fetch `GET /oracles/:oracle_id/state`

That gives you:

- quote assets
- active oracle list
- strike grid metadata
- latest spot/forward
- latest SVI
- oracle lifecycle state

### 2. Create or find a manager

Users need a `PredictManager` before they can trade.

- existing managers: `GET /managers` or filter by owner
- on-chain creation entrypoint: `predict::create_manager`

The resulting `manager_id` is the user's trading account for future deposits, mints, redeems, and range trades.

### 3. Fund the manager

Users typically:

1. acquire the enabled quote asset
2. deposit that quote asset into their `PredictManager`
3. mint or redeem against that manager

The manager deposit flow is implemented on-chain in `predict_manager::deposit`.

### 4. Build transactions with generated bindings

Use `@mysten/codegen` as the default integration path for:

- Move type parsing
- typed object decoding
- PTB helpers
- generated call targets

Do not hand-roll BCS parsing or scatter raw string targets like `package::module::function` throughout the app unless you have to.

For Predict specifically, generated bindings are the right default for:

- `predict::create_manager`
- `predict::mint`
- `predict::redeem`
- `predict::mint_range`
- `predict::redeem_range`
- `predict::supply`
- `predict::withdraw`

### 5. Confirm on-chain state, then refresh from the server

After submit:

1. wait for transaction confirmation
2. refresh the directly affected on-chain objects if needed
3. refresh the indexed server endpoints that back the current page

The server is low-lag, but not zero-lag. Do not assume it updates in the same instant as the transaction response.

## Transaction Flows

### Create manager

Entry point:

- `predict::create_manager`

Inputs:

- no existing manager object required

Output:

- a new shared `PredictManager`

### Mint a directional position

Entry point:

- `predict::mint<Quote>`

Inputs:

- `Predict`
- `PredictManager`
- `OracleSVI`
- `MarketKey`
- `quantity`
- `Clock`

Behavior:

- debits quote balance from the manager
- increases long quantity for that `MarketKey`
- emits `PositionMinted`

### Redeem a directional position

Entry points:

- `predict::redeem<Quote>`
- `predict::redeem_permissionless<Quote>` for settled positions

Behavior:

- decreases manager quantity
- pays out quote asset into the manager
- emits `PositionRedeemed`

### Mint a range

Entry point:

- `predict::mint_range<Quote>`

Inputs:

- `Predict`
- `PredictManager`
- `OracleSVI`
- `RangeKey`
- `quantity`
- `Clock`

Behavior:

- debits quote from the manager
- increases range quantity
- emits `RangeMinted`

### Redeem a range

Entry point:

- `predict::redeem_range<Quote>`

Behavior:

- decreases range quantity
- pays out quote asset into the manager
- emits `RangeRedeemed`

### Supply liquidity

Entry point:

- `predict::supply<Quote>`

Behavior:

- transfers quote into the vault
- mints `PLP`
- emits `Supplied`

### Withdraw liquidity

Entry point:

- `predict::withdraw<Quote>`

Behavior:

- burns `PLP`
- returns quote from the vault
- emits `Withdrawn`

## Oracle Lifecycle

This matters because tradeability depends on oracle state.

### Before expiry

- oracle must be active
- live prices can update frequently
- SVI updates come less frequently than prices
- mints and normal redeems quote from current oracle state

### At expiry

The oracle settles when the feed pushes the first post-expiry price update. That update freezes the settlement spot and emits `OracleSettled`.

### After settlement

- settled positions and ranges can be redeemed
- no further live price or SVI updates are accepted
- the vault can compact the settled oracle into constant-size settled state

Compaction is an internal storage optimization for the protocol. Integrators should still use indexed history and server endpoints for settled markets.

## Common Integration Pitfalls

- Do not assume positions are separate objects. They live inside `PredictManager`.
- Do not render from raw chain scans if the public server already has the data.
- Do not mix old testnet package IDs with the current package.
- Do not assume server lag is zero immediately after a transaction.
- Do not assume SVI updates are as frequent as price updates.
- Do not assume an oracle is tradeable just because it exists. Check its status.

## Minimal Checklist

- use the current package ID
- use the public server as the default render backend
- create one `PredictManager` per user
- use `@mysten/codegen` for parsing and PTB building
- refresh both transaction state and indexed server state after writes
- treat oracle lifecycle state as part of the trading UX

## Source Pointers

- core shared object: [sources/predict.move](./sources/predict.move)
- manager account model: [sources/predict_manager.move](./sources/predict_manager.move)
- registry and admin entrypoints: [sources/registry.move](./sources/registry.move)
- oracle state machine: [sources/oracle.move](./sources/oracle.move)
- vault accounting: [sources/vault/vault.move](./sources/vault/vault.move)
- example operator scripts: [../../scripts/transactions/predict](../../scripts/transactions/predict)
