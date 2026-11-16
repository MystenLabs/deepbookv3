# Predict protocol documentation

This is the documentation for the Predict protocol: how it works, how it is
designed, and what its risks are. It is written for a technically literate reader
(traders, liquidity providers, and anyone evaluating the protocol) who wants to
understand the mechanism. It is **not** an integration or SDK guide — it does not
contain transaction recipes or a function-by-function API reference.

> **Status:** in development, not yet deployed. Current shipped state: oracle data arrives **signed and inline**, as Pyth Lazer and Block Scholes values checked against each underlying's oracle binding (no in-package oracle, and no Propbook read since package version 6). Strikes are **absolute integer ticks** (`raw_strike = tick × tick_size`). The LP layer is **asynchronous** — supply and withdraw are queued and settled by a **privileged periodic flush** that marks the whole pool at one **exact** NAV. **Terminal settlement is explicit**, from the signed Pyth price at expiry, or a signed Block Scholes spot at expiry after a 30-second grace period. From package version 4, mints and early sells use **delayed execution**: each order waits in its market's queue and fills at Pyth's signed price for a fixed instant after it was placed, and a filled order stays in the queue as an Open record. The queue lives in a companion package, `deepbook_predict_orders`, and the pure pricing math in a library, `deepbook_predict_math`, because Sui caps the size of a package. Where a behaviour is still changing, the docs describe it at the conceptual level and point to the configuration that governs it rather than to specific values that may drift.

## Start here

- **[Overview](./overview.md)** — what Predict is, the core mental model, the
  market and position lifecycle, and what the protocol guarantees.
- **[Glossary](./glossary.md)** — every term technically defined, mapped to its
  standard options / structured-product name and to the code identifier.

## Concepts

How the protocol works:

- **[Markets and positions](./concepts/markets-and-positions.md)** — per-expiry
  range markets, the absolute tick grid, what an order/position is, and the
  lifecycle from mint through early sell and settlement.
- **[Delayed execution](./concepts/delayed-execution.md)** — the three packages
  that share the order flow, how queued mints and early sells are placed,
  priced at τ, filled or refunded, held as Open records, and paid at
  settlement, plus the policy and the upgrade rules.
- **[Pricing and oracles](./concepts/pricing-and-oracles.md)** — how prices are formed from signed Pyth Lazer and Block Scholes data, the oracle binding, and the instant each flow prices at.
- **[Fees and rebates](./concepts/fees-and-rebates.md)** — the fee components a
  trader pays and the isolated inventory-impact charge and rebate.
- **[Liquidity and NAV](./concepts/liquidity-and-nav.md)** — the pool, PLP
  shares, the async supply/withdraw queues, the privileged flush, and how the
  exact pool NAV is computed.

## Design

How the protocol is built:

- **[Architecture](./design/architecture.md)** — the packages and on-chain
  objects, who owns what capital, the capability and authorization model, and
  version gating, including the publish and relink order across packages.
- **[Configuration](./design/configuration.md)** — what is tunable, the
  defaults, how config is snapshotted per expiry, and who can change it.
- **[Invariants](./design/invariants.md)** — a precise, scannable reference of
  the conditions the protocol always maintains (solvency, floor, NAV,
  settlement, rounding).
- **[Design decisions](./design/decisions.md)** — the significant design choices
  and the alternatives that were rejected, with rationale.

## Risks

- **[Risks and limitations](./risks.md)** — trust assumptions, risks to holders
  and liquidity providers, oracle and admin powers, and known limitations.

## Reading paths

- **Trader:** [overview](./overview.md) →
  [markets and positions](./concepts/markets-and-positions.md) →
  [delayed execution](./concepts/delayed-execution.md) →
  [fees and rebates](./concepts/fees-and-rebates.md) →
  [risks](./risks.md).
- **Liquidity provider:** [overview](./overview.md) →
  [liquidity and NAV](./concepts/liquidity-and-nav.md) →
  [pricing and oracles](./concepts/pricing-and-oracles.md) →
  [fees and rebates](./concepts/fees-and-rebates.md) → [risks](./risks.md).
