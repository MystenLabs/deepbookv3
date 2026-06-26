# Predict — Testnet Deployment & Integration Guide

This folder is the source of truth for the **current Predict testnet deployment**.

- **`deployment.testnet.json`** — every package ID, shared-object ID, asset/oracle
  feed ID, and wiring parameter of the live deployment. Always read IDs from this
  file; the tables below are a human-readable mirror and may lag.
- **`deploy.ts`** — the deploy/wiring script that produced the JSON.

> **If you integrated against the `predict-testnet-4-16` deployment, read
> [§4 Migrating from 4-16](#4-migrating-from-the-predict-testnet-4-16-deployment) first.**
> Everything changed: all IDs were redeployed, custody moved to a new `account`
> package, and the oracle moved into its own packages. Your old transactions will
> not build against the new types.

Chain: `testnet` (chainId `4c78adac`). Settlement coin: **DUSDC** (6 decimals).
Prices/probabilities are 1e9 fixed-point (`FLOAT_SCALING = 1_000_000_000`).

---

## 1. Deployment IDs (current)

> Verbatim from `deployment.testnet.json` (`updatedAt` 2026-06-25). Re-read the JSON
> before building — never hardcode from memory.

### Packages
| Package | ID |
|---|---|
| `predict` | `0xdb3ef5a5129920e59c9b2ae25a77eddb48acd0e1c6307b97073f0e076016446e` |
| `propbook` (oracle registry + feeds API) | `0x8eb2adde1c91f8b7c9ba5e9b0a32bfb804510c342939c5f77458fd8143f9755b` |
| `block_scholes_oracle` | `0x8192932b70d5946217d0f09aad44f84ad5c27ee4c1ca31b09f46200fbd31d3de` |
| `account` (custody) | `0xb9389eac8d59170ffd1427c1a66e5c8306263464fcc6615e825c1f5b3e15da3b` |
| `fixed_math` | `0x6930d8eff504f15e45e7ceec3d504bfc1a6f1e1d4c02babe03c156f77b84523d` |

### Shared objects (pass these into transactions)
| Object | ID |
|---|---|
| `predict::protocol_config::ProtocolConfig` | `0x2325224629b4bd96d1f1d7ee937e07f8a06f861018a130bbb26db09cb0394cb6` |
| `predict::plp::PoolVault` | `0xfde98c636eb8a7aba59c3a238cfee6b576b7118d1e5ffa2952876c4b270a3a2a` |
| `predict::registry::Registry` | `0x54afbf245caf42466cedb5756ed7816f34f544afdfa13579a862eccf3afa21ca` |
| `propbook::registry::OracleRegistry` | `0xf3deaff68cbd081a35ec21653af6f671d2ad5f012f3b4d817d81752843374136` |
| `account::account_registry::AccountRegistry` | `0x3c54d5b8b6bca376fc289121838ad02f8a5b3843242b9ad7e8f8245720e685a2` |

### Framework / coins
| Thing | Value |
|---|---|
| `Clock` | `0x6` |
| `AccumulatorRoot` (fund settlement) | `0x0000000000000000000000000000000000000000000000000000000000000acc` |
| DUSDC coin type | `0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC` |
| PLP share coin type | `0xdb3ef5a5129920e59c9b2ae25a77eddb48acd0e1c6307b97073f0e076016446e::plp::PLP` |

### Asset `BTC_USD` (the only listed asset)
| Field | Value |
|---|---|
| `propbookUnderlyingId` | `1` |
| Pyth feed (`PythFeed`) | `0xc78d7de16217d46d21b92ae475da799448be30b71a758dc6d7bb3ac2f1c35afb` |
| BS spot feed (`BlockScholesSpotFeed`) | `0xcdc5fa7364e60fd2504aa96f65b707dc0734e507a919b1a7d7d63164fd67b745` |
| BS forward feed (`BlockScholesForwardFeed`) | `0xe72c734ea8d8dcbc9183d9d8f96f51aaa1fb5034d5ed33ac60d67d261e15b48a` |
| BS SVI feed (`BlockScholesSVIFeed`) | `0xdc2f8270676bd05fb28491e8d4a41a495722fda7a454926dd66dbba256a21c69` |

### Cadences (each produces a rolling series of per-expiry `ExpiryMarket`s)
| id | name | tick size | admission tick | window |
|---|---|---|---|---|
| 0 | `1m` | 1e9 | 1e10 | 3 |
| 1 | `5m` | 1e9 | 1e10 | 3 |
| 2 | `1h` | 1e9 | 1e10 | 3 |

Individual `ExpiryMarket` objects are **created on a schedule**, not fixed — discover
them from the indexer (see [§6](#6-discovery--indexer)).

---

## 2. Architecture (what the objects are)

Predict sells **European cash-or-nothing range digitals** on an asset. A position is
an `Order` over a `[lower_tick, higher_tick)` strike range on a specific
`ExpiryMarket`; payout is backed by the `PoolVault` (PLP LPs supply the backing).

The integration spans **four packages**:

- **`account`** — generic custody. Each owner has one `AccountWrapper` (a shared
  object at a *derived, deterministic* address). It holds per-coin balances and
  is the thing every Predict flow debits/credits. Authorization is an `Auth`
  hot-potato (owner-signed, or app-delegated). Funds settle through the framework
  `AccumulatorRoot`.
- **`propbook` + `block_scholes_oracle`** — the oracle. `OracleRegistry` binds an
  underlying id to its canonical `PythFeed` + Block-Scholes `spot/forward/SVI`
  feeds. Pricing reads all four.
- **`predict`** — the protocol. `ProtocolConfig` (global gates), `PoolVault` (LP
  backing + supply/withdraw queues), `Registry` (market creation + caps), and the
  per-expiry `ExpiryMarket`s where mint/redeem/liquidate happen.

A **`Pricer`** is a PTB-local pricing snapshot: build it once per transaction from
the market + the four oracle feeds, then pass it into mint/redeem/liquidate/NAV
calls in the **same** transaction.

---

## 3. Integration recipes

All flows are composable `public fun`s (no `entry`). Build them as PTBs. Argument
order below is exact (verified against source at this revision). `<…>` = an ID from
§1; `market` = a discovered `ExpiryMarket` id.

### 3.0 One-time: create & fund an account (`account` package)

```
// create your wrapper (deterministic per owner; do once, then it's shared)
wrapper = account::account_registry::new(<AccountRegistry>, ctx)   // returns AccountWrapper
account::account::share(wrapper)

// owner authorization — generate per transaction that moves your funds
auth = account::account::generate_auth(ctx)                        // owner = tx sender

// deposit DUSDC into your account (folds settle → auth → deposit)
account::account::deposit_funds<DUSDC>(wrapper, auth, dusdc_coin, <AccumulatorRoot>, <Clock>)
```

`generate_auth` ties the `Auth` to the tx sender; the wrapper must be the sender's
derived wrapper. `withdraw_funds<T>(wrapper, auth, amount, root, clock, ctx)` pulls
funds back out. `account_registry::derived_wrapper_address(registry, owner)` /
`derived_wrapper_exists(...)` let you find/check a wrapper without creating one.

### 3.1 Build the Pricer (required for live mint/redeem/liquidate)

```
pricer = predict::expiry_market::load_live_pricer(
    market,                  // &ExpiryMarket
    <ProtocolConfig>,
    <OracleRegistry>,        // propbook registry
    <PythFeed>,              // asset.pyth
    <BlockScholesSpotFeed>,  // asset.bs_spot
    <BlockScholesForwardFeed>,// asset.bs_forward
    <BlockScholesSVIFeed>,   // asset.bs_svi
    <Clock>,
)   // returns Pricer (PTB-local; aborts if feeds stale or past expiry)
```

### 3.2 Mint a position

```
order_id = predict::expiry_market::mint_exact_quantity(
    market, wrapper, auth, <ProtocolConfig>, pricer,
    lower_tick, higher_tick,   // u64 raw tick indices on the market grid
    quantity,                  // u64 contracts (DUSDC 6dp units of max payout)
    leverage,                  // u64 1e9-scaled; 1e9 == 1x (no floor)
    max_cost,                  // u64 slippage: caps ALL-IN withdrawal (net_premium + fee + builder_fee + EWMA penalty)
    max_probability,           // u64 1e9-scaled: caps quoted per-contract probability before fees
    <AccumulatorRoot>, <Clock>, ctx,
)   // returns u256 order_id
```

Budget-sized alternative — spend up to `amount`, fees on top, abort below
`min_quantity`:

```
order_id = predict::expiry_market::mint_exact_amount(
    market, wrapper, auth, <ProtocolConfig>, pricer,
    lower_tick, higher_tick, amount, min_quantity, leverage,
    <AccumulatorRoot>, <Clock>, ctx,
)
```

### 3.3 Redeem (close) a position

```
// live market — priced close, partial or full. Returns (closed_id, Some(replacement_id) if partial).
(closed, replacement) = predict::expiry_market::redeem_live(
    market, wrapper, auth, <ProtocolConfig>, pricer,
    order_id, close_quantity, <AccumulatorRoot>, <Clock>, ctx,
)

// settled market — permissionless, full close only, no Auth, no Pricer.
(closed, _none) = predict::expiry_market::redeem_settled(
    market, <AccountRegistry>, wrapper, <ProtocolConfig>,
    <OracleRegistry>, <PythFeed>,
    order_id, close_quantity, <AccumulatorRoot>, <Clock>, ctx,
)
```

### 3.4 LP: supply / withdraw backing capital

```
// queue a supply of `amount` DUSDC; filled at the next flush (NAV-priced). Returns queue index.
idx = predict::plp::request_supply(<PoolVault>, wrapper, auth, <ProtocolConfig>, amount, <AccumulatorRoot>, <Clock>, ctx)

// queue a withdraw of `amount` PLP shares; filled at the next flush.
idx = predict::plp::request_withdraw(<PoolVault>, wrapper, auth, <ProtocolConfig>, amount, <AccumulatorRoot>, <Clock>, ctx)

// cancel a still-pending request before the flush (refunds escrow into your account)
predict::plp::cancel_supply_request(<PoolVault>, wrapper, auth, <ProtocolConfig>, idx, <AccumulatorRoot>, <Clock>, ctx)
predict::plp::cancel_withdraw_request(<PoolVault>, wrapper, auth, <ProtocolConfig>, idx, <AccumulatorRoot>, <Clock>, ctx)
```

Supply/withdraw are **asynchronous**: they queue, and a privileged keeper flush
fills them at a single NAV mark. Filled DUSDC/PLP is delivered to your account via
the accumulator (auto-settled on your next account-touching call).

### 3.5 Keeper / permissionless

- `predict::expiry_market::liquidate(market, <ProtocolConfig>, pricer, budget)` — one
  bounded liquidation pass over underwater leveraged orders; returns count.
- `predict::expiry_market::liquidate_order(market, <ProtocolConfig>, pricer, order_id)` — try one.
- `redeem_settled` (above) is permissionless once a market is settled.

---

## 4. Migrating from the `predict-testnet-4-16` deployment

The 4-16 build had **no `deployment/` folder, no `account` package, and the oracle
inside `predict`**. Treat this as a rewrite of your integration layer, not an ID
swap. Concretely:

1. **Swap every ID.** All packages were redeployed and all shared objects recreated
   — see §1. Nothing from 4-16 is reusable.

2. **Custody moved to the `account` package (biggest break).**
   - *Old (4-16):* a predict-side `PredictManager` plus predict caps/proofs
     (`PredictTradeCap` / `DepositCap` / `WithdrawCap` / `PredictTradeProof`). Trades
     took the manager + a cap/proof.
   - *New:* `account::AccountWrapper` + `account::Auth`. **Every** mint / redeem /
     supply / withdraw now takes `wrapper: &mut AccountWrapper, auth: Auth` and a
     `root: &AccumulatorRoot`. The predict manager and all predict-side trade/deposit/
     withdraw caps are **gone**. Create a wrapper and fund it via the `account`
     package (§3.0); deposit/withdraw DUSDC there, not through predict.

3. **Oracle extracted into `propbook` + `block_scholes_oracle`.**
   - *Old:* `oracle.move` / `oracle_config.move` lived inside `predict`; a single
     oracle object was passed to trades.
   - *New:* pricing needs **four** feed objects (`PythFeed`, `BlockScholesSpotFeed`,
     `BlockScholesForwardFeed`, `BlockScholesSVIFeed`) bound via
     `propbook::OracleRegistry`. You no longer pass an oracle to mint directly — you
     build a `Pricer` with `expiry_market::load_live_pricer(...)` (§3.1) and pass that.

4. **Module/entry layout changed.** `predict.move` → flows now live in
   **`expiry_market.move`** (`mint_exact_quantity`, `mint_exact_amount`,
   `redeem_live`, `redeem_settled`, `liquidate`). `predict_manager.move` →
   **`predict_account.move`** (predict-side account state). Update every
   `target` string accordingly.

5. **Market model is per-expiry cadence markets.** Positions live on `ExpiryMarket`
   objects produced by cadences (`1m`/`5m`/`1h`), discovered from the indexer (§6),
   not a single static market. Order IDs are packed `u256`.

6. **New required args on the hot path:** `&AccumulatorRoot` (fund settlement) and a
   per-PTB `&Pricer`. Mint slippage is now `max_cost` + `max_probability` (or
   `min_quantity` for the budget variant). See §3.2 for exact semantics.

Rewire checklist: (a) point all IDs at §1; (b) replace manager+caps with
wrapper+auth and add `AccumulatorRoot`; (c) add the `load_live_pricer` step and pass
`Pricer`; (d) update module/function names per #4; (e) re-derive tick/quantity/
leverage units against the cadence grid (§1).

---

## 5. Caveats (read before going live)

- **Oracle freshness aborts.** `load_live_pricer` (and thus mint/redeem_live) aborts
  if any feed is stale or the market is past expiry (`EBlockScholesPriceStale`,
  `EBlockScholesSVIStale`, `EPythSpotInvalid`, `ELivePricingExpired`, …). Always pass
  the **current** feed objects from the `OracleRegistry`; the registry binding is
  asserted, so a wrong/old feed id aborts (`EWrongPythFeed`, etc.).
- **Pause & valuation gates.** `ProtocolConfig` has a global `trading_paused` (blocks
  new risk) and a `valuation_in_progress` lock (blocks supply/withdraw/redeem_settled
  during a flush). Per-market `mint_paused` blocks new mints on one expiry. Expect and
  handle these aborts.
- **Version gating.** Every flow calls `config.assert_version()`. After a package
  upgrade, transactions built against the old version abort — rebuild against the
  current package IDs.
- **Settlement timing.** `redeem_settled` requires the market actually settled
  (`ensure_settled` against the propbook Pyth feed at the exact expiry millisecond).
  A market that has expired but isn't settled yet is in `awaiting_settle` — you can't
  redeem-settled it until a settlement observation lands.
- **Async LP.** Supply/withdraw don't execute inline; they queue and fill at a keeper
  flush at one NAV mark. Don't assume immediate fills; watch `SupplyFilled` /
  `WithdrawFilled` (§6). Cancel before the flush with the returned index.
- **Accumulator delivery.** Payouts, fills, and refunds are delivered via the
  `AccumulatorRoot` and only land in your stored balance after a `settle<T>` — which
  every account-touching predict flow runs for you. A bare balance read can lag until
  the next settle.
- **Leverage = a time-varying floor, priced in.** `leverage` (1e9-scaled, 1e9 = 1x)
  sets a deterministic floor schedule; the contract value is range-probability minus
  the floor, floored at 0. Mint enforces `max_terminal_floor ≤ max_terminal_payout`.
  Leveraged orders can be liquidated when they fall below floor.
- **Rounding favors the protocol.** User-facing outflows (redeem, withdraw, payout)
  round down; you may receive ≤1 unit less than a naive computation. Don't assert
  bit-exact payouts.
- **Slippage semantics differ by entrypoint.** `mint_exact_quantity.max_cost` caps the
  all-in withdrawal; `mint_exact_amount` caps only the `net_premium` budget and uses
  `min_quantity` as the guard (fees charged on top). `OrderMinted` emits the payment
  components separately, not a single total.
- **Ticks are raw grid indices.** `lower_tick`/`higher_tick` are integer indices on the
  market's `tick_size` grid; mint admission additionally snaps to `admission_tick_size`.
  An open upper bound uses the positive-infinity sentinel tick.

---

## 6. Discovery & indexer

- **Indexer base URL:** `https://predict-server-beta.testnet.mystenlabs.com`
  (override in `deployment.testnet.json` → `servers.predict` if present).
- **Find markets:** `GET /markets` → rows carry `expiry_market_id`, `expiry`,
  `tick_size`, `max_admission_leverage`, etc. Filter by `expiry` to map markets onto
  cadence slots. `GET /markets/{expiry_market_id}/state` → settlement info
  (`settlement.settlement_price` once settled).
- **Live on-chain state** (cash, payout liability, reference tick, oracle reads) is
  read from the chain via `devInspect` getters on `ExpiryMarket` / `PoolVault` /
  the feeds — see the operational dashboard (§7) for a working reader.
- **Events to index** (emitted by the owning module, past-tense names):
  `OrderMinted`, `LiveOrderRedeemed`, `SettledOrderRedeemed`, `LiquidatedOrderRedeemed`,
  `OrderLiquidated`, `MarketCreated`, `MarketSettled`, `ReferenceTickSet`,
  `SupplyRequested`, `WithdrawRequested`, `SupplyFilled`, `WithdrawFilled`,
  `RequestCancelled`, `FlushExecuted`, `BuilderCodeCreated`, `BuilderFeesClaimed`,
  `TradingPausedUpdated`, `ExpiryMarketMintPausedUpdated`.

---

## 7. Operational dashboard

A read-only, full-screen TUI that watches protocol health (verdict, oracle freshness,
backing/solvency, the per-cadence market timeline, keeper/settlement state) lives at
`packages/predict/dashboard/`. It reads this same `deployment.testnet.json`.

```
cd packages/predict/dashboard
python3 dashboard.py            # requires: pip install textual
# flags: --asset BTC_USD  --rpc-url <url>  --refresh 10  --indexer-url <url>
```

Use it to confirm the deployment is live and healthy before/while integrating: a green
`● LIVE` surface with `all systems nominal` means the markets, oracle, and pool are all
in a tradeable state.
