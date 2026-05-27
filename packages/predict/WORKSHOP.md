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

Internally, strikes and prices use **9-decimal scaling** and DUSDC uses **6-decimal scaling** — but the workshop scripts take **human units** (strikes in whole dollars, quantities in whole DUSDC) and scale them up for you. So `STRIKE: 75_000` means $75,000 and `QUANTITY: 1` means one $1 contract.

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

UP/DOWN binary bet on a strike. Edit the `CONFIG` block at the top of `scripts/transactions/predict/mintPosition.ts` — only `MANAGER_ID` is per-attendee; the rest is pre-filled to the workshop oracle:

```ts
const CONFIG = {
    MANAGER_ID:  'PASTE_YOUR_MANAGER_ID',  // ← paste your manager id here
    ORACLE_ID:   '0xec05af68…d851d2d',     // BTC 2026-05-28 08:00 UTC
    EXPIRY:      1779955200000,
    STRIKE:      75_000,                   // $75,000
    DIRECTION:   'up',                     // or 'down'
    QUANTITY:    1,                        // $1 face
    TOPUP:       1,                        // DUSDC to deposit before mint
    SKIP_TOPUP:  false,                    // true → reuse manager's existing balance
};
```

Then run:
```
pnpm predict-mint
```

The PTB does, in order: pick up your existing DUSDC → `predict_manager::deposit` → `market_key::up/down` → `predict::mint`. A `PositionMinted` event prints.

(Env vars with the same names override `CONFIG` if you'd rather pass them inline.)

### 4. Redeem the position

Edit `CONFIG` in `redeemPosition.ts` to mirror the position you minted (same ORACLE_ID, EXPIRY, STRIKE, DIRECTION) and choose how much to close in `QUANTITY`. Set `SETTLED: true` to use `redeem_permissionless` once the oracle has settled.

```
pnpm predict-redeem
```

### 5. Vertical range (spread)

Bet that settlement lands inside a band `(lower, higher]`. Pays $1 × qty if it does, otherwise the live bid. Edit `CONFIG` in `mintRange.ts`:

```ts
LOWER_STRIKE:  70_000,   // $70,000
HIGHER_STRIKE: 80_000,   // $80,000
```

```
pnpm predict-mint-range
```

### Bonus: provide liquidity

```
pnpm predict-deposit         # supply DUSDC → receive PLP (edit AMOUNT in deposit.ts)
pnpm predict-withdraw        # burn PLP → receive DUSDC   (edit PLP_COIN in withdraw.ts)
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
