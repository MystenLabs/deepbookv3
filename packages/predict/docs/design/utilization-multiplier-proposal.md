# Utilization-scaled fee multiplier — design note

Status: **Phase 1 landed** (LP withdraw fee multiplier + `ProtocolConfig`
utilization cache). Phase 2 (trader-side multiplier reading the cache) is a
follow-on PR.

The earlier recommendation against a trader-side application assumed either
funnelling trades through `PoolVault` or a per-expiry ratio. Phase 1 caches
pool-wide `u` onto `ProtocolConfig` at flush end — already on every trade path
as `&ProtocolConfig` — so Phase 2 needs no new shared-object dependency.

## The problem being priced

When an LP withdraws, the pool's cash cushion shrinks and its outstanding payout
liability does not. The LPs who stay back the same obligations with less
protection — more risk per dollar of equity, for the same pay.

Nothing in the system responds to this without the multiplier:

- Per-expiry funding room is bounded by `max_expiry_allocation`, snapshotted at
  registration (`pool_accounting.move`). It does not shrink with equity.
- `backing_buffer_lambda` is sized off liability, not off pool equity.
- Trader fees are `max(base_fee·√(p(1−p)), min_fee) × expiry_fee_multiplier` —
  a function of the contract's own probability and time to expiry, with no
  reference to pool state.

## The ratio — liability over equity

```
u = total_payout_liability / pool_nav      // clamped to [0, 1e9]
```

**Rejected:** `1 − idle_balance / pool_nav`. `rebalance_expiry_cash` is
permissionless — anyone can shift idle into expiry cash, raising an idle-based
multiplier for every withdrawer in the next flush. L/E is invariant to that.

**Rejected:** per-expiry utilization from the market's own cash and liability.
The same permissionless rebalance lets a trader who finds the surcharge firing
top the market up and switch it off for gas — and the top-up drains pool idle.

`total_payout_liability` is accumulated in `value_expiry` on the **same branch**
as NAV (swept/settled markets contribute 0 to both). A settled market's stale
`settled_payout_liability` must not inflate `u`.

## The curve

Mirror `expiry_fee_multiplier`: linear from 1.0 at `utilization_threshold` to
`utilization_max_multiplier` at `u = 1.0`, ramp rounded down. LP-side product
then rounds up (to the pool); trade-side product (Phase 2) rounds down.

## Phase 1 application (landed)

```
effective_rate = min(mul_up(base_rate, utilization_multiplier(u)), max_plp_fee_rate)
```

Frozen into `FlushMark` alongside the two rates. `u`, the multiplier, and the
cache timestamp are emitted on `FlushExecuted` and written onto `ProtocolConfig`
inside the valuation lock.

Defaults: `utilization_max_multiplier = 1.0` (exact no-op), threshold `0.8`,
max multiplier ceiling `3.0`.

## Phase 2 (follow-on)

Read the cached `u` on mint/redeem and compose a second multiplier onto the
existing trade fee. Do not add `PoolVault` to the trade path. Propose an
explicit staleness policy for an unusually old cache (decay toward 1.0).

## Contention note

`finish_flush` already takes `&mut ProtocolConfig` for the valuation lock. The
cache write adds no new shared-object contention against the trade path's
read-only `&ProtocolConfig` uses — the exclusive lock was already taken once per
flush.
