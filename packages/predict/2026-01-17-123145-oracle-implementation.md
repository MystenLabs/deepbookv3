# Coding Session Context

**Task**: oracle-implementation
**Created**: 2026-01-17T12:31:45Z
**Handoff ID**: 2026-01-17-123145-oracle-implementation

## Task

Implement the Block Scholes oracle integration for DeepBook Predict - translating the Python demo into Move smart contracts.

## Background

DeepBook Predict is a binary options protocol. Users bet on whether price will be above/below a strike at expiry. $1 if correct, $0 if wrong.

**Pricing approach**: Block Scholes provides an SVI (Stochastic Volatility Inspired) volatility surface oracle. The oracle pushes base data; derived values (IV, option prices) are computed on-chain.

**Key design decisions already made**:
- Vault-based counterparty model (single vault takes all trades, not P2P order book)
- Spread-only fees (no trading fees)
- SVI params update at low frequency (every 10-20s), spot/forward at high frequency
- Derived feeds computed on-chain via calculator pattern

**The Python demo** (`blockscholes_oracle_deepbook_demo.py`) simulates what the on-chain oracle should do:
- Feed storage with versioning and keying
- SVI-based IV calculation for any strike
- Digital option pricing using Black-Scholes
- Permission bitmasks for access control
- Calculator chaining (IV depends on FORWARD + SVI, OPTION_PRICE depends on IV + SPOT + RATE)

## Starting Points

Look at the Python demo first to understand the architecture:
- `FeedStorage` class - how feeds are stored and keyed
- `SVICalculator` - how IV is computed from SVI params
- `OptionPriceCalculator` - how digital option prices are computed
- `compute_iv_svi()` function - the SVI formula
- `compute_digital_option_price()` function - Black-Scholes digital

For Move patterns, look at existing DeepBook code:
- How oracles are typically integrated
- Existing price feed patterns
- Shared object patterns for the feed storage

## Reference Material

**SVI Formula**:
```
k = log(strike / forward)  // log moneyness
total_variance = a + b * (rho * (k - m) + sqrt((k - m)^2 + sigma^2))
implied_vol = sqrt(total_variance / time_to_expiry)
```

**Digital Option Formula**:
```
d+ = (log(F/K) + 0.5 * vol^2 * t) / (vol * sqrt(t))
d- = d+ - vol * sqrt(t)
digital_call = exp(-r * t) * N(d-)
digital_put = exp(-r * t) * N(-d-)
```

**Base feeds** (stored, pushed by oracle):
- SPOT (high freq)
- FORWARD per expiry (high freq)
- SVI_PARAMS: a, b, rho, m, sigma (low freq, 10-20s)
- DOMESTIC_RATE (very low freq)

**Derived feeds** (computed on-chain):
- IV = f(FORWARD, SVI_PARAMS, strike)
- OPTION_PRICE = f(SPOT, FORWARD, IV, RATE, strike, expiry, is_call)

**Risk limits** (for later, not this session):
- Max single trade: 5% of capital
- Max per market: 20% of vault
- Max total exposure: 80% of vault

---

## Completion Checklist

When finished (or at a stopping point), write a summary file.

**Write to**: `2026-01-17-123145-oracle-implementation-summary.json` (in repo root or `.claude/` folder)

```json
{
  "handoff_id": "2026-01-17-123145-oracle-implementation",
  "task_completed": true,
  "summary": "Brief description of what was accomplished",
  "implementations": [
    {
      "description": "What was implemented",
      "files": ["path/to/file.move"]
    }
  ],
  "decisions": [
    {
      "decision": "Technical choice made",
      "rationale": "Why this approach"
    }
  ],
  "files_changed": [
    "path/to/file1.move",
    "path/to/file2.move"
  ],
  "open_questions": [
    "Unresolved issues or things to revisit"
  ],
  "technical_insights": [
    "Reusable knowledge - patterns discovered, gotchas learned, things worth remembering"
  ],
  "next_steps": [
    "If continuing this work, what comes next"
  ],
  "blockers": []
}
```

**Field Guide:**
- `task_completed`: Set to `false` if stopping before the task is done
- `implementations`: Group related file changes by what they accomplish
- `decisions`: Technical choices made during implementation - include rationale
- `files_changed`: All files created or modified (paths relative to repo root)
- `open_questions`: Unresolved issues, things that need clarification, edge cases to handle
- `technical_insights`: Knowledge valuable beyond this specific task - patterns, gotchas, learnings
- `next_steps`: If work continues, what should happen next
- `blockers`: Anything preventing progress (empty array if none)

---

*This context document helps maintain continuity across coding sessions.*
