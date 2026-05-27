# Sui Overflow Workshop — How to Trade on DeepBook Predict

Thursday, May 28 · 10–11 AM EDT

This is the attendee handout for the live walkthrough. The full protocol concepts live in [README.md](./README.md). This doc is the tight, hands-on path: install, get test funds, place your first trade.

## Testnet deployment (as of workshop)

| Resource | Value |
|---|---|
| Network | Sui testnet |
| Predict package | `0xf5ea2b3749c65d6e56507cc35388719aadb28f9cab873696a2f8687f5c785138` |
| Predict object | `0xc8736204d12f0a7277c86388a68bf8a194b0a14c5538ad13f22cbd8e2a38028a` |
| Quote asset | `…::dusdc::DUSDC` (test token, 6 decimals) |
| Public indexer | https://predict-server.testnet.mystenlabs.com |

Strikes and prices use **1e9 scaling** (a $75,000 BTC strike is `75_000_000_000_000`). Quantities and DUSDC are in **1e6 units** (one $1 contract = `1_000_000`).

## Prerequisites

1. **Sui CLI** with a testnet address and gas.
   ```
   sui client switch --env testnet
   sui client active-address
   sui client faucet
   ```
2. **Node + pnpm**. From the repo root:
   ```
   cd scripts && pnpm install
   ```
3. **DUSDC**. There is no public faucet — drop your testnet address in the workshop chat and the host will mint you DUSDC. Every script that needs DUSDC pulls from the coins you already own (no treasury cap required); you just need a non-zero balance to start.

## The five commands

All commands run from `scripts/`. Every script reads testnet IDs from `scripts/config/constants.ts` and your active address from `sui client`.

### 1. List active markets

```
pnpm predict-list-markets
```
Hits the indexer and prints active oracles (BTC expiries). Copy an `ORACLE_ID` and `EXPIRY` from the output.

### 2. Create your PredictManager (one time)

```
pnpm predict-create-manager
```
Prints `MANAGER_ID=0x…`. Save it as an env var for the rest of the workshop:
```
export MANAGER_ID=0x...
```

### 3. Mint a directional position

UP/DOWN binary bet on a strike. The script also tops up your manager with DUSDC in the same PTB (sourced from coins you already own).

```
export ORACLE_ID=0x...                        # from step 1
export EXPIRY=1748419200000                   # from step 1
export STRIKE=75000000000000                  # $75,000 in 1e9
export DIRECTION=up                           # or down
export QUANTITY=1000000                       # $1 face
# optional:
# export TOPUP=2000000                        # DUSDC to deposit before mint (default = QUANTITY)
# export SKIP_TOPUP=1                         # skip deposit, use manager's existing balance

pnpm predict-mint
```
The PTB does, in order: pick up your existing DUSDC → `predict_manager::deposit` → `market_key::up/down` → `predict::mint`. A `PositionMinted` event prints.

### 4. Redeem the position

Same env vars, plus `QUANTITY` of however much you want to close.
```
pnpm predict-redeem
```
After settlement, set `SETTLED=1` to use `redeem_permissionless`.

### 5. Vertical range (spread)

Bet that settlement lands inside a band `(lower, higher]`. Pays the full $1·qty if it does, otherwise the live bid.

```
export LOWER_STRIKE=70000000000000
export HIGHER_STRIKE=80000000000000
pnpm predict-mint-range
```

### Bonus: provide liquidity

```
pnpm predict-deposit         # supply DUSDC → receive PLP
pnpm predict-withdraw        # burn PLP → receive DUSDC  (set PLP_COIN=0x…)
```

## What's happening on-chain

- `predict::create_manager` shares a `PredictManager` owned by you. Positions live inside it as table entries keyed by `MarketKey`/`RangeKey`, not as separate NFTs.
- `predict::mint<DUSDC>` reads the current oracle SVI, computes ask against post-trade vault state, withdraws cost from the manager's DUSDC balance, and increments the position quantity.
- `predict::redeem<DUSDC>` returns DUSDC to the manager, with the payout being the live bid pre-settlement or `$1·qty` if the strike won at settlement.
- The vault is one shared pool — every mint/redeem updates the same exposure that LPs are exposed to.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `ENotOwner` | You're calling a manager function from a different sender than the manager owner. |
| `EOracleNotSettled` on `redeem_permissionless` | Oracle is still live; use plain `predict::redeem` instead. |
| `ETradingPaused` | Protocol globally paused mints; nothing client-side fixes this. |
| `EInsufficientPosition` on redeem | Quantity exceeds what's actually open in your manager. |
| Server endpoint 5xx | Indexer hiccup. Direct on-chain reads still work; the server is for render data. |

## Source pointers

- Move sources: [sources/predict.move](./sources/predict.move), [sources/predict_manager.move](./sources/predict_manager.move), [sources/market_key/](./sources/market_key/), [sources/oracle.move](./sources/oracle.move)
- Workshop scripts: [`../../scripts/transactions/predict/`](../../scripts/transactions/predict/)
- Concepts deep dive: [README.md](./README.md)
