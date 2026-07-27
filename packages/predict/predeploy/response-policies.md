# Predict Response-Policy Register

Updated 2026-07-27. This is the tracked register of **settled response-policy
decisions**: for each degenerate or adversarial state the protocol can reach,
the behavior someone deliberately chose, why, and the tests that pin it.

`open-items.md` tracks work that is still open; when an item closes, the
*decision* it produced graduates into an entry here instead of surviving only
in a commit message — this register is the pipeline's single terminal for
judgment calls, and at most one entry resolves a given item. Measured evidence
behind entries lives as dated records in `evidence/`. `docs/risks.md` is the
public disclosure and must describe the behavior recorded here — a `risks.md`
claim about failure behavior that has no register entry (or contradicts one)
is a finding. The protocol-wide rounding policy (R1–R3) also lives here, at
the end of the register.

## The discipline

- **Classify the violated variable by controller.** Protocol-controlled values
  (supply, escrow, accounting) can carry hard invariants. Market-controlled
  values (NAV, prices, post-loss balances) cannot — no assert forbids a loss
  that already happened off-code. For market-controlled states the only design
  freedom is the *response*.
- **Pick the response from the blast-radius ladder:** `abort` (single-user,
  user-recoverable actions only) → `skip/carry` (batch, keeper, and mandatory
  paths — one degenerate element must not stall the machine) → `pause` (only
  with an explicit recovery path) → `designed wind-down` (economically dead
  states). A state-triggered abort in a shared/mandatory path over a
  market-controlled variable is a liveness defect, not a safety feature.
- **Accepting a risk is legitimate only as an artifact:** recorded here with
  reasoning, a risk profile, pinning tests, and a reopen condition.
- **Risk profiles are measured, not guessed, where possible.** Entries whose
  reachability is asserted from intuition are tagged `BEST-GUESS`; the harness
  (`packages/predict/harness/`) is the tool for replacing that tag with a
  measured profile (reachability cost, window width, loss sequence).
- **Deleting or weakening a guard requires a duty inventory.** A guard's stated
  purpose is a claim, not an inventory — enumerate what else it incidentally
  bounds (arithmetic headroom, ratio sanity, downstream cast safety) before
  removal, and record the removal as an entry here. Precedent: the P-1 circuit
  breaker was removed on a fairness argument and was silently also the only
  u64-headroom bound on LP fill math (RP-1/RP-2).

## Entry schema

Each entry records: **Trigger state** / **Controller** / **Blast radius** /
**Response** (ladder rung) / **Reasoning** / **Risk profile** (`MEASURED` or
`BEST-GUESS`) / **Pinning tests** / **Reopen when**.

---

## RP-1: The flush executes at any exact NAV mark (price circuit breakers removed)

- **Trigger state:** frozen flush mark implies a PLP price outside the former
  `[0.01, 100]` DUSDC band, or a pool NAV below the former dust floor.
- **Controller:** market — pool NAV is set by trading outcomes; supply by fill
  history. `total_supply ≤ k × pool_value` is not a maintainable invariant.
- **Blast radius:** the mark is computed inside `finish_flush`, the single
  mandatory pool-wide PTB (valuation, sweeps, LP fills).
- **Response:** proceed — no mark-level guard. Degeneracies are owned at the
  fill site (RP-2). (Commit `cc67ed9f`, resolving P-1.)
- **Reasoning:** the mark is the exact pool NAV, so any price it implies is
  fair by construction; the deleted `assert_plp_price_in_bounds` was a
  state-triggered abort over a market-controlled variable with no on-chain
  recovery path — it bricked the flush in legitimate states (100x
  appreciation, post-drawdown recapitalization) until package upgrade.
- **Risk profile:** `BEST-GUESS`. Residual found 2026-07-02: the deleted guard
  was incidentally the only u64-headroom bound on fill math; RP-2 now owns
  those fill-site degeneracies by classifying non-executable queue heads before
  mutating pool state.
- **Pinning tests:** `pool_valuation_flow_tests.move` —
  `finish_flush_with_zero_pool_nav_and_empty_queues_succeeds`,
  `finish_flush_with_low_plp_price_and_empty_queues_succeeds`,
  `finish_flush_with_high_plp_price_and_empty_queues_succeeds`.
- **Reopen when:** the fill-site policy (RP-2) turns out not to cover a
  mark-level degeneracy.

## RP-2: Non-executable LP queue heads at the drain — refund

- **Trigger state:** at the frozen mark, the head request's fill is not
  executable: the implied PLP price is outside `[0.01, 100]` DUSDC/PLP,
  supply would mint zero shares, withdraw would pay zero, or the computed
  quote does not fit in u64.
- **Controller:** market (the mark) × user (request size). The one
  protocol-controlled action in the loop is share issuance itself.
- **Blast radius:** `lp_book::drain` runs inside `finish_flush`; an aborting
  fill aborts the entire pool-wide flush until the request owner voluntarily
  cancels. A hostile or absent owner stalls it indefinitely.
- **Response:** auto-cancel-and-refund. `lp_book::drain` classifies the head
  before joining supply cash, minting PLP, burning PLP, or withdrawing idle
  cash. A non-executable head is popped, its escrow is returned to the request
  recipient with `RequestCancelled`, and the flush continues. Filled and
  protocol-refunded heads both count against that queue's per-flush budget and
  toward `FlushExecuted.requests_processed`. A withdrawal whose quote is valid
  but exceeds idle is different: it stays queued, consumes no withdraw budget,
  and the withdrawal pass stops FIFO-until-dry.
- **Reasoning:** the drain must be total over request content. Beyond the
  stall, a fill that *fits* at a dust mark mints ~1e18 shares; `total_supply`
  only shrinks via withdrawals, so the inflated supply persists after NAV
  recovery, permanently pinning PLP price at dust and widening the overflow
  band. Refunding fills at inexecutable marks enforces the one maintainable
  direction of the old invariant: the protocol never *manufactures* the
  degenerate ratio, even though it cannot forbid NAV collapse.
- **Risk profile:** `BEST-GUESS` — organic reachability requires near-total LP
  wipeout (pool value in a micro-DUSDC band at the flush instant) and cannot
  be cheaply forced (attacker must win oracle-priced bets). The asymmetry is
  the ratchet: improbable per flush, irreversible once. Harness campaign
  candidate: drive NAV collapse and measure the window width and ratchet
  onset.
- **Pinning tests:** `lp_book_tests.move` —
  `priced_supply_with_zero_pool_value_refunds`,
  `priced_supply_that_rounds_to_zero_shares_refunds`,
  `priced_withdraw_that_rounds_to_zero_payout_refunds`,
  `supply_at_min_executable_plp_price_fills`,
  `supply_below_min_executable_plp_price_refunds`,
  `supply_at_max_executable_plp_price_fills`,
  `supply_above_max_executable_plp_price_refunds`,
  `oversized_supply_that_exceeds_u64_shares_refunds`,
  `non_executable_supply_refunds_spend_supply_budget`,
  `non_executable_withdraw_refunds_spend_withdraw_budget`, and
  `withdrawals_stop_when_idle_is_dry_and_carry`. The fixed_math package
  separately pins the checked mul-div helpers that classify u64-fit.
- **Reopen when:** request-limit semantics change in a way that interacts with
  protocol-triggered refunds, or a new LP request type adds another
  non-executable fill mode.

## RP-3: `lp_pool_value` floors at zero

- **Trigger state:** the sticky held-out total (`exclusion +
  pending_protocol_profit`) exceeds a collapsed gross pool value.
- **Controller:** market (gross collapses via losses); the exclusion basis is
  protocol accounting but intentionally does not shrink on withdrawals.
- **Blast radius:** the NAV read feeding the mandatory flush.
- **Response:** `skip/carry`-shaped clamp — `saturating_sub` to 0, never
  abort. LP-attributable value reads as zero until marks recover; the
  downstream consequence (zero-value fills) is RP-2's problem, not this
  read's.
- **Reasoning:** LP value cannot be negative; an abort here would brick the
  flush on an exogenous state. NAV==0 is a real reachable state, not an
  underflow guard.
- **Risk profile:** `BEST-GUESS` (requires gross ≤ held-out, i.e. severe
  drawdown after a profitable period).
- **Pinning tests:** partial — `pool_valuation_flow_tests.move` ·
  `finish_flush_with_zero_pool_nav_and_empty_queues_succeeds` proves the flush
  survives a NAV==0 mark, but reaches it via an underwater market
  (`setup_underwater_market(0)`, gross=0, exclusion=0), so it does **not**
  exercise the sticky-exclusion clamp's own trigger (held-out total exceeding a
  positive-then-collapsed gross). The clamp direction is therefore not directly
  pinned; add direct sticky-exclusion coverage before changing this clamp.
- **Reopen when:** the exclusion basis becomes non-sticky, or RP-2's
  implementation changes what a zero mark means for the queues.

## RP-4: Past-expiry-but-unsettled market blocks the flush (no substitute mark)

- **Trigger state:** an active market is past expiry but Propbook has no
  normalized spot at the exact expiry millisecond yet.
- **Controller:** external — resolution relayer liveness (Pyth Lazer
  resolution endpoints supply the exact-timestamp print), and Pyth aggregate
  liveness at the boundary, which no relayer can compensate for.
- **Blast radius:** the whole flush aborts while the market is in the window.
- **Response:** `pause`-with-recovery — abort and retry; the recovery path is
  the permissionless exact-ms insert followed by `try_settle`. Standalone cash
  rebalance is a no-op in the window, and the keeper does not flush until the
  transition succeeds. Deliberately **no substitute
  mark**: a settlement-dependent market has no well-defined true value, and
  the single mark prices both queue directions — contribute-0 dilutes
  incumbents on supply, free-cash overpays withdrawals.
- **Recovery is not guaranteed.** `pyth_feed::insert_at` rejects a print
  generated more than `constants::max_settlement_carry_ms` (2s) before its
  envelope (`ESettlementCarryExceedsWindow`). Pyth publishes exactly one
  envelope per tick and never revises it, so a boundary whose canonical print
  was carried from beyond that window has no admissible settling row and never
  will: the retry loop above never terminates and the pool's flush is blocked
  permanently. The bound is deliberate — settling on an arbitrarily stale mark
  is the worse outcome, and the window is compiled because the insert is
  permissionless and first-writer-wins. Both window edges are pinned in
  propbook: `packages/propbook/tests/pyth/pyth_feed_tests.move` —
  `insert_at_carry_within_window_claims_the_key`,
  `insert_at_carry_beyond_window_aborts`.
- **Reasoning + evidence:** `evidence/rp4-settlement-liveness.md` (accepted
  operational assumption, testnet evidence); grid-snap at creation makes the
  key representable, resolution endpoints make it producible **when Pyth
  generated a print within the carry window of that boundary**.
- **Risk profile:** `UNMEASURED` for the unrecoverable case — the evidence in
  `evidence/rp4-settlement-liveness.md` predates the carry bound and does not
  cover it. Boundary carry-availability (how often Pyth carries a price across
  a grid boundary for longer than the window) is not yet measured; measuring it
  on testnet is a mainnet launch blocker. Residual = prolonged relayer outage
  blocks LP fills pool-wide, plus permanent pool-wide flush blockage on a
  beyond-window boundary; both disclosed in `risks.md`.
- **Pinning tests:** `settlement_flow_tests.move` —
  `try_settle_without_exact_expiry_spot_returns_false_without_mutation`,
  `expired_unsettled_standalone_rebalance_moves_no_cash`, and
  `explicit_settlement_unblocks_pool_valuation_sweep`.
- **Reopen when:** settlement-v2 introduces a valuation-safe representation
  for unsettled past-expiry markets, or boundary carry-availability
  measurement justifies an admin settlement fallback or a different window.

## RP-5: BS-vs-Pyth basis/deviation circuit breakers removed

- **Trigger state / threat:** a compromised or adversarial Block Scholes
  operator steering live pricing away from the Pyth spot.
- **Controller:** external (oracle operator).
- **Blast radius:** every live price — entry prices, NAV marks, liquidation.
- **Response:** accept + disclose (commit `057f9565`). The cross-feed
  deviation guards are gone; the static pricing-safe envelope remains
  (positive spot/forward, bounded basis, bounded SVI magnitudes, `|rho| ≤ 1`,
  sigma band, positive minimum total variance). A correct-but-adversarial
  source can steer prices anywhere inside that envelope.
- **Reasoning:** the deviation guards were a state-triggered abort over an
  externally-controlled variable — a divergence event (or a legitimate fast
  market) bricked pricing with no recovery path, and staleness-vs-authenticity
  cannot be resolved by a consumer-side band. The real mitigation is the
  verifier: permissionless BS pushes are not production-safe until the stub is
  replaced (deploy gate S-4).
- **Risk profile:** `BEST-GUESS`; bounded only by the envelope. Gated by S-4
  before value-bearing deployment.
- **Pinning tests:** not yet catalogued — fill in when this entry is next
  touched.
- **Reopen when:** the production verifier lands (S-4) — revisit whether any
  cross-feed sanity band is then worth reintroducing as a skip, not an abort.

## RP-6: The flush is privileged, not permissionless

- **Trigger state / threat:** a permissionless flush would let anyone time the
  valuation to a favorable oracle state and capture mispriced LP fills.
- **Controller:** protocol (who may start a flush is protocol-controlled — so
  this one *is* enforceable as an invariant).
- **Response:** gate the flush behind the revocable `MarketLifecycleCap`; the
  accepted cost is a trust assumption — the operator chooses the valuation
  instant (never the price: the mark is the exact NAV at that instant) and
  must run flushes for LP liveness.
- **Reasoning + disclosure:** `docs/risks.md` "The privileged flush"; audit
  lens L8 (NAV-timing manipulation closed by privilege).
- **Risk profile:** `BEST-GUESS` — operator-timing abuse bounded by mark
  exactness; liveness depends on flush cadence (disclosed).
- **Pinning tests:** not yet catalogued — fill in when this entry is next
  touched.
- **Reopen when:** a continuous/permissionless valuation design (e.g.
  commit-reveal or TWAP mark) is ever proposed.

## RP-7: Trading pause blocks new risk creation only

- **Trigger state:** `PauseCap` pauses trading (globally or per-market).
- **Controller:** protocol (pause operator).
- **Response:** mint paths abort; exits (redeem), settlement cleanup, and
  valuation stay live and are governed only by the valuation lock. One-way
  pause; recovery is admin-side.
- **Reasoning:** blocking exits during an emergency converts a safety switch
  into a user-fund trap; only new risk creation needs to stop.
- **Risk profile:** n/a (semantics decision, not a probabilistic risk).
- **Pinning tests:** not yet catalogued — fill in when this entry is next
  touched.
- **Reopen when:** pause semantics are intentionally changed.

## RP-8: Deferred protocol profit — defer-and-carry (D033)

- **Trigger state:** a recognized protocol cut is owed but the backing cash
  has since been redeployed (`available < owed` at realization time).
- **Controller:** market (cash moves with trading between recognition and
  realization).
- **Blast radius:** a bare `balance.split` would underflow-abort the
  permissionless cleanup or the pool-wide flush that realizes the cut.
- **Response:** `skip/carry` — accrue in `pending_protocol_profit`, split
  `min(pending, available)`, carry the remainder to cash-abundant branches;
  trader/principal backing outranks protocol revenue; the carried amount is
  held out of NAV.
- **Reasoning:** liveness class distinct from rounding-dust underflow
  (Rounding policy § R1 below); seniority must be explicit so the deferred cut
  never preempts funding.
- **Risk profile:** n/a (accounting-liveness policy).
- **Pinning tests:** not yet catalogued — fill in when this entry is next
  touched.
- **Reopen when:** profit-realization flow is redesigned.

---

## RP-9: Congestion surcharge charges against the pre-trade EWMA estimate

- **Trigger state:** a trade lands at an outlier gas price (congestion spike or
  trader-chosen gas) on either charging path — mint or live redeem.
- **Controller:** market — gas price is trader/network-chosen; the protocol only
  chooses the ordering of charge vs estimate update.
- **Blast radius:** per-trade fee only (the surcharge is additive and
  single-user); no shared-path liveness interaction.
- **Response:** charge first, then fold the observation
  (`expiry_market::ewma_penalty`) — a deliberate ordering divergence from
  DeepBook core, which folds first and so tests each observation against a
  distribution that already contains it.
- **Reasoning:** detect-then-update is the standard anomaly-test order (the
  spike is judged against the prior distribution, not diluted by itself), and
  it makes the public quote surface exact: `quote_mint` /
  `quote_mint_for_account` compute the same pre-fold penalty a same-state,
  same-gas-price mint charges. Consequence: the surcharge fires more readily at
  spike onset than under core's ordering; sustained spikes converge to the same
  behavior. The first-observation variance-poisoning weakness
  (`docs/concepts/fees-and-rebates.md` § 4) is unchanged.
- **Risk profile:** `BEST-GUESS` — spike-onset firing frequency not measured
  (the penalty is disabled by default).
- **Pinning tests:** `extreme_first_observation_suppresses_penalty_for_later_trades`
  (ewma_tests, charge-then-fold narrative),
  `ewma_penalty_included_in_quote_and_mint_debits_exactly`
  (quote_mint_tests, nonzero pre-fold penalty quoted and charged identically in
  one transaction),
  `quote_matches_independent_costs_and_mint_debits_exactly_all_in_cost`
  (quote_mint_tests, quote equals the debit with the penalty term at zero).
- **Reopen when:** the penalty is enabled in production and measured firing
  rates diverge materially from intent, or a redeem-side quote lands (DBU-513
  scope) and wants different redeem semantics.

---

## RP-10: Large atomic PTBs are cost-amplified by transaction-level metering — accept + disclose (resolves C-3)

- **Trigger state:** a router, keeper, or integrator builds a large
  multi-command PTB of leveraged mints/redeems; per-command computation cost
  grows with command position / accumulated transaction state, so the PTB hits
  the 5M computation-unit wall far below N × standalone cost.
- **Controller:** external — Sui's per-transaction metering, not a Predict code
  path. No contract change alters it; raising the gas budget does not bypass
  the computation wall.
- **Blast radius:** the oversized transaction only — it aborts on OOG with no
  state change; normal one-op user flows are unaffected. The same metering is
  a cost term inside the mandatory flush PTB, tracked separately under C-1's
  joint valuation budget.
- **Response:** accept + disclose (`docs/risks.md` § Batched transactions).
  Integrators chunk batches instead of assuming linear scaling. Scan-once
  caching inside Predict was evaluated and rejected as low-yield: the
  amplification is not primarily Predict's logical work.
- **Reasoning:** the discriminator run was decisive — a leveraged mint appended
  after twenty 1x mints (which never write the liquidation book) amplified
  ~20.2×, ruling out liquidation-book page dirtying; the mechanism is
  transaction-level command-position accumulation and applies to large
  multi-command PTBs generally.
- **Risk profile:** `MEASURED` on localnet (two replicated runs, harness E4):
  ~110–150 leveraged mints/PTB atomic ceiling; a 100-mint PTB ≈ 68% of the
  wall. Findings: `evidence/c3-mint-batch-2026-07-01.md`. Magnitude is
  book- and transaction-shape-dependent — localnet gives mechanism and
  direction, not a permanent production multiplier; flows designed near the
  ceiling should measure, not assume.
- **Pinning tests:** not yet catalogued — platform metering behavior, not
  pinnable in Move unit tests by nature; the evidence is the harness finding
  linked above (the `mint-batch` strategy, formerly experiments-ledger E4).
- **Reopen when:** Sui's metering model changes materially, or a production
  measurement diverges from the localnet ceiling enough to invalidate the
  integrator guidance.

---

## RP-11: Trading-loss rebate — claim-time stake + self-incentivized permissionless cleanout (resolves P-9)

- **Trigger state:** a settled market has accounts with unresolved trading-loss rebates (open
  settled positions + an unresolved `ExpiryTradingSummary`); the rebate is priced at the account's
  `active_stake` read at CLAIM time (`expiry_market::claim_trading_loss_rebate`), and expiry cash stays reserved
  until each account is resolved.
- **Controller:** protocol (the resolution path + the app-auth gate) × user (their standing stake
  and whether they self-claim). The cleanup TRIGGER is permissionless.
- **Blast radius:** per account (the rebate amount) plus the expiry's reserved cash, released to
  the pool only as accounts resolve. No shared-path liveness: an unresolved account strands only
  its own reserve, which is self-correcting (returns to the pool whenever a cleanout runs).
- **Response:** accept — (a) the rebate is priced at claim-time active stake, and (b) resolution +
  cash release rely on the permissionless `redeem_settled_permissionless` +
  `claim_trading_loss_rebate_permissionless` cleanout, which is SELF-INCENTIVIZED (a keeper/MEV bot
  is paid the storage rebate to run it) rather than on any protocol-run keeper. No contract change;
  the mint-time stake-snapshot fix is deliberately NOT taken.
- **Reasoning + evidence:**
  - The claim-time-stake leak (P-9, now resolved) is structurally unreachable for every current-cadence market:
    lazy stake activation (`roll_active_stake`, one epoch) means stake added mid-market cannot
    activate before the promptly-swept claim inside a sub-epoch (1m/5m/1h) market. Even in a
    hypothetical multi-epoch option the leak is bounded by `rate × fees`, captures at most the
    discount half of staking (`rate = max_fee_discount = 0.5`), and needs a genuine 100k+ DEEP
    commitment (retail-excluded). The permissionless claim-to-deny grief has zero payoff under the
    same gate. `evidence/p9-stake-abuse-2026-07-07.md` (analytical, config-derived).
  - The cleanout is self-incentivized: MEASURED on localnet, the one-PTB cleanout net gas is
    negative at every account size (−6.3M MIST at N=1 → −66M MIST at N=20; `net(N) ≈ −3.43M −
    3.14M·N`) — freeing the settled positions' storage rebates ~3.29M MIST/position against ~0.1M
    compute. No up-front fee / summary padding needed (E3 min-fee = 0).
    `evidence/p9-cleanout-gas-2026-07-07.md`.
  - The self-incentive holds for LIQUIDATED accounts too — the archetypal loser, which takes the
    zero-payout liquidated arm of `redeem`. MEASURED (two-marginal fit, R²=0.999):
    `net = −3.02M − 4.47M·nLiquidated − 3.19M·nSurvived` MIST — both marginals strongly negative and
    the per-**liquidated**-position refund (−4.47M) EXCEEDS the per-survivor (−3.19M), because a
    liquidated redeem frees comparable-or-more storage while creating less new storage (zero/floor
    payout). ⚠ This fit was measured on the since-removed tombstone model, where liquidation wrote
    a book-side tombstone that the cleanout later freed. The derived-state model (DBU-592) frees the
    liquidated order's book storage AT LIQUIDATION instead of at cleanout, so the liquidated-account
    cleanout net gas is unmeasured under the shipped model and needs re-measurement — the
    magnitude and even the liquidated-vs-survivor ordering are unverified.
    `evidence/p9-cleanout-gas-liquidated-2026-07-08.md`.
  - The rebate CLAIM is self-incentivized on its OWN, not just inside the bundle — so a searcher
    resolves it even for non-owed (winner) accounts whose owner has no self-claim incentive, releasing
    their reserve to the pool. MEASURED: standalone `claim_trading_loss_rebate_permissionless` net
    −0.95M MIST; its in-bundle marginal −2.5M. `evidence/p9-claim-marginal-2026-07-08.md`.
- **Risk profile:** `MEASURED` — cleanout self-incentive measured on localnet for surviving (5-point
  sweep), liquidated (two-marginal fit), AND the standalone/marginal rebate claim, 0 fails/retries;
  the stake-abuse bound is analytical (config + the ~24 h epoch activation gate). Residual: a lagging
  cleanout leaves an account's reserve in the expiry — self-correcting, not a loss. Findings:
  `evidence/p9-cleanout-gas-2026-07-07.md`, `evidence/p9-cleanout-gas-liquidated-2026-07-08.md`,
  `evidence/p9-claim-marginal-2026-07-08.md`, `evidence/p9-stake-abuse-2026-07-07.md`.
- **Pinning tests:** `settlement_flow_tests.move` — `rebate_claim_requires_settled_market` (:477)
  and `rebate_claim_with_open_position_aborts` (:496) pin the claim preconditions (settled market,
  no open positions); `deauthorized_predict_app_blocks_permissionless_rebate_claim` (:320) and
  `owner_auth_rebate_claim_survives_predict_app_deauth` (:334) pin the app-auth gate. Those two run
  over the setup fixture `prepare_settled_loss_with_inactive_rebate_stake` (:567), which stages the
  inactive-rebate-stake state but asserts nothing itself. The claim-time-stake *pricing* (active
  stake read at claim, `expiry_market::claim_trading_loss_rebate`) is not pinned by a dedicated Move assertion — it
  rests on the analytical bound (`evidence/p9-stake-abuse-2026-07-07.md`); likewise the gas-incentive
  is platform metering (like RP-10), pinned by the harness evidence above, not a Move unit test.
  Audit provenance: finding 8b5d5f.
- **Reopen when:** the tombstone removal (DBU-592) ships — re-run `cleanout-gas-liq` to re-measure
  the liquidated-account cleanout net gas under the derived-state model (the order's book storage is
  now freed at liquidation, not at cleanout, so the prior liquidated fit above no longer describes
  the shipped model); OR a market with life ≥ ~1 Sui epoch (a long-dated / multi-epoch option) ships
  (re-measure the late-stake exposure; reconsider snapshotting benefit-relevant stake at mint); OR
  the settled-redeem storage footprint shrinks / Sui storage pricing drops enough that the cleanout
  net gas turns positive (re-run the sweep; apply the E3 up-front-fee formula); OR
  `trading_loss_rebate_rate` is set materially above `max_fee_discount`.

---

## RP-12: LP request limit misses carry for three flush attempts (resolves P-7)

- **Trigger state:** a queued LP supply or withdraw request reaches the head of
  its FIFO queue during a flush, the frozen mark is executable, but the quoted
  output is below the request's minimum output (`min_plp_out` for supply,
  `min_dusdc_out` for withdraw).
- **Controller:** market (the frozen mark) × user (the request-time limit). The
  protocol controls only the retry policy once the request is at the head.
- **Blast radius:** `lp_book::drain` runs inside `finish_flush`; blindly filling
  a limit-missing request gives the user unbounded slippage, while immediately
  cancelling on the first miss makes ordinary mark volatility a poor LP UX.
- **Response:** skip/carry with bounded expiry. A live limit miss increments the
  request's miss count, emits `RequestLimitMissed`, counts against that queue's
  per-flush processed budget, leaves the request at the head, and stops that
  queue for the flush. On the third miss, the request is protocol-cancelled and
  refunded with `RequestCancelled.reason = 2` (`limit expired`) instead of
  carrying indefinitely. The user cannot modify a queued limit; changing price
  protection means cancelling and submitting a new request.
- **Reasoning:** carrying across a small fixed number of flush attempts absorbs
  ordinary NAV noise without forcing users to monitor and re-submit after every
  miss. Expiry bounds queue blockage: an overly tight or stale limit cannot
  permanently block later FIFO requests. The fixed value is upgrade-required
  (`lp_request_limit_flush_attempts = 3`) rather than per-user configurable to
  keep the public surface and queue semantics simple pre-deploy.
- **Risk profile:** `BEST-GUESS` — the UX win depends on actual flush cadence
  and NAV volatility. The liveness risk is bounded by the three-attempt expiry,
  and users retain the explicit cancel path while pending.
- **Pinning tests:** `lp_book_tests.move` —
  `supply_limit_miss_carries_then_fills_when_mark_improves`,
  `supply_limit_expires_after_three_misses`,
  `withdraw_limit_miss_carries_then_fills_when_mark_improves`, and
  `withdraw_limit_expires_after_three_misses`.
- **Reopen when:** flush cadence changes materially, the retry count becomes
  user-configurable, or LP request limits become mutable in-place.

---

## RP-13: Budget-bias mint sizing searches the premium relation; oversized budgets saturate at the lot cap (`ENetPremiumBudgetTooHigh` removed; resolves DBU-566)

- **Trigger state:** a `mint_exact_amount` (or budget-bias quote) net-premium
  budget large enough that the fitting quantity exceeds the lot cap — or, in
  the removed design, large enough that a u64 intermediate of the algebraic
  inverse overflowed (~$18,446 / leverage).
- **Controller:** user — the budget is a caller-chosen primitive on a
  single-user action; the read-only quotes accept any u64 budget.
- **Blast radius:** the single mint transaction or quote; no shared or
  mandatory path.
- **Response:** proceed — sizing is a binary search over lot counts against the
  premium relation, with the lot cap (`order::max_quantity_lots`) as the search
  domain, so an oversized budget converges to the largest legal order instead
  of aborting. Every probe quantity is a legal order quantity and the premium
  relation only shrinks its input, so no intermediate can leave u64: the former
  guard's abort state is unrepresentable, not tolerated.
- **Duty inventory (guard removal):** the three `ENetPremiumBudgetTooHigh`
  asserts bounded only the removed algebraic inverse's own `(budget+1) *
  leverage` and `entry_value * scaling` u64 intermediates; those expressions
  were deleted with the inverse, and no downstream consumer read its raw
  (pre-lot-cap) result. Nothing else was incidentally bounded.
- **Accepted inaccuracy:** the search probes the single-floor fused premium
  `mul_div_down(p, Q, L)`, which over-estimates admission's two-floor charge by
  at most one premium unit, so sizing is conservative: the charged premium
  never exceeds the budget, and the fill is at most one lot short of the exact
  maximum. The lot bound is envelope-dependent, not intrinsic: one premium unit
  spans `leverage / entry_probability` raw quantity units, so it stays sub-lot
  only because `config_constants::min_min_entry_probability` floors the
  admissible entry band at 1% (worst reachable case ~152 raw units against the
  10_000-unit lot, at the 1% floor under the probability-scaled cap of the 10x
  template-leverage envelope). The probe >= charge dependency is one-sided and
  documented at the probe site in `strike_exposure::quote_mint_terms`.
- **Risk profile:** `BEST-GUESS` — the conservative edge is sub-lot-premium
  dust per mint; search cost is ~32 probes of two u128 ops, unmeasured against
  the BS pricing in the same call.
- **Pinning tests:** `mint_exact_amount_tests.move` —
  `oversized_budget_saturates_at_the_lot_cap_without_aborting` (u64-max budget
  quotes the lot-cap premium, the former abort domain),
  `budget_mints_largest_fitting_quantity_and_debits_its_exact_cost` and
  `budget_at_next_lot_premium_mints_the_next_lot` (sizing pinned from both
  sides at the exact ATM probability),
  `budget_fill_below_min_quantity_aborts` (fill floor);
  `mint_redeem_guard_tests::mint_exact_amount_below_min_quantity_aborts`
  (dust budget rejects on the floor). Untested — gap: the one-lot-conservative
  edge needs a rounding-lossy probability no current fixture pins.
- **Reopen when:** the premium relation changes shape (a fee folded into the
  budget, a rounding flip — the probe must move with it or the one-sided bound
  breaks), the `min_min_entry_probability` envelope floor is lowered (the
  one-lot fill bound dies with it), a measured gas profile shows the search
  matters, or a consumer needs the exact maximum fill at fractional leverage.

---

## RP-14: Exact spot products trust Propbook's exact-history key (`EReferenceTickTimestampMismatch` removed; resolves audit 914ecd)

- **Trigger state:** `pyth_feed::normalized_spot_at(requested_timestamp)` returns
  a read whose `source_timestamp_ms` differs from `requested_timestamp`.
- **Controller:** protocol dependency — Propbook owns exact-history insertion,
  lookup, and Pyth normalization semantics.
- **Blast radius:** reference-tick selection for one expiry market. Settlement
  already consumed the same exact lookup without repeating the timestamp check.
- **Response:** proceed — Predict trusts the Propbook exact-read contract and
  pricing's opaque `ExactSpotRead` retains only the optional normalized value.
- **Reasoning:** `oracle_lane::insert_at` keys `exact_reads` by the inserted
  read's `source_timestamp_ms`; `read_at(timestamp)` can return only the value
  stored under that exact key; and `pyth_feed::normalized_spot_from_read`
  preserves both timestamps. A mismatched timestamp is therefore
  unrepresentable without changing Propbook's source semantics.
- **Duty inventory (guard removal):** the deleted assert only re-checked that
  exact-key invariant. It did not bound spot value, arithmetic headroom,
  freshness, landing time, grid alignment, or market identity. Canonical-feed
  identity remains checked by `pricing::load_exact_spot_read`; missing or
  unnormalizable history remains `Option::none`; and no consumer used the
  discarded update timestamp.
- **Risk profile:** `BEST-GUESS` — unreachable by construction at current
  Propbook source; residual risk is semantic drift in that dependency, not an
  accepted reachable market state.
- **Pinning tests:** `reference_tick_tests.move` —
  `set_reference_tick_floors_spot_and_is_idempotent`,
  `set_reference_tick_missing_exact_history_aborts`, and
  `set_reference_tick_wrong_pyth_feed_aborts`.
- **Reopen when:** Propbook changes exact-history keying, `read_at`, or Pyth
  normalization semantics, or Predict begins using the exact product across a
  delayed boundary that requires update-time metadata.

---

## RP-15: Non-monotone active-book BS surfaces block NAV valuation

- **Trigger state:** during `current_nav`, the active payout tree asks for UP
  prices at increasing strike ticks and a fresh Block Scholes surface makes a
  higher strike price above a lower strike price.
- **Controller:** external — the BS surface publisher controls the shape inside
  Predict's pricing-safe envelope.
- **Blast radius:** one market's active book can abort that market's NAV read.
  Because pool flush uses one frozen mark for all LP supply and withdraw fills,
  this can block LP fills pool-wide until the surface is corrected.
- **Response:** abort and retry with a valid surface. The recovery path is the
  same operational path as stale or missing oracle data: publish a fresh,
  usable BS surface and rerun valuation.
- **Reasoning:** `strike_payout_tree::walk_linear` relies on active boundary
  prices being monotone. Skipping the market or carrying a partial mark would
  poison the single LP mark used for both supply and withdraw, while allowing
  the inverted segment through can overstate pool NAV.
- **Risk profile:** `BEST-GUESS` — reachability depends on the BS publisher
  sending an arbitrageable surface that also intersects the active book.
  Production safety depends on replacing the stub verifier before value-bearing
  deployment (S-4).
- **Pinning tests:** `pricing_guard_tests.move` —
  `price_memo_rejects_non_monotone_surface_over_active_ticks`; and
  `current_nav_flow_tests.move` —
  `current_nav_rejects_non_monotone_active_book_surface`.
- **Reopen when:** NAV valuation gains a safe per-market skip/carry design, the
  LP flush no longer uses one shared mark for both queues, or the production BS
  verifier proves monotonicity before the surface reaches Predict.

---

## RP-16: Protocol reserve is accrue-only; the cut is taken on booked terminal profit — accept + disclose (resolves P-8)

- **Trigger state:** an expiry materializes terminal profit
  (`pool_accounting::materialize_expiry_profit`, reached from a settled-market
  sweep or a settled rebate-claim residual return); the protocol's share (`protocol_reserve_profit_share`) is split from
  idle into `PoolVault.protocol_reserve_balance`, which has no
  split/withdraw/claim entrypoint in the scoped packages. Separately,
  cross-market sweep order is permissionless (`plp::rebalance_expiry_cash`), so
  a profitable expiry can be swept while an offsetting loss — settled but not
  yet swept, or still live — is not yet booked into `net_losses_to_fill`, and a
  cut taken at that moment is never clawed back.
- **Controller:** protocol (the materialization + loss-carry mechanism) ×
  anyone (sweep ordering is a permissionless trigger).
- **Blast radius:** LP-borne only. Reserve over-accrual per episode is bounded
  by `share × losses concurrently unbooked at the sweep`; no holder funds, no
  liveness path. The reserve itself is excluded from LP value at all times.
- **Response:** accept both properties + disclose (`docs/risks.md`
  § Liquidity-provider (PLP) risk). No withdraw path ships in this package:
  the reserve's eventual use (buy-and-burn, withdrawal, incentive recycling,
  solvency backstop) is deliberately undecided, and the entrypoint lands with
  the package upgrade that decides it — a purely additive upgrade, so nothing
  is reserved for it now. No cut-basis change ships either: the ordering
  effect is accepted as a timing property, not queued as a fix.
- **Reasoning:** cumulative materialized profit is structurally pinned to the
  running peak of booked net P&L (`net_losses_to_fill` ≡ peak − current booked
  net), so the lifetime cut equals the share of lifetime net whenever later
  profits refill the carry — a profit-first ordering front-loads the cut and is
  then repaid one-for-one by suppressed cuts on subsequent profits. A material
  front-load requires a mixed-sign sweep backlog AND a near-zero existing carry
  AND profit-first order; even with prompt sweeping there is a small
  ever-present window (roughly one settlement interval — coinciding cadence
  grids can settle a profit and a loss in the same window, and the booking
  order inside it is permissionlessly choosable), bounded by
  `share × losses settling in that window`. Residuals: LPs who exit between a front-loaded cut and
  the carry refill bear a small one-time timing transfer (suppliers inside the
  window pick it up), and the front-load becomes permanent only if the pool
  winds down or stays loss-making so the carry never refills. LP pricing is
  structurally unaffected: `plp::lp_pool_value` already excludes
  `share × max(0, live unrealized net − carry)` — the net-basis anticipation of
  the future cut — and already-materialized cuts have left the pricing basis.
- **Risk profile:** `BEST-GUESS` — the peak-of-booked-net invariant itself is
  algebraic (it follows from the carry algebra in `materialize_expiry_profit`,
  and the ordering example is direct computation: at a 20% share, sweeping
  +100 before an unswept −50 reserves 20 instead of 10, and the next +50 of
  profit refills the carry and reaches LPs uncut, repaying the difference);
  the best-guess half is reachability and magnitude — exposure scales with
  losses concurrent in a sweep window, so material exposure is backlog-shaped.
- **Pinning tests:** partial — `pool_accounting_tests.move` —
  `materialize_carries_loss_forward_before_recognizing_profit` pins the carry
  legs (the loss carries; subsequent profit materializes only above the
  carry), and `tests/flows/protocol_profit_deferral_tests.move` pins the
  idle-capped realization deferral. Untested — gap: the cross-market ordering
  leg (a profit-first sweep reserves the share of gross recognized profit);
  that pin lands with the unit-test rebuild in flight (DBU-599).
- **Reopen when:** a package upgrade adds the withdraw path (decide then
  whether over-accrued reserve reconciles to LPs before funds leave); or
  market shape makes mixed-sign sweep backlogs a normal state rather than an
  outage artifact (long-dated expiries, multi-hour settlement gaps); or a
  wind-down is contemplated while `net_losses_to_fill` is nonzero.

---

## RP-17: The NAV mark values a knocked-out order at its liquidated worth (resolves P-10)

- **Trigger state:** at the valuation prices, an active leveraged order's live
  gross value is at or below its knock-out threshold
  (`gross <= floor_shares / liquidation_ltv`) — the liquidatable band
  `(floor, floor/ltv]` plus the underwater tail — while a NAV mark is computed
  (every `current_nav`, including the flush lane `plp::value_expiry`).
- **Controller:** market (prices move orders into the band between keeper
  sweeps) × protocol (whether the mark prices those claims at holder value).
- **Blast radius:** the single frozen mark that fills both LP queues. Marking a
  liquidatable order at holder value (`range_value - floor`) understates
  recoverable value by up to the LTV buffer per order, diluting incumbent LPs on
  a same-flush supply and contradicting the exact-mark framing (RP-1; the
  NAV-mark directional invariant).
- **Response:** value the knock-out at its liquidated worth in the read-only NAV
  correction, without touching the book. `exact_live_liability` already walks the
  payout tree once and subtracts the leveraged floor correction
  (`liquidation_book::correction_value`); that correction now credits a
  knocked-out order's full `range_value` — using the same threshold the close
  flow and ambient sweep apply (`gross <= div(floor_shares, liquidation_ltv)`) —
  instead of the `min(range_value, floor)` floor cap, so the order's live
  liability marks at zero. The order is not liquidated here: the existing ambient
  sweep liquidates it on its own cadence, so valuation stays a pure read with no
  tree mutation, no event, and no per-flush kill pass. A book with zero
  knocked-out orders produces a correction identical to the prior formula, so the
  mark is unchanged for healthy books.
- **Reasoning:** the mark must never price a claim the protocol would not honor.
  Crediting the knock-out at its liquidated value removes the conservative band
  in the lane where the mark moves money (LP fills), matching what the sweep will
  realize, while keeping NAV a side-effect-free read. Deferring the actual
  liquidation to the sweep leaves a window where the mark anticipates a
  liquidation the book has not yet applied — the same window the sweep lag
  already carries, and one that moves no money, because the mark only sets LP
  fill prices, not holder payouts.
- **Residual:** the credit uses each order's per-order `range_value`, which
  differs from that order's aggregated payout-tree contribution by the
  boundary-aggregation rounding of P-13 (at most one raw unit per boundary), so a
  flush that credits a knock-out lands within P-13's band on the same side. This
  is the accepted P-13 residual, not a new class.
- **Risk profile:** `BEST-GUESS` — reachability depends on prices moving orders
  into the band between sweeps. Cost is the read-only scan over the active
  leveraged set that `correction_value` already walks on every valuation; no tree
  mutation, event, or extra traversal enters the C-1 budget, so the worst case is
  cost-identical to a healthy flush.
- **Pinning tests:** `current_nav_flow_tests.move` —
  `single_leveraged_order_above_floor` (a survivor above the band keeps the floor
  cap, so the correction is unchanged) and
  `single_leveraged_order_underwater_nets_to_zero` (the deep-underwater tail,
  which both formulas zero) constrain the endpoints. The band case `(floor,
  floor/ltv]`, where the credit differs from the old floor cap, still needs a
  dedicated pin on a high-variance surface (a leveraged order priced into the
  band marks at zero live liability, raising NAV above the floor-capped value);
  tracked as the follow-up test for this policy.
- **Reopen when:** the LP flush stops using one shared mark for both queues; or a
  product decision requires the book to be liquidated in-pass rather than by the
  sweep (reintroducing the mutation and its gas profile); or the P-13
  boundary-aggregation residual is closed and the credit must become exact.

---

## RP-18: Protocol-wide emergency freeze — reversible hard stop of the version-gated surface

- **Trigger state:** an exploit or incident requires halting the full
  version-gated Predict surface (mint, redeem, settlement, valuation, LP
  supply/withdraw, admin config) faster than a package upgrade allows, and the
  at-risk flow is not covered by trading-pause (which blocks only new risk
  creation, RP-7).
- **Controller:** protocol — a `PauseCap` holder engages it; the `AdminCap`
  lifts it.
- **Blast radius:** every version-gated flow — the same surface a package-version
  disable covers, reached because the freeze is folded into
  `protocol_config::assert_version`. Account-package custody withdrawals and
  builder-fee claims are not Predict-version-gated and stay available, so
  already-credited custody balances and earned builder fees remain withdrawable;
  unredeemed positions and pending LP-queue escrow are frozen (reversibly) until
  admin lifts it. The ungated bypasses
  (existence-level cap revocations, the watermark setter, and freeze/unfreeze
  themselves) stay available.
- **Response:** `pause`-with-recovery. Force-on via
  `registry::freeze_protocol_pause_cap` (one-way, `PauseCap`, bypasses the
  version gate like every kill switch); recovery is admin-side via
  `protocol_config::set_frozen(_, false)`, intentionally ungated so an engaged
  freeze is never unrecoverable without an upgrade.
- **Reasoning:** the only prior lever with this blast radius was a
  version-disable, triggerable and recoverable only by shipping a package
  upgrade — too slow under an active exploit, and `bump_version_watermark`
  cannot set the floor above the running version, so a pure-watermark freeze was
  impossible without an upgrade. Blocking Predict redeems (unlike RP-7) is
  intentional: a hard freeze must be able to stop a redeem/settlement-path
  exploit. The user-fund-trap concern RP-7 owns is bounded here because balances
  already in account custody stay withdrawable and recovery needs no upgrade. A
  one-way
  upgrade-to-resume variant was rejected — it would reimpose the upgrade cost the
  freeze exists to avoid.
- **Risk profile:** n/a (semantics decision, not a probabilistic risk).
- **Pinning tests:** `protocol_config_tests.move` —
  `frozen_blocks_version_gated_flow` (a gated flow aborts `EProtocolFrozen` while
  frozen) and `frozen_defaults_false_and_admin_toggles` (admin lifts the freeze
  while frozen — no unrecoverable brick); `registry_guard_tests.move` —
  `pause_cap_freezes_protocol` (`PauseCap` force-on + admin lift) and
  `revoked_pause_cap_cannot_freeze_protocol` (revoked cap rejected).
- **Reopen when:** freeze semantics are intentionally changed (a one-way variant
  is adopted, or custody/exit paths are brought under the freeze), or per-flow
  granularity beyond the single global gate is required.

---

## RP-19: Budget mint bounds all-in cost, not entry probability (resolves H-5)

- **Trigger state:** a budget-sized mint (`expiry_market::mint_exact_amount`)
  executes against an oracle that moved after the caller built the transaction,
  so the fill's price per contract and its fees differ from what the caller saw.
- **Controller:** market — the surface and the EWMA congestion state both move
  between build and execution, and neither is caller-controlled.
- **Blast radius:** one caller's own mint. No protocol-side or cross-user effect.
- **Response:** `abort` (user-recoverable single-user action). The entrypoint
  takes `max_cost`, the all-in ceiling on `net_premium + trader-paid fee +
  builder_fee + EWMA penalty`, and aborts `EMintCostAboveMax` when the fill would
  breach it. The cap is **required**: zero aborts `EMintCostCapRequired`, and no
  value disables it — the budget shape exists to bound spend, so a caller opting
  out of the total bound while asking for a bounded premium is incoherent. The
  entrypoint deliberately does **not** take a `max_probability` bound.
- **Reasoning:** `max_premium` bounds only the premium; fees and the congestion
  surcharge are charged on top, so before this the total withdrawal was unbounded
  on the one entrypoint whose entire purpose is bounding spend, and the surcharge
  is derived from recent flow — precisely the term that moves between build and
  execution. The probability half of H-5 is declined rather than deferred:
  `min_quantity` evaluated against `max_premium` already bounds price per
  contract from above (`max_premium / min_quantity`), so a separate probability
  argument would express the same constraint twice on a public signature that
  cannot be narrowed after deploy. `mint_exact_quantity` keeps both guards
  optional because it has no budget term to bound price against.
- **Risk profile:** n/a (bound semantics, not a probabilistic risk).
- **Pinning tests:** `mint_exact_amount_tests.move` —
  `budget_mint_at_exact_all_in_cost_cap_succeeds` (the cap equal to the fill's
  exact debit passes), `budget_mint_one_unit_over_all_in_cost_cap_aborts` (one raw
  unit below that debit aborts `EMintCostAboveMax`, breached only by the fee on
  top of an affordable premium), and
  `budget_mint_without_an_all_in_cost_cap_aborts` (zero aborts
  `EMintCostCapRequired`, not the breach code).
- **Reopen when:** the budget mint gains a sizing mode where `min_quantity` no
  longer bounds price per contract, or a quote surface lands that lets callers
  resolve entry probability at execution time.

---

## RP-20: Positive-variance and d2 guards move to the high-precision domain (resolves P-14)

- **Trigger state:** a live pricing evaluation whose total variance is positive
  but tiny — below `1e-9`, so it floored to zero at 1e9 — or whose `d2` magnitude
  grows without bound as `w` approaches zero.
- **Controller:** market. The SVI surface is vendor-published, and short-dated
  markets legitimately carry `w ~ 1e-8`; no on-chain check can forbid a small but
  genuine variance.
- **Blast radius:** every priced path on the affected market — mint, live close,
  liquidation threshold, and the NAV mark the pool-wide flush consumes. The
  aborting form is therefore a flush-liveness risk, not a single-user one.
- **Response:** the two guards keep their error codes but now evaluate in the
  1e18 domain the variance path computes in.
  - `ENonPositiveVariance` fires on the true sign of `a + b·inner` rather than on
    its 1e9 truncation, so a surface whose variance is positive but under `1e-9`
    prices instead of aborting. The previous abort was an artifact of the
    truncation, not a degenerate surface.
  - `d2` **saturates** at magnitude `8e9 + 1` instead of aborting when the
    quotient would overflow `u64`. `normal_cdf` and `normal_pdf` already saturate
    beyond `|8|`, so the cap is inside the domain where the result is already
    pinned to its limit; the arithmetic can no longer abort there.
- **Reasoning:** both changes only ever convert an abort into a priced result, on
  a path that is mandatory (the flush values every active market in one PTB). Per
  the blast-radius ladder, an abort over a market-controlled variable on a
  mandatory path is the response we most want to remove. Neither widens what the
  contract will *construct*: `assert_min_total_variance_positive` still rejects
  surfaces at pricer load in the 1e9 domain, unchanged by this work.
- **Risk profile:** the admitted new region is `0 < w < 1e-9`. Pricing there is
  well-conditioned in the new domain — the 1e18 variance carries about nine more
  significant digits than the value that used to floor to zero. The `d2` cap is
  defensive rather than observed: the load gate holds the analytical minimum
  variance at or above one raw unit at 1e9, which bounds `sqrt(w)` from below, and
  over 249,313 admissible sampled surfaces the largest unclamped `|d2|` was
  1.4e14 against a `u64` ceiling of 1.8e19. That is headroom, not a proof — `b`
  ranges to 100e9, so the rounding slack in `inner` is large enough in principle
  to drive `w` lower — so the cap stays and is pinned at its own inputs.
- **Pinning tests:** `pricing_guard_tests.move` —
  `low_variance_surface_prices_where_the_1e9_path_aborted` drives a loadable
  surface whose per-strike variance is positive but floors to zero at 1e9 (the
  region this policy admits) and asserts the independently generated digital;
  `d2_saturates_at_the_normal_clamp_instead_of_overflowing` drives the cap at the
  helper's scalar inputs, where a `w` of one raw unit at 1e18 makes the quotient
  exceed `u64` (unit-tests rule 4 — the guard is exercised at its own inputs
  because no admissible surface has been shown to reach it);
  `boundary_loaded_surface_with_nonpositive_per_strike_variance_aborts` still
  aborts (the surface it pins is negative on the true value, not only after
  truncation), and `zero_total_variance_aborts_at_load` pins the unchanged
  construction gate. Both new tests were mutation-checked: restoring the coarse
  1e9 rejection fails the first two, and deleting the cap fails the second.
- **Reopen when:** a surface is observed whose true total variance is positive
  but so small that `sqrt(w)` itself underflows the 1e9 result scale, or if the
  saturation cap is ever read by something other than `normal_cdf`/`normal_pdf`.

---

## RP-21: Unchanged SVI tuples roll down from their first source timestamp (resolves P-2)

- **Trigger state:** the Block Scholes publisher retransmits an unchanged
  normalized SVI tuple while time-to-expiry decreases, including inside the
  wider SVI freshness window near expiry.
- **Controller:** external × protocol clock — the publisher controls the
  parameter tuple and envelope cadence; elapsed time is objective on-chain
  state.
- **Blast radius:** every live quote, mint, redeem, liquidation, and NAV read
  for the tuple's expiry. Because a flush must value every active market, one
  affected expiry blocks the pool-wide flush and all queued LP fills. Exact
  settlement does not use SVI.
- **Response:** proceed with anchored remaining-time roll-down. Propbook keeps
  `params_timestamp_ms` fixed at the first accepted source timestamp carrying
  the current exact normalized tuple while advancing `source_timestamp_ms` and
  `update_timestamp_ms` on newer identical retransmits. Any normalized
  parameter change resets the anchor to that update's source timestamp.
  Predict computes
  `a_eff = sign(a) * floor(abs(a) * 1e9 * remaining_ms / anchor_tte_ms)` and
  `b_eff = floor(b * 1e9 * remaining_ms / anchor_tte_ms)`, both **at 1e18** with
  a `u256` intermediate, and hands them to the variance path in that domain;
  `rho`, `m`, and `sigma` are unchanged. The scaled results are carried at 1e18
  rather than narrowed back to 1e9 because the roll-down multiplies terms that
  are themselves tiny on short-dated surfaces — a 1e9 floor costs up to a whole
  raw unit of `a`, and a short-dated `a` is only about ten raw units, so the
  truncation alone breached the ratified price-deviation bound (P-14's defect,
  one layer upstream). Freshness continues to use the latest envelope source
  timestamp. Carrying the roll-down at 1e18 substantially shrinks the terminal
  rounding region in which the roll-down can drive per-strike variance
  non-positive, but does not remove it, and the size of what remains is not a
  single closed form — it depends on the sign of `a` and on cancellation between
  `a` and `b·inner`, not on `a` alone. The existing `ENonPositiveVariance` guard
  remains authoritative for that state, including in pool valuation. Recovery is
  for the publisher to send a changed usable tuple, which resets the parameter
  anchor, followed by retrying the affected action or flush.
- **Reasoning:** transport freshness and parameter age answer different
  questions. A one-second retransmit proves the feed is live but does not make
  an unchanged variance-to-expiry calibration new. Preserving both timestamps
  lets the protocol reject an unavailable stream while consuming the current
  tuple at the remaining horizon, without a separate near-expiry mode or
  minimum-time cutoff. The pre-expiry variance abort is an explicitly accepted
  mandatory-path interruption: it should be rare for provider-calibrated
  surfaces, the low-frequency flush is retriable, and flooring variance to a
  fabricated positive value would hide an unusable effective surface.
- **Risk profile:** `BEST-GUESS` — the timestamp and arithmetic policy are
  deterministic and pinned. The expected rarity and timely publisher recovery
  are not measured; whether linear roll-down is the best calibration model is
  deliberately owned by the still-open O-1 calibration work.
- **Pinning tests:** `pricing_tests.move` —
  `roll_down_is_exact_at_anchor_and_keeps_sub_1e9_resolution`,
  `roll_down_handles_one_ms_boundary_and_u256_intermediates`,
  `rolled_sub_1e9_resolution_reaches_the_variance_pricing_divides_by`, and
  `identical_svi_retransmit_refreshes_source_without_moving_params_anchor`;
  `pricing_guard_tests.move` —
  `pre_expiry_roll_down_keeps_positive_variance`,
  `terminal_roll_down_to_zero_aborts_before_expiry`, and
  `w_prime_keeps_the_rolled_b_precision` (the rolled `b` must reach the skew
  correction at 1e18; narrowing it to 1e9 first misses the reference by ~890
  units against a 21-unit budget).
- **Reopen when:** the provider changes tuple or timestamp semantics, an
  effective-zero surface materially interrupts LP flush liveness or lacks
  timely changed-tuple recovery, Predict adopts a calibrated non-linear horizon
  transform, or live pricing stops consuming SVI total variance as
  variance-to-expiry.

---

## Rounding policy (R1–R3)

Ratified 2026-06-07. At 1e-9 fixed-point with the protocol's token decimals,
sub-unit dust is economically negligible; the real risk is an off-by-one that
aborts a transaction and strands funds. The protocol therefore optimizes for
liveness and a protocol-favored dust bias, not bit-exactness for its own sake.

### R1: Liveness first

Dust must never abort a settlement, redeem, backing, or liability path. Every
`available - requested` subtraction on those paths must be provably
non-underflowing: the reserve or liability backing a payout must always be at
least the amount paid against it. Preferred construction: compute the reserve
and payout from the same expression; or remove and reinsert exact terms so the
accounting atoms match bit-for-bit; or, where that is impossible, round the
reserve up. A `>=` relation that can become `<` by one unit of precision is
the bug class. R1 covers only dust/ulp underflow — deferred-realization
shortfall uses defer-and-carry accounting (RP-8), and bootstrap /
`total_supply == 0` issues need a minimum-liquidity or equivalent structural
solution.

### R2: Dust is biased to the protocol

When a rounding choice exists, the protocol or LP pool keeps the dust; the
user or LP counterparty receives at most one unit less. Concretely:
user-facing outflows round down (redeem, withdraw, payout, rebate);
protocol-held reserves and liabilities are greater than or equal to the
corresponding outflow; use bit-equal reserve/payout pairing where possible,
otherwise round reserves up. Net result: dust accrues to the pool, is never
stranded, and never causes an abort.

### R3: Document direction and owner

Every money-moving expression names its rounding direction and who owns the
dust when the expression is not obvious (e.g.
`// = amount * p / S, round down (user eats <=1 ulp; pool never short).`);
use `ceil(...)` terminology for round-up paths.

**Applications.** Partial close to settled payout: derive reserve and payout
from the same order atoms — remove old order terms and reinsert replacement
terms exactly, so tree reserve equals settled payout with no dust buffer.
Protocol reserve realization: never bare-split a balance for an amount
recognized earlier if the backing cash can be redeployed before the split —
realize `min(pending, available)`, carry the remainder, keep it out of LP
value (RP-8). NAV and floor correction: round floor correction so it cannot
overstate recoverable value; one-unit dust biases toward incumbents/the
protocol, never toward overpaying a withdrawal.

**Audit obligation.** Every money flow is checked against R1 and R2 — mint
contribution, live redeem, settled payout, liquidation, fees and discounts,
rebate reserve, LP supply/withdraw pricing, NAV floor correction. If a flow
can underflow or round toward the user, fix it or document the accepted
tradeoff explicitly.

---

## Pricing and valuation deviation bounds (ratified 2026-07-22)

Ratified accuracy ceilings for every derived price and valuation, distinct from
the R1–R3 accounting-dust policy above (which governs one-ulp money-movement
rounding, not model-evaluation accuracy):

- **Contract price:** a computed range / UP price must not deviate from its true
  real-math value by more than **0.1%** (relative, in the 1c–99c tradeable band).
- **NAV:** a produced `current_nav` / pool mark must not deviate from true NAV by
  more than **1%** (relative).

Enforcement is by independent-reference test, not model judgment, and is in fact
tighter than the ceilings. The price bound is guarded by the generated pricing
reference (`packages/predict/tests/pricing/pricing_reference_data.move`, built by
`generate_pricing_reference.py` from real Block Scholes surfaces against a
true-math reference), whose per-scenario analytic fixed-point tolerance sits well
inside 0.1% — but only where the dataset has scenarios. It must therefore cover
the full deployed variance range, short-dated included, or the bound goes
unenforced exactly where it is tightest: `1/sqrt(w)` conditioning makes low
variance the worst case, which is the gap open item P-16 records. The NAV bound
is guarded by the `current_nav_flow_tests` independent oracle. A pricer or
valuation change that would breach either ceiling on any deployable surface is a
defect to fix, not an accepted tradeoff — this is the line between negligible and
worth-fixing.

---

## Update rules

- New entries come from: closing an `open-items.md` item that embodied a
  response decision; removing/weakening any guard (mandatory duty-inventory
  entry); an audit or review finding an undecided state that is then decided.
- At most one entry resolves a given open item; name the resolved item in the
  entry title (e.g. "resolves C-3").
- Every entry must link at least one pinning test, or carry an explicit
  "not yet catalogued" / "untested — gap" marker. A decision with no pinning
  test is not enforced and must not be described as shipped behavior in
  `docs/risks.md`.
- Audit runs (`predict-audit` skill) must re-verify entries at HEAD — the
  pinning tests still exist, the code still matches the recorded response,
  `risks.md` still cites reality — and must not re-flag a registered decision
  whose reasoning still verifies. Drift between an entry and HEAD is itself a
  finding.
- `BEST-GUESS` risk profiles are standing candidates for harness measurement;
  when a campaign measures one, replace the tag with `MEASURED` and link the
  dated findings record under `evidence/`.
