# Risk-Based Spread Calculation for Binary Options Vault

## Setup

A vault acts as the sole counterparty for binary option contracts. Users can mint UP or DOWN contracts at any continuous strike (bounded by a $0.03 minimum price and $0.97 maximum price).

- **UP at strike K**: pays $1 if settlement > K, else $0
- **DOWN at strike K**: pays $1 if settlement <= K, else $0

## Liability function

At settlement price P, the vault owes:

```
L(P) = Σ(UP qty where strike < P) + Σ(DOWN qty where strike ≥ P)
```

The peak of L(P) across all possible P is the true worst-case liability.

## Goal

Compute a risk-informed spread for each new mint. The spread should reflect how much additional risk that mint adds to the vault's aggregate exposure — not just directional skew (UP vs DOWN ratio), but strike concentration risk (e.g., the vault could be heavily exposed at strikes where both UP and DOWN contracts pay out simultaneously).

## Available inputs

### Oracle (per underlying+expiry)

- Spot price, forward price — updated ~1s
- SVI parameters (a, b, rho, m, sigma) — updated ~10-20s
- Risk-free rate, time to expiry
- From these: full risk-neutral probability distribution at any strike via Black-Scholes N(d2)
- Can compute EMA of any params or derived values (IV, etc.) if useful

### Vault state (O(1) updatable per trade)

Currently tracked:

- `total_up_short` — aggregate UP quantity across all strikes
- `total_down_short` — aggregate DOWN quantity across all strikes

Can add more summary statistics if needed (e.g., quantity-weighted average strike per side, second moment, etc.), as long as each is O(1) updatable on mint/redeem.

## Constraints

- On-chain (Sui Move), unsigned integers, fixed-point arithmetic (1e9 scaling)
- O(1) per mint/redeem — no iteration over positions
- Can store additional summary statistics, updated incrementally
- Oracle data available at time of each trade

## Question

What summary statistics should we track, and what formula should we use to compute a risk-informed spread that reflects the vault's true aggregate exposure?
