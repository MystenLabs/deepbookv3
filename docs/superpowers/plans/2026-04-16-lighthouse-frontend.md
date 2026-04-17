# Lighthouse Frontend Implementation Plan

> **For agentic workers:** use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to implement this plan checkpoint-by-checkpoint. This revision intentionally removes stale code scaffolding and locks the architecture decisions that matter.

**Goal:** Ship Lighthouse as a shareable Next.js frontend on Vercel that lets a retail user zkLogin with Google, fund a testnet trading account, open a directional BTC position against DeepBook Predict, see MTM and lifecycle states, redeem on win, and supply/withdraw PLP.

**Deploy target:** `predict-testnet-4-16` contracts, a public `predict-server`, and direct Sui fullnode access for live chain reads.

## Critical Review And Corrections

The previous plan had four structural problems:

1. It treated deprecated JSON-RPC websocket event subscriptions as the primary live data path.
2. It mixed server-rendered data, raw on-chain reads, and UI-local derivations without a clear contract.
3. It assumed the frontend would build too much state out of low-level endpoints or direct object reads.
4. It pulled in extra client infrastructure (`@mysten/dapp-kit`, `@tanstack/react-query`) that is not needed for a zkLogin-first MVP.

This revised plan fixes that.

## Locked Architecture

### Read-path split

- **Public predict-server is the canonical render API** for all indexed or summarized protocol data:
  - oracles list and lifecycle state
  - predict config and enabled quote assets
  - manager summary and positions summary
  - vault summary and historical vault performance
  - portfolio PnL history
- **Browser-side Sui gRPC is the canonical live market-data path** for `OraclePricesUpdated` and `OracleSVIUpdated`.
- **Direct on-chain reads are allowed, but only for data that is inherently wallet-local or confirmation-critical**, such as:
  - current epoch for zkLogin session TTL
  - wallet USDsui / PLP balances
  - transaction confirmation and digest follow-up

### Sui access

- Use `@mysten/sui/grpc` and `SuiGrpcClient`.
- Do **not** use `suix_subscribeEvent`.
- Do **not** make JSON-RPC websocket a dependency of the MVP architecture.
- The live stream should use `SubscriptionService.SubscribeCheckpoints`, filter predict-package oracle events client-side, and reconnect from the last processed cursor.

### Frontend stack

- Keep: Next.js 15, TypeScript, Tailwind, SWR, Zustand, `@mysten/sui`, `@mysten/zklogin`, `lightweight-charts`, Vitest, Playwright.
- Remove from MVP plan: `@mysten/dapp-kit`, `@tanstack/react-query`.

## Required Public Server Contract

These routes are the contract the frontend should target. Existing routes can be expanded, but the frontend should not depend on ad hoc raw-event stitching for its main screens.

### Existing routes to keep and use

- `GET /predicts/:predict_id/state`
- `GET /oracles/:oracle_id/state`
- `GET /managers?owner=0x...`
- `GET /status`

### Existing routes that should be expanded

- `GET /oracles` or preferably `GET /predicts/:predict_id/oracles`
  - Must include `predict_id`, `underlying`, `min_strike`, `tick_size`, and lifecycle fields.
  - The frontend should not infer strike bounds or tick size from unrelated sources.

### New routes to add

- `GET /predicts/:predict_id/oracles`
  - Predict-scoped oracle list for expiry chips and trade-page boot.
- `GET /managers/:manager_id/summary`
  - Trading balance, redeemable balance, open exposure, realized PnL, unrealized PnL, account value.
- `GET /managers/:manager_id/positions/summary`
  - Aggregated rows per `(oracle_id, strike, side)` with qty, cost basis, status, outcome, latest known mark metadata.
- `GET /predicts/:predict_id/vault/summary`
  - TVL, PLP price, utilization, available liquidity, open exposure, fees, composition.
- `GET /predicts/:predict_id/vault/performance?range=1D|1W|1M|3M|ALL`
  - Time series for PLP value / vault performance chart.
- `GET /managers/:manager_id/pnl?range=1D|1W|1M|3M|ALL`
  - Portfolio PnL series.

### Optional convenience route

- `GET /owners/:owner/manager`
  - Nice-to-have if the frontend repeatedly resolves owner -> manager and you want a cleaner API than `/managers?owner=`.

## Target App Shape

New app under `apps/lighthouse/`.

```text
apps/lighthouse/
├── app/
│   ├── layout.tsx
│   ├── page.tsx
│   ├── trade/page.tsx
│   ├── vault/page.tsx
│   ├── portfolio/page.tsx
│   ├── signin/page.tsx
│   └── api/
│       ├── zklogin/salt/route.ts
│       ├── zklogin/prove/route.ts
│       ├── tx/sponsor/route.ts
│       └── faucet/mint/route.ts
├── components/
│   ├── nav/
│   ├── trade/
│   ├── vault/
│   ├── portfolio/
│   └── common/
├── lib/
│   ├── api/predict-server.ts
│   ├── config.ts
│   ├── formatters.ts
│   ├── pricing/
│   ├── sui/client.ts
│   ├── sui/checkpoints.ts
│   ├── sui/read.ts
│   ├── sui/ptb.ts
│   └── zklogin/
├── store/
│   └── trade.ts
└── tests/
    ├── unit/
    └── e2e/
```

## Checkpoint 0 — Bootstrap And Config

**Gate:** `apps/lighthouse` builds and boots locally.

- [ ] Register `apps/*` in `pnpm-workspace.yaml`.
- [ ] Bootstrap the Next.js app under `apps/lighthouse`.
- [ ] Install only the MVP dependencies.
- [ ] Add typed env config.
- [ ] Replace `NEXT_PUBLIC_SUI_WS_URL` with `NEXT_PUBLIC_SUI_GRPC_URL`.
- [ ] Keep `NEXT_PUBLIC_SUI_RPC_URL` only if a non-gRPC client is still truly required; otherwise remove it.

**Env contract**

- `NEXT_PUBLIC_SUI_NETWORK=testnet`
- `NEXT_PUBLIC_SUI_GRPC_URL=https://fullnode.testnet.sui.io:443`
- `NEXT_PUBLIC_PREDICT_SERVER_URL=...`
- `NEXT_PUBLIC_PREDICT_PACKAGE_ID=...`
- `NEXT_PUBLIC_PREDICT_REGISTRY_ID=...`
- `NEXT_PUBLIC_PREDICT_ID=...`
- `NEXT_PUBLIC_USDSUI_TYPE=...`
- zkLogin + server-side sponsor/faucet secrets

## Checkpoint 1 — Core Libs

**Gate:** pure utilities and data clients are in place and unit-tested.

- [ ] Implement pricing primitives from the existing `charts_btc.html` math:
  - SVI -> UP/DOWN digital price
  - utilization-aware spread application
- [ ] Implement formatters and countdown helpers.
- [ ] Add `lib/sui/client.ts` as a thin `SuiGrpcClient` singleton.
- [ ] Add `lib/sui/read.ts` for direct chain reads that are allowed in the browser:
  - current epoch
  - wallet USDsui balance
  - wallet PLP balance
  - transaction wait helpers
- [ ] Add `lib/api/predict-server.ts` against the **server contract above**, not against raw placeholder endpoints.
- [ ] Add typed models for:
  - predict state
  - oracle summary
  - oracle state
  - manager summary
  - positions summary
  - vault summary
  - vault performance series
  - pnl series

## Checkpoint 2 — zkLogin, Sponsor, Faucet

**Gate:** a fresh user can sign in, mint testnet USDsui, and submit sponsored transactions.

- [ ] Implement zkLogin salt/prove routes.
- [ ] Implement session storage and expiry handling.
- [ ] Implement sponsor route around the zkLogin signature flow.
- [ ] Implement faucet route for testnet USDsui.
- [ ] Build the nav wallet/session menu without introducing a wallet adapter dependency.

## Checkpoint 3 — Live Market Data Pipeline

**Gate:** the app can seed a selected oracle from the public server, then keep it live from the Sui checkpoint stream.

- [ ] Implement `lib/sui/checkpoints.ts`.
- [ ] Subscribe with `SuiGrpcClient.subscriptionService.subscribeCheckpoints(...)`.
- [ ] Narrow the stream with a read mask so the browser only receives fields needed to inspect checkpoint events.
- [ ] Filter events client-side down to:
  - `OraclePricesUpdated`
  - `OracleSVIUpdated`
  - selected `oracle_id`
- [ ] Track the last processed cursor and reconnect from it on stream drop.
- [ ] If the live stream goes stale beyond a threshold, refetch `GET /oracles/:oracle_id/state` and resubscribe.
- [ ] Keep quote freshness and stream freshness separate:
  - quote TTL drives the ring
  - stream reconnect logic drives stale-state recovery

**Important:** do not make the trade page depend on the stream for first paint. First paint comes from the public server.

## Checkpoint 4 — Trade Page

**Gate:** `/trade` renders from real data and can submit a real buy.

- [ ] Build the page around this load order:
  1. `GET /predicts/:predict_id/state`
  2. `GET /predicts/:predict_id/oracles`
  3. `GET /oracles/:selected_oracle_id/state`
  4. resolve manager via `/managers?owner=`
  5. if manager exists, `GET /managers/:manager_id/summary`
- [ ] Render expiry chips from predict-scoped oracle data.
- [ ] Seed the selected oracle’s latest price/SVI/ask-bounds from `/oracles/:id/state`.
- [ ] Switch to live updates from the checkpoint stream once mounted.
- [ ] Compute the quote client-side from:
  - latest spot
  - latest forward
  - latest SVI params
  - time to expiry
  - pricing config from `/predicts/:predict_id/state`
  - vault utilization from `/predicts/:predict_id/vault/summary`
- [ ] Keep the strike wheel and chart fully client-side.
- [ ] Submit `mint_position` through the sponsored tx path.

## Checkpoint 5 — Positions And Lifecycle

**Gate:** positions table and lifecycle banners work without client-side raw-event reconstruction.

- [ ] Add `GET /managers/:manager_id/positions/summary` to the server if missing.
- [ ] Render the positions table from this summary endpoint.
- [ ] Use oracle lifecycle from `/predicts/:predict_id/oracles` plus `/oracles/:id/state`.
- [ ] Use direct chain reads only for tx confirmation after Sell or Redeem.
- [ ] Awaiting-settlement and settled states must render cleanly even if the live market stream is paused.

## Checkpoint 6 — Vault

**Gate:** `/vault` is server-first and only falls back to direct chain reads for wallet-local balances.

- [ ] Add or wire `GET /predicts/:predict_id/vault/summary`.
- [ ] Add or wire `GET /predicts/:predict_id/vault/performance?range=...`.
- [ ] Render vault hero, metrics, composition, and performance from the public server.
- [ ] Use direct chain reads only for:
  - user wallet USDsui balance
  - user PLP coin balance
- [ ] Submit supply/withdraw through the sponsored tx path.

**Do not** rebuild vault metrics in the browser from raw predict object fields for the main UI path.

## Checkpoint 7 — Portfolio

**Gate:** `/portfolio` shows meaningful account value and PnL without placeholder math.

- [ ] Add or wire `GET /managers/:manager_id/summary`.
- [ ] Add or wire `GET /managers/:manager_id/pnl?range=...`.
- [ ] Render:
  - account value
  - realized / unrealized / total PnL
  - pnl chart
  - trading balance
- [ ] Use direct chain reads only for wallet-local balance lanes in the transfer card.
- [ ] Keep transfer flows sponsored and manager-aware.

## Checkpoint 8 — Integration And E2E

**Gate:** the app works against the public server and fullnode, not local mock data.

- [ ] Write Playwright smoke tests for:
  - unauthenticated redirect behavior
  - trade page initial render
  - expiry switching
  - quote movement under live stream
  - buy flow
  - vault render and supply flow
  - portfolio render and transfer flow
- [ ] Verify stale-stream recovery by forcing a stream reconnect and confirming UI recovery from server seed + resumed cursor.
- [ ] Verify behavior against the actual cloud `predict-server` URL you deploy in parallel.

## What The Frontend Should Not Do

- Do not use JSON-RPC websocket subscriptions as the primary live feed.
- Do not derive vault analytics in the browser from raw chain objects for the main UI.
- Do not stitch the entire positions table out of `/positions/minted` and `/positions/redeemed` on the client if a summary endpoint exists.
- Do not make the user wait for live gRPC events before the first trade page render.
- Do not add wallet-connect infrastructure to support a future mode that this MVP is not shipping.

## Verification Checklist

- [ ] Trade page first paint comes from the public server.
- [ ] Live oracle quote updates come from Sui gRPC checkpoint streaming.
- [ ] Stream reconnect uses cursor resume semantics.
- [ ] Wallet-local values come from direct chain reads, not the predict indexer.
- [ ] Positions, vault, and portfolio screens all render from frontend-oriented summary endpoints.
- [ ] The UI stays usable if the live stream drops temporarily.

## Notes For Parallel Backend Work

The user is deploying the cloud indexer/server in parallel. Frontend work should therefore:

- target the server contract above from day one
- avoid inventing temporary client-side derivations that will later be deleted
- accept mock responses only where the public server route is not deployed yet

If a route is missing, add it to `crates/predict-server` rather than pushing more business logic into the client.
