# Predict protocol documentation

This is the documentation for the Predict protocol: how it works, how it is
designed, and what its risks are. It is written for a technically literate reader
(traders, liquidity providers, and anyone evaluating the protocol) who wants to
understand the mechanism. It is **not** an integration or SDK guide — it does not
contain transaction recipes or a function-by-function API reference.

> **Status:** in development, not yet deployed. Current shipped state: live
> oracle data is read from the standalone **propbook** Pyth and Block Scholes
> feeds (no in-package oracle); strikes are **absolute integer ticks**
> (`raw_strike = tick × tick_size`); the LP layer is **asynchronous** — supply
> and withdraw are queued and settled by a **privileged periodic flush** that
> marks the whole pool at one **exact** NAV; and **terminal settlement is
> passive**, using Propbook's exact Pyth timestamp history when a normal redeem
> or pool-rebalance flow first needs the settled branch. Where a behaviour is
> still changing, the docs describe it at the conceptual level and point to the
> configuration that governs it rather than to specific values that may drift.

## Start here

- **[Overview](./overview.md)** — what Predict is, the core mental model, the
  market and position lifecycle, and what the protocol guarantees.
- **[Glossary](./glossary.md)** — every term technically defined, mapped to its
  standard options / structured-product name and to the code identifier.

## Concepts

How the protocol works:

- **[Markets and positions](./concepts/markets-and-positions.md)** — per-expiry
  range markets, the absolute tick grid, what an order/position is, and the
  lifecycle from mint through live redeem and liquidation.
- **[Leverage and the floor](./concepts/leverage-and-floor.md)** — how leverage
  is modelled as embedded premium financing (a deterministic, time-varying
  floor) plus a knock-out on the contract's payoff.
- **[Pricing and oracles](./concepts/pricing-and-oracles.md)** — how prices are
  formed from the propbook Pyth spot and Block Scholes surface, the forward
  fallback, and freshness rules.
- **[Fees and rebates](./concepts/fees-and-rebates.md)** — the fee components a
  trader pays, the staking discount, and the trading-loss rebate.
- **[Liquidation](./concepts/liquidation.md)** — when and why a leveraged
  position is liquidated, and what the holder receives.
- **[Liquidity and NAV](./concepts/liquidity-and-nav.md)** — the pool, PLP
  shares, the async supply/withdraw queues, the privileged flush, and how the
  exact pool NAV is computed.

## Design

How the protocol is built:

- **[Architecture](./design/architecture.md)** — the on-chain objects, who owns
  what capital, the capability and authorization model, and version gating.
- **[Configuration](./design/configuration.md)** — what is tunable, the
  defaults, how config is snapshotted per expiry, and who can change it.
- **[Invariants](./design/invariants.md)** — a precise, scannable reference of
  the conditions the protocol always maintains (solvency, floor, NAV,
  settlement, liquidation, rounding).
- **[Design decisions](./design/decisions.md)** — the significant design choices
  and the alternatives that were rejected, with rationale.

## Risks

- **[Risks and limitations](./risks.md)** — trust assumptions, risks to holders
  and liquidity providers, oracle and admin powers, and known limitations.

## Reading paths

- **Trader:** [overview](./overview.md) →
  [markets and positions](./concepts/markets-and-positions.md) →
  [leverage and the floor](./concepts/leverage-and-floor.md) →
  [fees and rebates](./concepts/fees-and-rebates.md) →
  [liquidation](./concepts/liquidation.md) → [risks](./risks.md).
- **Liquidity provider:** [overview](./overview.md) →
  [liquidity and NAV](./concepts/liquidity-and-nav.md) →
  [pricing and oracles](./concepts/pricing-and-oracles.md) →
  [fees and rebates](./concepts/fees-and-rebates.md) → [risks](./risks.md).
