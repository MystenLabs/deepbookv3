# Predict protocol documentation

This is the documentation for the Predict protocol: how it works, how it is
designed, and what its risks are. It is written for a technically literate reader
(traders, liquidity providers, and anyone evaluating the protocol) who wants to
understand the mechanism. It is **not** an integration or SDK guide — it does not
contain transaction recipes or a function-by-function API reference.

> **Status:** the protocol is in development and not yet deployed. Where a
> behaviour is still changing, the docs describe it at the conceptual level and
> point to the configuration that governs it rather than to specific values that
> may drift.

## Start here

- **[Overview](./overview.md)** — what Predict is, the core mental model, the
  market and position lifecycle, and what the protocol guarantees.
- **[Glossary](./glossary.md)** — every term technically defined, mapped to its
  standard options / structured-product name and to the code identifier.

## Concepts

How the protocol works:

- **[Markets and positions](./concepts/markets-and-positions.md)** — per-expiry
  range markets, the strike grid, what an order/position is, and the lifecycle
  from mint to settlement.
- **[Leverage and the floor](./concepts/leverage-and-floor.md)** — how leverage
  is modelled as embedded premium financing (a deterministic, time-varying
  floor) plus a knock-out on the contract's payoff.
- **[Pricing and oracles](./concepts/pricing-and-oracles.md)** — how prices are
  formed from Pyth spot and Block Scholes parameters, freshness rules, and how
  the settlement price is chosen.
- **[Fees and rebates](./concepts/fees-and-rebates.md)** — the fee components a
  trader pays, the staking discount, and the trading-loss rebate.
- **[Liquidation](./concepts/liquidation.md)** — when and why a leveraged
  position is liquidated, and what the holder receives.
- **[Liquidity and NAV](./concepts/liquidity-and-nav.md)** — the pool, PLP
  shares, how net asset value is computed, and supply/withdraw.

## Design

How the protocol is built:

- **[Architecture](./design/architecture.md)** — the on-chain objects, who owns
  what capital, the capability and authorization model, and version gating.
- **[Configuration](./design/configuration.md)** — what is tunable, the
  defaults, how config is snapshotted per expiry, and who can change it.
- **[Tick range encoding](./design/tick-range-encoding.md)** — proposed packed
  absolute-tick range representation for public APIs, order IDs, and exposure
  indexes.
- **[Versioning and shared-object loaders](./design/versioning-and-loaders.md)**
  — proposed central version authority and checked loader pattern for Predict
  shared objects.
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
