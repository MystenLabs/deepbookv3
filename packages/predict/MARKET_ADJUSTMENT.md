# Flow-Based Price Adjustment

## The Problem

The predict protocol quotes binary option prices from an SVI oracle (Black-Scholes on a volatility surface). This works well when the oracle is the best available source of truth. But if a more accurate price discovery venue exists — e.g., Polymarket with active participants and no oracle dependency — anyone with access to that better signal can systematically buy underpriced positions and drain the vault.

**Example**: 15 minutes to expiry. Our oracle prices the UP token (BTC > $100k) at 20c. The same market on Polymarket is trading at 40c. A trader buys UP from us at ~20c (+ spread) when it's "really" worth 40c. The vault absorbs the loss. This continues until expiry.

The current spread (base + utilization) sets a minimum edge an attacker needs, but doesn't solve the root cause: **the mid-price itself is wrong**. No amount of spread fixes a wrong mid.

This is the fundamental vulnerability of any oracle-based quoting system: if your oracle is wrong, you lose.

## The Alternative: Pure AMM

A pure AMM (like Uniswap) has no oracle. Price is purely emergent from supply and demand. It can't be "wrong" relative to an external source because it IS the source. Every trade moves the price, and arbitrageurs keep it aligned with other venues.

But a pure AMM has its own problem: **the price is always stale by default**. Every single transaction is an arbitrage (small or large). Price discovery is slow and expensive — the AMM only learns the "right" price after absorbing losses from informed traders.

## The Goal

We want a hybrid: the oracle provides a reasonable starting price, but **taker flow also influences the effective price**. If the oracle is right, the flow signal fades and the oracle dominates. If the oracle is wrong, taker flow corrects the mid-price before the vault bleeds too much.

## Assumptions

The protocol runs a rolling set of oracles with expirations at increasing intervals:

```
now                                                                      ~7 weeks out
 |                                                                             |
 |  hourly (12)          |  daily (7)              |  weekly (7)               |
 |  ·  ·  ·  ·  ·  ·  ·  | ·     ·     ·     ·     | ·        ·        ·       |
 |__|__|__|__|__|__|__|__|_______|_______|_________|__________|__________|_____|
 0h    3h    6h    9h   12h    2d     4d     6d    1w       3w        5w     7w
```

- **Hourly**: next 12 expirations (one every hour)
- **Daily**: next 7 expirations (one every day)
- **Weekly**: next 7 expirations (one every week)

At any given time, there are ~26 active oracles. New oracles are created as old ones expire and settle. Each oracle has continuous strikes.

This means trades can come in across a wide range of expirations — a flow-based signal from a 45-minute-to-expiry trade is very different from a 5-week-to-expiry trade.

**Constraint**: this runs on-chain in a smart contract. The solution must use O(1) space and O(1) time — we cannot iterate over oracles or maintain per-oracle state that grows. The aggregate must be a fixed-size summary that any trade can update and any quote can read in constant time.

## What We Know

Currently, the oracle provides an SVI volatility surface and a **forward price**. The forward price is the key input to Black-Scholes for computing binary option prices — when we say "the oracle is wrong," it's often the forward price that's stale relative to where the market actually is.

When a user mints a position, we receive these inputs:

- **Direction** (UP or DOWN) — the core directional signal
- **Cost** (USDC spent) — the strength of conviction / "vote weight"
- **Expiry** (from the oracle) — the timeframe of the conviction
- **Strike** (from the market key) — the price level

From these inputs, we want to build an **aggregate view of flow**. This aggregate captures the market's collective opinion based on actual capital deployment.

## Key Questions

### 1. What do we store?

We need some aggregate state that summarizes the cumulative flow signal. What variables capture the right information?

At minimum, we need the direction and magnitude of flow. But do we also need to track the timeframe profile of the flow (e.g., is the signal coming from near-term or far-term trades)?

### 2. How does each trade update the aggregate?

Each trade input carries different information:

- **Direction + cost**: the primary signal. $50k of UP buys = strong bullish view.
- **Expiry**: a 30-min trade is a very specific near-term conviction ("BTC is going up NOW"). A 7-day trade is a more diffuse view ("BTC will be higher eventually"). Should a 30-min trade contribute more to the aggregate than a 7-day trade? If so, how much more?
- **Strike**: does strike need to factor into the aggregate directly, or does USDC cost already handle it? A far-OTM strike has a low binary price, so the same quantity costs less USDC than an ATM trade — cost may naturally down-weight low-conviction strikes.

### 3. How does the aggregate decay?

The flow signal should fade over time — old trades become less relevant. Key considerations:

- **Linear vs exponential decay**: linear is simpler but the adjustment hits zero at a predictable time (gameable). Exponential is smoother and harder to time — could be half-life based (value halves every N ms) or EMA based (similar to the EWMA used in DeepBook core for volume tracking).
- **Decay speed**: fast decay trusts the oracle more. Slow decay trusts flow more. This should be configurable.
- **Does the decay rate itself depend on context?** e.g., should the signal decay faster when the oracle is actively being updated (fresh data) vs when it's stale?
- **Settlement**: when an oracle settles, its trades stop contributing new signal. The ideal decay mechanism should naturally handle this — the signal from a settled oracle's trades fades without needing explicit cleanup.

### 4. How do we use the aggregate to quote each oracle?

This is where time-to-expiry matters on the **output** side. Given an aggregate flow signal, how should it affect quotes for different oracles?

- A 5-minute-to-expiry oracle should probably be very sensitive to the flow signal (binary price moves sharply near expiry).
- A 2-hour-to-expiry oracle should be less sensitive (more time for things to change).
- Should there be both an **ingest weight** (how much this trade's tte affects its contribution) and an **output weight** (how much the aggregate affects this oracle's quote)?

### 5. How much flow should it take to move the price?

This is the "virtual depth" or "liquidity resistance" question. It likely should scale with the vault balance — a $1M vault should require more flow to move than a $10k vault. But what's the right ratio?

## Initial Direction

One approach we've been exploring. Not prescriptive — poking holes is encouraged.

### The idea in plain language

We keep a single number — call it the **flow signal** — that represents the market's collective bullish/bearish opinion based on actual trades. Think of it like a tug-of-war:

- Every dollar spent buying UP pulls the signal toward bullish.
- Every dollar spent buying DOWN pulls it toward bearish.
- Over time, the signal fades back to neutral (the oracle takes over again).

When we quote a price for any oracle, we take the oracle's price and nudge it by the flow signal. Three things control how much:

1. **How big is the signal?** More one-sided flow = bigger nudge.
2. **How recent is the signal?** It decays over time — a signal from 2 minutes ago matters less than one from 5 seconds ago.
3. **How close is this oracle to expiry?** Near-expiry oracles get nudged more. A 5-minute oracle is very sensitive; a 3-week oracle barely moves.

### Two places where time-to-expiry matters

**When a trade comes in** — a 30-minute-to-expiry trade is a strong, urgent signal ("BTC is going up RIGHT NOW"). A 7-day trade is weaker as a near-term signal. So near-expiry trades push the flow signal harder.

**When we quote an oracle** — a 5-minute-to-expiry oracle should be very reactive to the flow signal. A 3-hour oracle should be mostly anchored to its oracle price. So near-expiry oracles are more sensitive to the flow signal.

### What we store

A single fixed-size aggregate (O(1) space):

```
value: u64         // how strong the signal is
is_negative: bool  // bullish (+) or bearish (-)
last_update_ms: u64
```

### Configurable parameters

| Parameter | What it controls |
|-----------|-----------------|
| `depth_multiplier` | How much capital it takes to move the signal. Scales with vault balance — a bigger vault is harder to push around. |
| `half_life_ms` | How fast the signal fades. Short = trust oracle more. Long = trust flow more. |
| `max_adjustment` | Cap on how far the mid-price can drift from the oracle. Safety rail. |
| `reference_tte_ms` | The "crossover point" for time-to-expiry weighting. Oracles/trades at this tte get 50% weight. Shorter gets more, longer gets less. |

### Walked through example

Setup: Three oracles for BTC, all at strike $70k. Current BTC price is around $70.1k.

| Oracle | Time to expiry | Oracle UP price | Intuition |
|--------|---------------|-----------------|-----------|
| 30min  | 30 minutes    | 20c             | Unlikely to hit $70k in 30min |
| 24hr   | 24 hours      | 40c             | Decent chance over a day |
| 7d     | 7 days        | 70c             | Likely over a week |

Vault holds $100k. Parameters: depth_multiplier = 2x, half_life = 30s, reference_tte = 30min. Flow signal starts at **0** (neutral).

**A trader buys $10k of UP on the 30min oracle.**
```
Trade impact  = $10k / ($100k vault * 2x depth) = 0.05
Ingest weight = 30min ref / (30min ref + 30min tte) = 0.5
Signal update = 0 + 0.05 * 0.5 = +0.025
```

This single trade shifts quotes across all three oracles:

| Oracle | Output weight | Mid shift | New UP price |
|--------|--------------|-----------|--------------|
| 30min  | 30 / (30 + 30) = 0.50    | +1.25c | 20c → **21.25c** |
| 24hr   | 30 / (30 + 1440) = 0.02  | +0.05c | 40c → **40.05c** |
| 7d     | 30 / (30 + 10080) = 0.003 | +0.01c | 70c → **70.01c** |

The 30min oracle moves meaningfully. The 24hr oracle barely notices. The 7d oracle is essentially unchanged. This makes sense — a short-term bullish trade is mostly a short-term signal.

**30 seconds pass, no trades.**
```
Decay: 1 full half-life → signal halves from 0.025 to 0.0125
```

| Oracle | New UP price |
|--------|-------------|
| 30min  | 20c → **20.63c** |
| 24hr   | 40c → **40.03c** |
| 7d     | 70c → **70.00c** |

The signal is fading back. If no one else trades, all prices return to their oracle values.

The key dynamic: if traders keep buying UP, the mid keeps climbing. If they stop, it fades back. The oracle is the gravity; flow is the force pulling away from it.
