# Predict

Predict is an on-chain protocol for European cash-settled binary options
(digitals) on Sui. Users trade **range digitals** on the value of an oracle feed
at a fixed future **expiry**: a contract pays a fixed notional if the settlement
price lands inside the trader's chosen strike range, and zero otherwise. A shared
**pool** of liquidity providers writes every contract and earns the trading flow.

> **Status:** in development, not yet deployed. There are no published package
> addresses yet, and the on-chain interface is still changing. The documentation
> describes how the protocol works and is designed; it is not an integration or
> SDK guide.

From package version 4, Predict ships with two companion packages: [`deepbook_predict_orders`](../predict_orders/README.md), which holds the delayed-execution order queue every mint and early sell goes through, and [`deepbook_predict_math`](../predict_math/README.md), a pure pricing-math library. Sui caps a package at 102,400 bytes, so the order flow and the math live beside Predict, and Predict never names the companion. See [delayed execution](./docs/concepts/delayed-execution.md).

The TypeScript client is [`@mysten/deepbook-predict`](https://github.com/MystenLabs/ts-sdks/tree/main/packages/deepbook-predict), maintained in `MystenLabs/ts-sdks`.

## Documentation

Protocol documentation lives in [`docs/`](./docs/README.md). Start with the
[overview](./docs/overview.md), then read the
[concepts](./docs/README.md#concepts) and [risks](./docs/risks.md).

## Build & test

```sh
sui move build                                            # build the package
sui move test --gas-limit 100000000000 --package-size 64  # run the Move test suite (Sui 1.79.1+)
```

`--package-size 64` raises the test VM's package arena from its 10 MB default, which the Predict test package exceeds. Predict's order-flow primitives are exercised again from the companion's suite, so after changing them also test `packages/predict_orders` and `packages/sessions`.

Predict is close to Sui's 102,400-byte package limit, which counts module bytes, module names, the type-origin table, and the linkage table, and applies to every upgrade. Size-check every change from a non-test build. Sui's verifier also caps a struct at 32 fields, which the Move test VM does not enforce, so after a struct change publish the closure on localnet (`python3 -m harness smoke` from `packages/predict`) rather than trusting the tests alone.

## Developing Predict

The team's development system — the live tracker, settled decision records,
response policies, harness experiment ledger, and audit obligations — starts at
[`predeploy/README.md`](./predeploy/README.md) (the system map and authority
order). Read it before proposing or changing protocol behavior; it is how work
stays coherent across sessions and contributors.

See the repository root [CLAUDE.md](../../CLAUDE.md), which routes contributor conventions to the matching repository rules.
