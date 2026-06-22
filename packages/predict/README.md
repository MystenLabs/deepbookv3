# Predict

Predict is an on-chain protocol for European cash-settled binary options
(digitals) on Sui. Users trade **range digitals** on the value of an oracle feed
at a fixed future **expiry**: a contract pays a fixed notional if the settlement
price lands inside the trader's chosen strike range, and zero otherwise. Each
contract can carry **deterministic leverage**, modelled as embedded premium
financing — a time-varying floor on the contract's own payoff — plus a
knock-out, rather than as a separate debt position. A shared **pool** of
liquidity providers writes every contract and earns the trading flow.

> **Status:** in development, not yet deployed. There are no published package
> addresses yet, and the on-chain interface is still changing. The documentation
> describes how the protocol works and is designed; it is not an integration or
> SDK guide.

## Documentation

Protocol documentation lives in [`docs/`](./docs/README.md). Start with the
[overview](./docs/overview.md), then read the
[concepts](./docs/README.md#concepts) and [risks](./docs/risks.md).

## Build & test

```sh
sui move build                          # build the package
sui move test --gas-limit 100000000000  # run the Move test suite
```

See the repository root `CLAUDE.md` and `.claude/rules/` for contributor
conventions.
