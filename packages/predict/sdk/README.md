# @mysten/predict

TypeScript SDK for DeepBook Predict — binary markets on Sui. Builds
ready-to-sign transactions and reads on-chain state over gRPC. The SDK never
signs and never touches keys: every `tx.*` method returns a `Transaction` for
your wallet (dapp-kit) or signer to execute.

## Install

Not yet published to npm. Until then, consume it as a git dependency or from a
local checkout of this repo:

```jsonc
// package.json
"dependencies": {
	"@mysten/predict": "github:MystenLabs/deepbookv3#path:packages/predict/sdk",
	"@mysten/sui": "^2.16.0" // peer dependency
}
```

## Quickstart

```ts
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { PredictClient } from "@mysten/predict";

const client = new SuiGrpcClient({
	network: "testnet",
	baseUrl: "https://fullnode.testnet.sui.io:443",
});
const predict = new PredictClient({ network: "testnet", client });

// One-time: create your Predict account (a shared AccountWrapper).
const createTx = predict.tx.createManager();

// Fund it: pulls DUSDC from your wallet coins.
const depositTx = predict.tx.deposit(myAddress, 250); // $250

// Trade: BTC above $105,000 at this hour's expiry, $50 max payout, 2x leverage.
const mintTx = await predict.tx.mint(
	myAddress,
	{ underlying: "BTC", expiryMs: 1767225600000, strike: 105_000, side: "up" },
	{ quantity: 50, leverage: 2, maxCost: 12.5 },
);
// -> sign & execute any of these with your wallet / dapp-kit / signer

// Read: live markets and pool state.
const marketIds = await predict.read.markets();
const market = await predict.read.market({ underlying: "BTC", expiryMs: 1767225600000 });
console.log(market?.nav, market?.tickSize, market?.mintPaused);
```

## ⚠ Slippage defaults are UNCAPPED

`mint` mirrors the chain's semantics: when you omit `maxCost` and
`maxProbability`, the mint is **uncapped** — if the price moves between your
quote and execution, the position can cost up to your full account balance.
Frontends always have a quote in hand: **pass `maxCost` from your quote.**
The same applies to `redeem`, which has no slippage floor on the current
deployment — quote first, close fast.

## Units

Everything human-facing is decimal; everything on-chain is scaled integers.
The facade converts **inputs** exactly (string/bigint math — no floats on the
money path in). Read outputs typed `number` are display values: above 2^53
raw they lose low-digit precision — for accounting-exact reads use the
primitives layer, which returns raw `bigint`s (`accountBalance`, `poolStats`, …).

| Concept | You pass / receive | On-chain raw |
| --- | --- | --- |
| Amounts (deposit, spend, maxCost, balances) | USD decimal number or string (`12.5`, `"12.5"`) | ×1e6 (DUSDC) |
| `quantity` | **max payout** in USD; positions pay $1 per contract at expiry | ×1e6, in $0.01 lots |
| `strike` | USD (`105_000`) | ×1e9, must land on the market's tick |
| `leverage` | number ≥ 1 (default 1) | ×1e9 |
| `maxProbability` | 0..1 (`0.35` = 35¢ per $1 contract) | ×1e9 |
| PLP shares (`withdrawPlp`, `plpBalance`) | raw `bigint` shares | 6-decimal coin |

`side: "up"` wins if the settlement price is above the strike; `"down"` below.

## What's in the box

- **`PredictClient.tx`** — `createManager`, `deposit`, `withdraw`, `mint`,
  `mintAmount`, `redeem`, `claimSettled`, `supplyPlp`, `withdrawPlp`,
  `cancelSupplyPlp`, `cancelWithdrawPlp`, `setBuilderCode`, `unsetBuilderCode`.
  Market-resolving builders (`mint`/`mintAmount`/`redeem`/`claimSettled`) are
  async: they resolve the market object from
  `{ underlying, expiryMs, strike, side }` via the on-chain registry (cached
  per client).
- **`PredictClient.read`** — `markets()`, `market(desc)` (state + live NAV),
  `balance(owner)`, `plpBalance(owner)`, `pool()`. All reads run over gRPC
  `simulateTransaction`; no indexer required.
- **Composable primitives** — every Move entrypoint is also exported as a
  `(cfg, tx, args) => …` function with raw bigint units
  (`mintExactQuantity`, `redeemLive`, `requestSupply`, …) for integrators
  composing their own PTBs, plus the reads (`marketState`,
  `settlementPrice`, `currentNav`, `poolStats`, …).
- **Typed errors** — invalid inputs throw `PredictInputError` before the
  chain sees them; failed simulations throw `PredictMoveError` with the
  decoded Move abort (`module`, `code`, `abortName`).

## Networks & deployments

**Testnet only today** — `getConfig("mainnet")` throws until a mainnet
deployment exists. Object ids for the current testnet deployment are baked
into the SDK (`TESTNET_CONFIG`); they are updated, with a release, whenever a
new package version is deployed. Move-call targets flow through one
resolution seam, which will switch to MVR names (`@deepbook/predict`) once
registered — package upgrades then stop requiring an SDK release for target
resolution.

## Notes

- Position enumeration (all open orders for an account) is not on-chain
  readable and ships with the indexer API integration later; `mint` returns
  the order id in its transaction result, and `OrderMinted` events carry it.
- PLP supply/withdraw are queued and fill at the next pool flush; cancels
  take the queue `index` from the request transaction's events.
- `claimSettled` requires a full close of the order (contract rule).

## Development

```sh
pnpm install
pnpm test          # offline unit suite (tx construction, parsing, facade)
pnpm test:testnet  # live-testnet smoke: reads + deployed-surface arity guards
pnpm build         # ESM + CJS + d.ts via tsup
```
