# Protocol invariants

A reference list of the facts the Predict protocol maintains — the conditions
that must always hold for it to be correct and solvent. It is a precise,
scannable companion to the prose concept docs, aimed at auditors, integrators,
and contributors. For *how* each mechanism works, follow the links into
[../README.md](../README.md).

> **Status:** pre-deploy. Names refer to modules/functions rather than line
> numbers, which drift.

## Solvency and custody

- **Cash backing.** Every expiry's DUSDC cash always covers its payout liability
  plus its unresolved trading-loss rebate reserve (`cash ≥ payout_liability +
  rebate_reserve`), re-asserted after every cash mutation
  (`expiry_cash::assert_backing`).
- **Live payout liability is a settlement floor plus a liquidity buffer.** The
  floor is the maximum summed live backing at any *single* settlement price
  (`StrikePayoutTree::max_live_backing_payout`, an O(1) root read); the buffer is
  `backing_buffer_lambda × (Σ live backing − floor)`, with Σ still maintained as
  a running per-order total (`StrikeExposure.live_backing_liability`). Because
  exactly one settlement price resolves a market, the floor alone covers every
  settlement outcome in full (`settled_liability(p) ≤ floor` for every `p`); the
  buffer governs how much pre-settlement exit demand beyond the floor is funded.
  A lambda of 1.0 reproduces the fully summed reserve. See
  [../concepts/liquidity-and-nav.md](../concepts/liquidity-and-nav.md).
- **Early exits are buffer-bounded, settlement is not.** A live redeem that
  would push cash below the reserve aborts; smaller closes, later retries, and
  the full settlement payout remain available. Closing a position releases its
  own share of the buffer, so exit liquidity cannot be monopolized.
- **Settled liability is exact.** After settlement, payout liability becomes the
  exact terminal liability at the settlement price (`materialize_settled_liability`,
  idempotent), which is always ≤ the settlement floor (hence ≤ the live reserve).
- **No pool earmark.** Each expiry is settlement-self-contained at its floor: a
  market that never receives another top-up still pays every settlement winner
  in full. The per-expiry funding cap (`max_expiry_funding`) is enforced on
  every funding move as a ceiling, and the pool sync tops every market up toward
  its reserve target before an LP withdrawal pays out.
- **Custody.** DUSDC lives in exactly three places: a trader's `PredictManager`
  (inner `BalanceManager`), each expiry's `ExpiryCash`, and the pool ledger's idle
  balance. `ExpiryMarket` is the sole authorizer of expiry cash movement. The
  protocol reserve accumulates the protocol's profit share and is excluded from
  PLP redemption.

## Floor and leverage

- Predict sells one binary (digital) contract with a time-varying floor; leverage
  changes the deterministic floor *schedule*, not a separate debt overlay.
- Live value = range-probability value − deterministic floor, floored at 0. A 1×
  order has zero floor.
- The floor is **limited-recourse per order**: it offsets only its own order's
  value/payout, capped at that value. Aggregate floor exceeding aggregate
  liability is not positive NAV.
- The floor index rises deterministically from 1.0 toward `terminal_floor_index`
  over `leverage_floor_window_ms` before expiry (quadratic ramp,
  `floor_index_at_ms`).
- **Mint creation invariant:** `floor_shares × terminal_floor_index < quantity ×
  liquidation_ltv` — the terminal floor stays strictly below the liquidation
  point. Fees are transaction costs, not floor value.
- `floor_shares = financed_amount / open_floor_index` is the durable per-order
  floor accumulator.

## NAV and valuation

- Live valuation reads raw aggregate range and floor facts
  (`strike_nav_matrix::live_value`). `expiry_market::pool_nav` uses the aggregate-
  clamped liability only for its backing assert, then returns free cash
  (`cash − rebate_reserve`) plus the raw totals to PLP.
- PLP computes the active mark and uncertainty band from one limited-recourse
  bucket split. Verified and unscanned buckets each clamp their own
  `range − floor`; the supply mark uses the optimistic endpoint, and the
  withdraw fee charges pro-rata against `band = min(unscanned_floor,
  unscanned_range)`. The **withdraw mark ≤ supply mark**, and the supply mark is
  an upper bound on true recoverable value.

## Settlement

- A settled order pays `quantity − terminal_floor` if the settlement price is in
  `(lower, higher]`, else 0 (`close_settled_order`), with `terminal_floor =
  floor_shares × terminal_floor_index`.
- `materialize_settled_liability` is idempotent and caches the exact terminal
  liability at the settlement price; live indexes survive until privileged
  compaction.

## Liquidation

- An order is liquidatable when `range_probability × quantity ≤ (floor_shares ×
  current_floor_index) / liquidation_ltv`. Only leveraged orders (`floor_shares >
  0`) are ever liquidatable.
- Liquidation is **permissionless and bounded** per call by a candidate budget.
  Liquidated orders become tombstones until the holder redeems the worthless
  position and clears it.
- Liquidation **priority is encoded in the order-id high bits**: the packed
  quantity field stores the complement (`U32_MASK − quantity_lots`), so an
  ascending `u256` sort over raw order ids liquidates larger quantities first,
  then by floor shares, then by open time. The book never decodes a field.

## Mint admission

- Execution price `entry_probability + fee_rate` must lie in `[min_ask_price,
  max_ask_price]`.
- Leverage ∈ {1×, 1.5×, 2×, 2.5×, 3×}, with price-tiered caps (below one threshold
  only 1× is allowed; below a second, ≤2×).
- `net_premium = entry_probability × quantity / leverage ≥
  min_net_premium`; the pool seeds the remainder (`financed_amount`).

## Order encoding

- The order id packs, in 232 bits: quantity lots (u32), floor shares (u64),
  opened-at ms (u48), lower and higher boundary index (u24 each), and an
  expiry-local sequence (u40). The quantity field stores the complement, so an
  ascending sort is larger-first.
- Mint-admission policy (leverage tiers, price thresholds) is **not** part of
  order decoding or structural validation — a future policy change must never
  invalidate an existing packed id.
- Order ids are scoped by `(expiry_market_id, order_id)` and do not encode market
  lifecycle (expiry) in the id.

## Fees

- Trade fee = `fee_rate × quantity`, where `fee_rate = max(base_fee × √(p·(1−p)),
  min_fee) × expiry_ramp_multiplier`; the Bernoulli term is 0 at `p ∈ {0, 1}`.
- The builder fee and the gas-congestion surcharge are add-ons; both are excluded
  from the trading-loss rebate fee basis (only the trade fee counts).
- PLP withdrawal carries an uncertainty-band fee (`withdraw_fee_alpha ×
  aggregate_band × lp_share`, capped at the payout), retained in idle for the LPs
  who remain.

## Lifecycle

- Two orthogonal axes — oracle status (active → pending-settlement → settled) and
  pool/storage (registered → deactivated → compacted) — plus three independent
  gate flags (`trading_paused`, `mint_paused`, `valuation_in_progress`). "Paused"
  is not a state.
- Trading pause blocks new risk creation; exits, settlement cleanup, and
  valuation are gated only by the valuation lock.
- Compaction is **pool-coordinated**: it returns LP cash to the pool, unregisters
  the expiry from active valuation, and leaves the expiry as payout/rebate escrow
  only — there is no expiry-only path that can strand capital.

## Configuration

- Admin-tunable values have a stored field plus a `default_*` seed and an
  `assert_*` bound in `config_constants`, snapshotted per object at creation;
  later admin updates do not reprice active markets. Upgrade-required values stay
  as constants/macros read directly. `min_*`/`max_*` bounds are upgrade-required
  validation envelopes, not config fields. See
  [configuration.md](./configuration.md).

## Cross-object binding

- `ExpiryMarket` validates that the market, oracle, Pyth source, and range key
  belong together before composing them for trading. The registry enforces one
  Pyth source per feed.

## Rounding

- All fixed-point math is at 1e9 scale; `math::mul` and `math::div` round **down**
  uniformly.
- **Solvency rests on bit-identical pairing:** where a reserve and a payout derive
  from the same quantity, they use the *identical* rounding so they are bit-equal
  (e.g. `materialize_settled_liability` and `close_settled_order` both compute
  `mul(floor_shares, terminal_floor_index)`), so a reserve can never be short of
  the payout it backs.
- Dust is biased to the protocol/LP pool, never against solvency: payouts round
  down (the holder absorbs ≤1 unit), and the aggregate-NAV floor rounds down so
  dust cannot abort valuation. One deliberate carve-out: incentive USD valuation
  rounds **up**, marking incentive value conservatively high for supply pricing.
  See the "Rounding and dust" section of [../risks.md](../risks.md).
