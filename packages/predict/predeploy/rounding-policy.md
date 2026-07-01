# Predict Rounding Policy

Ratified 2026-06-07.

## Premise

At 1e-9 fixed-point with the protocol's token decimals, sub-unit dust is
economically negligible. The real risk is an off-by-one that aborts a
transaction and strands funds. The protocol therefore optimizes for liveness and
a protocol-favored dust bias, not bit-exactness for its own sake.

## Rules

### R1: Liveness first

Dust must never abort a settlement, redeem, backing, or liability path.

Every `available - requested` subtraction on those paths must be provably
non-underflowing. The reserve or liability backing a payout must always be at
least the amount paid against it.

Preferred construction:

- compute the reserve and payout from the same expression; or
- remove and reinsert exact terms so the accounting atoms match bit-for-bit; or
- where that is impossible, round the reserve up.

A `>=` relation that can become `<` by one unit of precision is the bug class.

R1 covers only dust/ulp underflow. It does not cover:

- deferred-realization shortfall, where backing cash can move before an owed
  amount is split; use defer-and-carry accounting instead;
- bootstrap / `total_supply == 0` issues; those need a minimum-liquidity or
  equivalent structural solution.

### R2: Dust is biased to the protocol

When a rounding choice exists, the protocol or LP pool keeps the dust. The user
or LP counterparty receives at most one unit less.

Concretely:

- user-facing outflows round down: redeem, withdraw, payout, rebate;
- protocol-held reserves and liabilities are greater than or equal to the
  corresponding outflow;
- use bit-equal reserve/payout pairing where possible, otherwise round reserves
  up.

Net result: dust accrues to the pool, is never stranded, and never causes an
abort.

### R3: Document direction and owner

Every money-moving expression should name its rounding direction and who owns
the dust when the expression is not obvious.

Example:

```move
// = amount * p / S, round down (user eats <=1 ulp; pool never short).
```

Use `ceil(...)` terminology for round-up paths.

## Applications

### Partial close to settled payout

The reserve and payout must be derived from the same order atoms. On partial
close, remove the old order terms and reinsert the replacement terms exactly, so
tree reserve equals settled payout. No dust buffer is needed when the same terms
drive both sides.

### Protocol reserve realization

Do not bare-split a balance for an amount recognized earlier if the backing cash
can be redeployed before the split. Realize only `min(pending, available)`, carry
the remainder, and keep the carried amount out of LP value. This is a separate
liveness class from R1 dust.

### NAV and floor correction

The exact live NAV rounds floor correction so it cannot overstate recoverable
value. A one-unit fixed-point dust difference must bias toward incumbents/the
protocol, not toward overpaying a withdrawal.

## Audit Obligation

Every money flow must be checked against R1 and R2:

- mint contribution
- live redeem
- settled payout
- liquidation
- fees and discounts
- rebate reserve
- LP supply/withdraw pricing
- NAV floor correction

If a flow can underflow or round toward the user, fix it or document the accepted
tradeoff explicitly.
