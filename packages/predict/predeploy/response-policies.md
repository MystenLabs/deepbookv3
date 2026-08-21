# Predict Response-Policy Register

Updated 2026-08-17. This is the tracked register of **settled response-policy
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
  but exceeds idle is different: it is not refused at all — idle pays as much of it as
  it covers and the unfilled balance stays queued at the head, after which the pass
  stops (RP-23). Only if idle cannot buy even one whole share does the head carry
  untouched, consuming no withdraw budget.
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
  `withdrawals_partially_fill_when_idle_runs_dry_and_carry_the_rest`. The fixed_math package
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

## RP-4: Exact Block Scholes fallback bounds missing-Pyth settlement delay (resolves P-29)

- **Trigger state:** an active market is at or past expiry and the canonical Propbook Pyth feed has no positive normalized observation at the exact expiry millisecond.
- **Controller:** external — Pyth and Block Scholes control their signed observations; any relayer may land either verified payload through Propbook.
- **Blast radius:** the whole flush aborts while the market remains expired and unsettled, because no substitute NAV mark exists for a settlement-dependent market.
- **Response:** `pause`-with-deterministic-recovery. `try_settle` checks exact Pyth history first on every attempt. Pyth is exclusive until `clock.timestamp_ms() >= expiry + 30_000`; from that boundary onward, if Pyth remains unavailable, the same transition may settle from the canonical Block Scholes value store's exact spot at `expiry`. Missing, zero, or wider-than-`u64` Block Scholes values return `false` without mutation so a later attempt can retry. Settlement still records one terminal price and exact liability atomically; no latest, nearest, rounded, interpolated, or administrative mark enters valuation.
- **Exact Block Scholes production:** `block_scholes_store::apply_spot_batch` independently inserts a positive `u64`-representable signed spot into permanent exact history whenever `published_at_ms` is a whole-minute boundary, even when that observation does not advance `latest`. The dedicated `insert_at` performs the same first-admissible-writer exact insertion without changing `latest`; non-minute, zero, and over-wide observations are no-ops for exact history. Market expiries are whole-minute aligned, so the fallback asks for a representable exact key.
- **Race policy:** inside the grace window only Pyth can settle. After it, every individual attempt still prefers Pyth, but the first valid settlement transaction is final: a Block Scholes settlement may execute before a Pyth row that arrives later. This is the accepted liveness tradeoff; the event records whether source `0` (Pyth) or `1` (Block Scholes) won.
- **Reasoning + evidence:** `evidence/rp4-settlement-liveness.md` owns the observed Pyth settlement latency. The deterministic second source removes the former state where one inadmissible Pyth boundary permanently blocked every future flush; a market remains blocked only while both exact sources are unavailable or unusable.
- **Risk profile:** `BEST-GUESS` — the 30-second preference window is a compiled policy choice, and a signed Block Scholes spot becomes terminal settlement authority after it. Residual risk is source disagreement at the first-writer boundary or simultaneous absence of both exact rows.
- **Pinning tests:** `settlement_flow_tests.move` — `block_scholes_fallback_arms_at_exact_grace_boundary`, `block_scholes_fallback_missing_after_grace_remains_retryable`, `pyth_wins_after_grace_when_both_exact_spots_exist`, `zero_block_scholes_fallback_spot_remains_retryable`, `oversized_block_scholes_fallback_spot_remains_retryable`, `block_scholes_fallback_rejects_another_underlyings_store`, `block_scholes_fallback_unblocks_pool_valuation_sweep`, and `try_settle_is_idempotent_and_keeps_settlement_price`; `block_scholes_store_tests.move` pins automatic insertion, dedicated insertion, non-minute no-op, first-writer ownership, and latest/history independence.
- **Reopen when:** the grace period changes, expiries cease to be minute-aligned, either source changes exact-history semantics, Block Scholes source quality is no longer accepted for terminal settlement, or a valuation-safe representation for expired-unsettled markets removes the need to block the flush.

## RP-5: Oracle source quality is accepted inside the pricing envelope (resolves P-23, P-25)

- **Trigger state / threat:** a compromised or adversarial Block Scholes
  operator steering live pricing away from the Pyth spot; a provider magnitude
  that does not fit Predict's `u64` pricing domain; or, while
  `use_pyth_spot_for_forward` is set, an independently fresh Pyth spot whose
  source timestamp is older than the Block Scholes spot observation's publish
  time.
- **Controller:** external (oracle operator).
- **Blast radius:** every live price — entry prices and NAV marks.
  The same load sits inside mandatory `plp::value_expiry`, so one over-wide
  observation for any active market also aborts the pool-wide flush and blocks
  queued LP fills until the observation is replaced.
- **Response:** accept provider quality inside the static pricing-safe envelope
  and disclose it (commit `057f9565`); select Pyth by its own freshness rather
  than relative source time; fail closed on provider-width overflow. The
  cross-feed deviation guards are gone. Representable inputs still must satisfy
  positive spot/forward, bounded basis, bounded SVI magnitudes, `|rho| ≤ 1`, the
  sigma band, and positive minimum total variance. A correct-but-adversarial
  source can steer prices anywhere inside that envelope. While
  `use_pyth_spot_for_forward` is set, every independently fresh usable Pyth spot
  reanchors the Block Scholes basis even when the Block Scholes spot is newer;
  only Pyth's own freshness boundary selects the Block Scholes-forward fallback.
  A signed Block Scholes magnitude above `u64::MAX` aborts with
  `EBlockScholesInputTooWide` before the `u128`-to-`u64` cast and semantic
  envelope. Recovery is a newer signed, representable observation followed by
  retrying the affected action or flush.
- **Reasoning:** the deviation guards were a state-triggered abort over an
  externally-controlled variable — a divergence event (or a legitimate fast
  market) bricked pricing with no recovery path, and staleness-vs-authenticity
  cannot be resolved by a consumer-side band. The real mitigation is the
  verifier: BS observations now enter only through signature-verified batches
  (S-4 resolved), so the residual is provider quality, not push access.
  `use_pyth_spot_for_forward` is a source-preference setting, not a
  newest-observation chooser: adding a relative-time gate would make the chosen
  source depend on cross-provider clock ordering and introduce another
  observable switching boundary. Provider-width representability is a semantic
  boundary between the external store's native `u128` values and Predict's
  `u64` pricing domain, so it is named before the primitive cast rather than
  exposing a raw VM arithmetic failure on a mandatory path.
- **Risk profile:** `BEST-GUESS`; representable source quality is bounded only
  by the envelope and the provider's signing integrity. The timestamp skew
  between independently fresh Pyth and Block Scholes observations is bounded by
  their configured absolute freshness windows, not by relative ordering. An
  over-wide signed observation is not bounded by the semantic envelope and can
  stop the pool-wide flush until the provider publishes a representable value.
- **Pinning tests:** `pricing_tests.move` —
  `use_pyth_spot_for_forward_selects_the_live_forward_source`,
  `fresh_pyth_remains_selected_when_block_scholes_is_newer`, and
  `live_forward_switches_source_exactly_at_pyth_staleness_boundary`;
  `pricing_guard_tests.move` —
  `block_scholes_price_above_u64_aborts_with_named_width_error`,
  `block_scholes_forward_at_u64_max_reaches_semantic_validation`,
  `block_scholes_forward_above_u64_aborts_with_named_width_error`,
  `block_scholes_svi_a_above_u64_aborts_with_named_width_error`,
  `block_scholes_svi_b_above_u64_aborts_with_named_width_error`,
  `block_scholes_svi_rho_above_u64_aborts_with_named_width_error`,
  `block_scholes_svi_m_above_u64_aborts_with_named_width_error`, and
  `block_scholes_svi_sigma_above_u64_aborts_with_named_width_error`;
  `pool_valuation_flow_tests.move` —
  `overwide_block_scholes_spot_aborts_pool_valuation_flush` and
  `newer_representable_block_scholes_spot_restores_pool_valuation_flush`.
- **Reopen when:** live signed-feed data shows provider excursions the envelope
  admits, relative source skew produces unacceptable marks, or width overflow
  becomes operationally ambiguous — revisit a cross-feed sanity band as a skip,
  a bounded-skew source rule, or explicit unavailable classification rather than
  the named mandatory-path abort.

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
  wall. ⚠ 2026-08-14: measured with leveraged mints, which no longer exist. The
  mechanism is transaction-level metering, so the ceiling is not expected to
  move, but the figure is unverified post-removal and the simulation parity
  model has not been migrated to re-measure it (open-items C-1).
  Findings: `evidence/c3-mint-batch-2026-07-01.md`. Magnitude is
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

> **RETIRED 2026-08-18 — the trading-loss rebate and DEEP staking were removed.** The trigger state (a settled market with unresolved rebates priced at claim-time `active_stake`) is unreachable: there is no rebate reserve, no `ExpiryTradingSummary`, and no claim. P-9 stays resolved — this entry remains its tombstone — and the settled-market cleanout survives as `redeem_settled_permissionless` alone, whose own gas incentive is the surviving half of the measurements below. The entry is kept verbatim for the decision record; nothing in it describes shipped behavior. Removal record: `docs/design/decisions.md` § "Staking and the trading-loss rebate removal".

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
    hypothetical multi-epoch option the leak is bounded by `rate × fees` and needs a genuine 100k+
    DEEP commitment (retail-excluded). ⚠ 2026-08-18: the stake fee discount was removed, so the
    rebate is now the whole of staking's value rather than half of it — a late staker forgoes
    nothing by waiting, and the epoch activation gate is the only thing that still makes the leak
    unreachable. The size bound (`rate × fees`) and the response are unchanged. The permissionless claim-to-deny grief has zero payoff under the
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
- **Pinning tests:** untested — the entry is retired and governs no live code path. Its four
  Move pins (`rebate_claim_requires_settled_market`, `rebate_claim_with_open_position_aborts`,
  `deauthorized_predict_app_blocks_permissionless_rebate_claim`,
  `owner_auth_rebate_claim_survives_predict_app_deauth`) and their
  `prepare_settled_loss_with_inactive_rebate_stake` fixture were removed with the claim they
  exercised; the app-auth gate they shared with settled redeem stays pinned by
  `deauthorized_predict_app_blocks_permissionless_settled_redeem` and
  `owner_auth_settled_redeem_survives_predict_app_deauth`. The claim-time-stake pricing was never
  pinned by a dedicated Move assertion, and the gas incentive is platform metering pinned by the
  harness evidence above. Audit provenance: finding 8b5d5f. (`check.py` has no RETIRED state;
  `untested` is the closest sanctioned value.)
- **Reopen when:** ⚠ 2026-08-14: the liquidated arm of this entry is moot — leverage removal deleted
  liquidation and the `cleanup-liquidated` harness profile, so the two-marginal
  `nLiquidated`/`nSurvived` fit can never be re-run and only the survivor marginal describes the
  shipped model. Re-measure the survivor cleanout under the derived-state model instead;
  OR a market with life ≥ ~1 Sui epoch (a long-dated / multi-epoch option) ships
  (re-measure the late-stake exposure; reconsider snapshotting benefit-relevant stake at mint); OR
  the settled-redeem storage footprint shrinks / Sui storage pricing drops enough that the cleanout
  net gas turns positive (re-run the sweep; apply the E3 up-front-fee formula); OR
  `trading_loss_rebate_rate` is raised materially (the leak scales linearly with it, and the
  up-front-staker comparison that used to bound it against `max_fee_discount` is gone with the
  fee discount).

---

## RP-12: LP request attempts are admin-tunable and ship at one — fill-or-kill (resolves P-7)

- **Trigger state:** a queued LP supply or withdraw request reaches the head of
  its FIFO queue during a flush, the frozen mark is executable, but the quoted
  output is below the request's minimum output (`min_plp_out` for supply,
  `min_dusdc_out` for withdraw).
- **Controller:** market (the frozen mark) × user (the request-time limit). The
  protocol controls only what happens to the request once it is at the head.
- **Blast radius:** `lp_book::drain` runs inside `finish_flush`, and every LP
  entry and exit passes through it. Blindly filling a limit-missing request gives
  the user unbounded slippage; leaving one queued at the head holds up every
  request behind it, so the head-of-queue policy is a pool-wide liveness control,
  not a per-user UX knob. The two settings move the cost between two different
  failure modes: at one attempt the queue cannot be held, but each miss is
  *processed* (pop, refund, event) and the drain continues, so with unbounded
  budgets a single flush does work proportional to the queued-request count —
  inside the one mandatory flush PTB, which is already measured at 47-92% of the
  computation ceiling on a saturated pool
  (`evidence/c1-price-memo-2026-07-01.md`) and whose OOG stalls valuation and both
  queues (`evidence/c1-nav-stress-2026-06-30.md`). Above one attempt the per-flush
  work is truncated by the `break` instead, at the cost of the blocking.
- **Response:** the attempt count is admin-tunable
  (`protocol_config::set_lp_request_limit_flush_attempts`, bounds 1–3) and
  **ships at 1**. At 1 a miss protocol-cancels and refunds immediately — the head
  is popped, its escrow returned, `RequestCancelled.reason = 2` emitted, and the
  drain continues to the next request in the same flush. A miss spends one unit of
  that queue's processed budget, exactly like a fill, so every head is resolved by
  the flush that reaches it and nothing is held over. Above 1 a missing head
  instead stays queued, emits `RequestLimitMissed`, and stops that queue for the
  flush, refunding on its final attempt. The user cannot modify a queued limit;
  changing price protection means submitting a new request.
- **Reasoning:** the queue is shared, so the cost of retrying a miss is paid by
  everyone behind it, not by the requester. The superseded policy (a compiled
  three attempts, stopping the queue on each miss) reasoned only about an honest
  too-tight limit and concluded expiry "bounds queue blockage". It does not: the
  bound is per request, and requests compose. `min_output` is unbounded at
  admission and escrow is refunded in full, so anyone could pre-stuff a queue
  with minimum-sized requests carrying an unsatisfiable limit and delay every
  later LP by ~2 flushes per request for the price of gas — measured at 2N+1
  flushes of total blockage for N requests, so 201 flushes with no honest LP exit
  at N=100 (external audit, issue #42). Shipping at 1 removes the amplification
  and the blocking together: a griefing request costs the same single budget unit
  as an honest one and is gone. The affordance given up is a resting limit, and
  keeping the attempt count as config rather than deleting the retry keeps that
  recoverable without an upgrade — the number is a tuning parameter for LP-queue
  liveness alongside flush cadence. The ceiling of 3 is deliberate: it caps the
  blocking an operator can create at the pre-fix behaviour, so raising the knob is
  never worse *on that axis* than what was measured.
  **The per-flush work this shifts onto the drain is bounded by the operator's
  budgets, not by the protocol.** Nothing caps pending requests per account or per
  queue, `min_output` is unbounded at admission, and a refunded request returns its
  escrow in the same transaction — so the same capital re-queues indefinitely at
  gas cost. Running a flush with `supply_budget`/`withdraw_budget` = `None` is
  therefore not a supported production configuration under this policy; both must
  be bounded so one flush's drain work is capped regardless of queue depth. This is
  an operational precondition, and the marginal cost of one refunded head against
  the flush's remaining headroom is **not yet measured**.
- **Risk profile:** split, because only one axis was measured.
  `MEASURED` for the blockage the **superseded** policy allowed — reproduced and
  quantified at 2N+1 flushes for N limit-missing requests
  (`evidence/rp12-lp-queue-head-of-line-2026-07-29.md`), which is what raising the
  knob buys back, bounded by the ceiling. `BEST-GUESS` for the **shipped** setting
  on both of its axes: the per-flush drain cost under a deep queue was not
  measured (see Reasoning — budgets must be bounded), and how often an honest limit
  misses depends on flush cadence and NAV volatility, which are also unmeasured.
  The pinning tests below hold the queue open at one attempt and pin that the
  blocking returns above it; neither is a gas or rate measurement. **The knob is a
  liveness control, not a UX preference** — raising it above 1 knowingly re-enables
  head-of-line blocking and should follow a measured miss rate rather than an
  intuition about volatility.
- **Pinning tests:** `lp_book_tests.move` —
  `supply_limit_miss_refunds_at_the_flush_that_reaches_it`,
  `supply_limit_miss_does_not_block_later_requests`,
  `withdraw_limit_miss_refunds_at_the_flush_that_reaches_it`,
  `withdraw_limit_miss_does_not_block_later_requests`, and `limit_miss_spends_one_budget_unit`;
  for the tunable path,
  `supply_limit_miss_carries_then_fills_when_mark_improves_at_three_attempts`,
  `supply_limit_expires_after_three_misses_at_three_attempts`,
  `raising_attempts_reintroduces_head_of_line_blocking`, and
  `withdraw_limit_miss_carries_then_expires_at_three_attempts`. `lp_flow_tests.move`
  drives the production request-then-flush path at both settings —
  `flush_refunds_limit_miss_at_the_default_attempt_count` and
  `flush_carries_limit_miss_when_admin_raises_the_attempt_count` — which is what pins
  the attempt count to configured state rather than to a constant.
  `protocol_config_tests.move` pins the shipped value on a fresh config
  (`new_config_ships_with_no_retry`) and the valuation-lock guard on the setter
  (`set_lp_request_limit_flush_attempts_during_valuation_aborts`); the tunable envelope
  is pinned in `risk_config_tests.move`.
- **Reopen when:** measured miss rates on a live cadence show honest LPs
  re-submitting often enough to want a resting limit back. Raising the attempt
  count is the cheap, bounded lever; the durable answer is a retry that cannot
  block the primary queue (a separate retry queue), after which the ceiling can be
  revisited. Also reopen if LP request limits become mutable in-place, or if a
  per-account pending-request cap is added — that bounds queue spam but is not a
  substitute here, because accounts are permissionless.

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
- **Accepted inaccuracy: none as of 2026-08-14.** This entry previously recorded
  a one-premium-unit conservative edge, because the search probed the fused
  `mul_div_down(p, Q, L)` while admission charged a two-floor expression. With
  leverage removed there is no division by `L`: the probe and the charge are both
  `mul_down(entry_probability, quantity)` on the same operands, so the largest
  admitted quantity is exact and the two can no longer disagree in either
  direction. The sub-lot bound this entry justified via the leverage envelope is
  therefore vacuous rather than merely satisfied.
- **Risk profile:** not applicable since 2026-08-14 — there is no conservative
  edge left to size. Search cost is ~32 probes of two u128 ops, unmeasured against
  the BS pricing in the same call; the search is now invertible in closed form and
  could be replaced by a single division.
- **Pinning tests:** `mint_exact_amount_tests.move` —
  `oversized_budget_saturates_at_the_lot_cap_without_aborting` (u64-max budget
  quotes the lot-cap premium, the former abort domain),
  `budget_mints_largest_fitting_quantity_and_debits_its_exact_cost` and
  `budget_at_next_lot_premium_mints_the_next_lot` (sizing pinned from both
  sides at the exact ATM probability),
  `budget_fill_below_min_quantity_aborts` (fill floor);
  `mint_redeem_guard_tests::mint_exact_amount_below_min_quantity_aborts`
  (dust budget rejects on the floor). The former "untested one-lot-conservative
  edge" gap is closed by deletion, not by a test: with no division by leverage
  the probe and the charge are the same expression, so the edge cannot occur.
- **Reopen when:** the premium relation changes shape (a fee folded into the
  budget, a rounding flip — the probe must move with it or the one-sided bound
  breaks), a measured gas profile shows the search matters, or a future change
  reintroduces a divisor between the probe and the charge.

---

## RP-14: Exact spot products trust Propbook's exact-history key (`EReferenceTickTimestampMismatch` removed; resolves audit 914ecd)

- **Trigger state:** `pyth_feed::normalized_spot_at(requested_timestamp)` returns
  a read whose `source_timestamp_ms` differs from `requested_timestamp`.
- **Controller:** protocol dependency — Propbook owns exact-history insertion,
  lookup, and Pyth normalization semantics.
- **Blast radius:** reference-tick selection for one expiry market. Settlement
  already consumed the same exact lookup without repeating the timestamp check.
- **Response:** proceed — Predict trusts the Propbook exact-read contract and
  pricing's exact-spot read returns only the optional normalized value.
- **Reasoning:** `oracle_lane::insert_at` keys `exact_reads` by the inserted
  read's `source_timestamp_ms`; `read_at(timestamp)` can return only the value
  stored under that exact key; and `pyth_feed::normalized_spot_from_read`
  preserves both timestamps. A mismatched timestamp is therefore
  unrepresentable without changing Propbook's source semantics.
- **Duty inventory (guard removal):** the deleted assert only re-checked that
  exact-key invariant. It did not bound spot value, arithmetic headroom,
  freshness, landing time, grid alignment, or market identity. Canonical-feed
  identity remains checked by `pricing::load_exact_spot`; missing or
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

## RP-15: Block Scholes guarantees butterfly-free surfaces; active-book inversions fail closed (resolves P-11)

- **Trigger state:** despite the provider's guarantee that every published SVI
  surface is monotone and butterfly-arbitrage-free, a fresh Block Scholes
  surface makes a higher-strike UP price exceed a lower-strike UP price. During
  `current_nav`, the active payout tree exposes that inversion at two increasing
  boundary ticks.
- **Controller:** external — the BS surface publisher controls the shape inside
  Predict's pricing-safe envelope; traders cannot choose SVI parameters.
- **Blast radius:** single-order pricing trusts the provider's surface and
  floors an inverted range to zero. NAV adds a defense-in-depth active-book
  check: one exposed inversion aborts that market's NAV read, and because the
  pool flush uses one frozen mark for all LP supply and withdraw fills, it can
  block LP fills pool-wide until the surface is corrected.
- **Response:** accept the provider guarantee for surface admission; do not add
  an on-chain `g(k) >= 0` or tighter synthetic-parameter envelope. If an active
  book nevertheless exposes an inversion, abort valuation and retry after the
  provider publishes a corrected surface. This converts the known aggregate-NAV
  overstatement into fail-closed liveness.
- **Reasoning:** `strike_payout_tree::walk_linear` relies on active boundary
  prices being monotone. Skipping the market or carrying a partial mark would
  poison the single LP mark used for both supply and withdraw, while allowing
  the inverted segment through can overstate pool NAV. Surface quality is part
  of the trusted Block Scholes provider contract rather than an invariant the
  signature or Predict Move code proves; the active-book check stays as a
  narrow accounting backstop rather than duplicating the provider's global
  surface validation on chain.
- **Risk profile:** `BEST-GUESS` — no sampled Block Scholes surface violated
  butterfly freedom, and reachability requires the trusted publisher to violate
  its guarantee with a surface whose inversion intersects the active book. The
  guarantee is not enforced by Predict on chain.
- **Pinning tests:** `current_nav_flow_tests.move` —
  `current_nav_rejects_non_monotone_active_book_surface`; and
  `payout_tree_walk_tests.move` —
  `inversion_on_a_cancelling_last_boundary_still_aborts`. The guard moved from
  the price memo to `strike_payout_tree::ENonMonotonePrice` when leverage was
  removed and the memo was deleted. It is enforced at EVERY payout-tree boundary,
  exactly as it was before the move. An intermediate revision of that change
  enforced it only over the boundaries whose start and end quantities do not
  cancel; that was wrong — the netted aggregate is unaffected by a cancelling
  boundary, but live redeem prices each order individually, so an inversion
  sitting on a cancelling tick let NAV understate liability while the flush
  succeeded. The second pinning test above is the regression for it.
- **Reopen when:** Block Scholes changes or violates the surface guarantee,
  Predict accepts another SVI publisher without the same guarantee, the
  active-book guard is removed, NAV valuation gains a safe per-market
  skip/carry design, or the LP flush no longer uses one shared mark for both
  queues.

---

## RP-16: Protocol reserve is accrue-only; the cut is taken on booked terminal profit — accept + disclose (resolves P-8)

- **Trigger state:** an expiry materializes terminal profit
  (`pool_accounting::materialize_expiry_profit`, reached from a settled-market
  sweep); the protocol's share (`protocol_reserve_profit_share`) is split from
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

> **RETIRED 2026-08-14 — trigger state unreachable.** Leverage was removed from
> Predict, so no order carries a floor, there is no knock-out threshold, and the
> NAV correction this entry governs no longer exists. `live_marked_liability` is
> now the payout-tree linear walk alone. The entry is kept for the decision
> record; its pinning tests were removed with the leveraged NAV correction.

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
- **Pinning tests:** untested — the entry is retired and governs no live code
  path. The two leveraged NAV tests that pinned it were removed with the
  correction they exercised, and the band between the floor and the knock-out
  threshold never got its dedicated pin before retirement. (`check.py` has no
  RETIRED state; `untested` is the closest sanctioned value.)
- **Reopen when:** leverage is reintroduced in any form. This entry is the
  starting point for that design: the knock-out mark, not the floor cap, is the
  decision that was settled here.

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
  takes `max_cost`, the all-in ceiling on `premium + trader-paid fee +
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
  and the NAV mark the pool-wide flush consumes. The
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

## RP-21: Block Scholes series age from their publish timestamps (resolves P-2, P-24; reanchored by DBU-715)

- **Trigger state:** the Block Scholes publisher retransmits an unchanged spot,
  forward, or normalized SVI tuple, or stops publishing a series entirely. A
  retransmission advances the transport envelope while the series retains the
  model timestamp at which the provider last derived the value; for SVI,
  time-to-expiry also continues to decrease.
- **Controller:** external × protocol clock — the publisher controls the
  series values, model timestamps, and envelope cadence; elapsed time is
  objective on-chain state.
- **Blast radius:** every live quote, mint, redeem, and NAV read
  that consumes the series. A stale spot affects every market on the
  underlying; a stale forward or SVI affects its expiry. Because a flush must
  value every active market, any one stale required series blocks the pool-wide
  flush and all queued LP fills. Exact settlement does not use these latest-series freshness checks; its post-grace Block Scholes fallback reads insert-only exact history.
- **Response:** fail closed on publish age — a series is usable while its
  signed batch envelope time is inside the window, and each publish is trusted
  as the provider's assertion that the carried value is current then. Spot and
  forward age out at `block_scholes_price_freshness_ms` (10s by default); SVI
  ages out at `block_scholes_svi_freshness_ms` (60s by default, configurable up
  to a 120s maximum). A retransmission of an unchanged tuple therefore
  refreshes the series and re-anchors the SVI roll-down at its new publish
  time; pricing halts only when envelopes stop arriving, and recovery is
  resumed publishing followed by retrying the affected action or flush. The
  store keys ordering on model time first and never lets a series' stored
  envelope time regress (`propbook::block_scholes_store::apply`), so the anchor
  is monotone. Predict computes
  `a_eff = sign(a) * floor(abs(a) * 1e9 * remaining_ms / anchor_tte_ms)` and
  `b_eff = floor(b * 1e9 * remaining_ms / anchor_tte_ms)` with
  `anchor_tte_ms = expiry - published_at`, both **at 1e18** with
  a `u256` intermediate, and hands them to the variance path in that domain;
  `rho`, `m`, and `sigma` are unchanged. The scaled results are carried at 1e18
  rather than narrowed back to 1e9 because the roll-down multiplies terms that
  are themselves tiny on short-dated surfaces — a 1e9 floor costs up to a whole
  raw unit of `a`, and a short-dated `a` is only about ten raw units, so the
  truncation alone breached the ratified price-deviation bound (P-14's defect,
  one layer upstream). The SVI freshness bound also caps the
  roll-down attenuation at `anchor_tte / remaining <= 1 + freshness / remaining`,
  which puts the floor-to-zero arm (`anchor_tte >= 1e9 * remaining_ms`) out of
  reach of any live quote; the residual non-positive-variance cases are the
  sign/cancellation ones — they depend on the sign of `a` and on cancellation
  between `a` and `b·inner`, not on `a` alone. The existing
  `ENonPositiveVariance` guard remains authoritative for that state, including
  in pool valuation.
- **Reasoning:** the provider contract (stated 2026-08-09) is that the model
  timestamp is re-derived roughly every 20 seconds and that an SVI publish
  whose model time is unchanged carries the same calibration already rolled
  down to its new publish time — duplicate SVI retransmission does not exist.
  The published `a`/`b` therefore always describe the variance remaining over
  the horizon from publish, making the publish time the only correct roll-down
  anchor: the previous model anchor under-scaled the surface whenever publish
  lagged calibration (it re-applied a discount the provider had already
  applied). Keying freshness on the same clock keeps one economic clock per
  read and makes liveness a transport property: a quiet-but-publishing feed
  keeps pricing (the earlier model-keyed policy halted the flush on exactly
  that state), at the trust cost that the contract itself is unverifiable
  on-chain — a provider republishing without actually rolling or recalibrating
  moves quotes as if the surface were current. Calibration age is observable
  off-chain from `BlockScholesObservationRecorded`, which is where a tripwire
  belongs: an on-chain model-age abort would be a state-triggered abort on the
  mandatory flush over an externally-controlled variable, the guard class RP-5
  removed (`docs/risks.md` § stopped transport). The pre-expiry
  variance abort is likewise accepted: the flush is retriable, and flooring
  variance to a fabricated positive value would hide an unusable effective
  surface.
- **Risk profile:** `BEST-GUESS` — the timestamp and arithmetic policy are
  deterministic and pinned. The provider's publish cadence per series, and
  therefore the frequency of a 10s or 60s envelope breach, is not measured;
  this measurement is operational validation of the accepted fail-closed
  policy, not a prerequisite for its correctness. Whether linear roll-down is
  the best calibration model remains owned by the still-open O-1 calibration
  work.
- **Pinning tests:** `pricing_tests.move` —
  `roll_down_is_exact_at_anchor_and_keeps_sub_1e9_resolution`,
  `roll_down_handles_one_ms_boundary_and_u256_intermediates`,
  `rolled_sub_1e9_resolution_reaches_the_variance_pricing_divides_by`, and
  `svi_retransmit_reanchors_the_roll_down_and_the_snapshotted_timestamp`;
  `pricing_guard_tests.move` —
  `live_quote_with_a_freshly_retransmitted_aged_spot_model_succeeds`,
  `live_quote_with_a_freshly_retransmitted_aged_forward_model_succeeds`,
  `live_quote_with_a_freshly_retransmitted_aged_svi_model_succeeds`,
  `live_quote_with_stale_block_scholes_surface_aborts`,
  `live_quote_with_fresh_spot_but_stale_forward_aborts`,
  `live_quote_with_fresh_prices_but_stale_svi_aborts`,
  `pre_expiry_roll_down_keeps_positive_variance`,
  `terminal_roll_down_to_zero_is_preempted_by_envelope_freshness`, and
  `w_prime_keeps_the_rolled_b_precision` (the rolled `b` must reach the skew
  correction at 1e18; narrowing it to 1e9 first misses the reference by ~890
  units against a 21-unit budget); `block_scholes_store_tests.move` —
  `svi_data_in_an_older_envelope_is_skipped_even_with_a_newer_model_time`.
- **Reopen when:** the provider changes series or timestamp semantics or is
  observed republishing surfaces it has stopped re-deriving, observed
  envelope-age breaches materially interrupt LP flush liveness or lack timely
  recovery, Predict adopts partial/async pool valuation, Predict adopts a
  calibrated non-linear horizon transform, or live pricing stops consuming SVI
  total variance as variance-to-expiry.

---

## RP-22: `EPythSpotInvalid` is scoped to the re-anchoring branch (DBU-670)

- **Trigger state:** the normalized Pyth spot exceeds Predict's pricing-safe
  ceiling (`max_pricing_spot!()`, `u64::MAX / 100`) during a live pricing load.
- **Controller:** external — the Pyth Lazer publisher controls the printed spot.
- **Blast radius:** every live-pricing path, including the mandatory pool flush
  (`plp::value_expiry` → `expiry_market::load_live_pricer`), so an oversized
  print can stop all LP supply and withdraw fills, not just one trade.
- **Response:** **abort while the re-anchor is selected, skip while it is not.**
  With `use_pyth_spot_for_forward` set, an oversized spot aborts as before. With
  it clear the spot feeds nothing, so the print is ignored along with every other
  Pyth print and pricing continues on the Block Scholes forward. Which response
  applies is an `AdminCap` setting read at the time of the load, so it is
  protocol policy, not a property of the print.
- **Reasoning:** the ceiling is not a validity judgement about Pyth data — it is
  the arithmetic precondition for `mul_div_down(spot, bs_forward, bs_spot)`
  staying inside u64 (co-designed with `max_pricing_basis_factor!()`). It has
  exactly one consumer, on one branch. Enforcing it on a branch that never reads
  the value would turn a publisher-controlled variable into an abort on the
  mandatory flush for no arithmetic benefit — the abort-over-skip direction the
  blast-radius ladder reserves for single-user, user-recoverable actions. The
  guard therefore lives with the multiplication it bounds. This makes the abort
  *conditionally* reachable rather than removing it: the ladder position moves
  from abort to skip only in the mode that does not consume the value.
- **Risk profile:** `BEST-GUESS` — an oversized normalized spot needs a print
  above `~1.8e17` at 1e9 scaling; reachability is a publisher-integrity question
  and is unmeasured. The response split itself is deterministic and pinned.
- **Pinning tests:** `pricing_guard_tests.move` —
  `fresh_pyth_spot_above_pricing_ceiling_aborts` (re-anchor selected: aborts) and
  `pyth_spot_above_pricing_ceiling_is_inert_while_the_switch_is_off` (re-anchor
  deselected: prices off the Block Scholes forward and still snapshots the Pyth
  source timestamp, so the print is ignored rather than treated as absent).
- **Reopen when:** any consumer of the normalized Pyth spot is added outside the
  re-anchoring branch (the ceiling would then need to move or be duplicated), or
  a cross-source deviation guard lands and changes which side of the ladder an
  out-of-envelope print belongs on (RP-5).

---

## RP-23: Supplies fill up to the pool-value cap and the remainder holds its queue place (DBU-684)

- **Trigger state:** a queued LP supply reaches the head of the supply pass at a
  frozen mark where filling it would raise LP-attributable pool value above
  `ProtocolConfig.max_lp_pool_value`.
- **Controller:** operator (sets the cap) × market (NAV moves the pool under a
  fixed cap without anyone depositing) × user (chooses the deposit size).
- **Blast radius:** capacity gates the supply pass only — withdrawals, already-issued
  PLP, and the genesis lock are never checked against it, so the cap closes the pool
  to new capital and can never trap capital already in it. It does reach exits
  **indirectly**: supplies drain first precisely because their fresh cash funds the
  same flush's withdrawals, so refusing supplies leaves idle lower and a large exit
  can hit the FIFO-until-idle-dry carry a flush earlier than it otherwise would.
- **Response:** fill what fits, keep the rest in place, and stop the pass. A head with
  room fills entirely; a head larger than the remaining headroom is **partially filled
  up to the cap**, its unfilled balance left escrowed at the head with its queue
  position, index, and owner intact; the pass then breaks. A head that finds no room at
  all — or a prefix so small it prices to zero shares — is left untouched and the pass
  breaks without spending flush budget. Headroom is measured against the frozen mark
  **plus the supplies already filled this flush**, so requests cannot collectively
  overshoot. Nothing is refunded for capacity: an LP who would rather hold cash than a
  place in line cancels.
  Breaking forfeits no throughput, because once the cap is reached nothing behind the
  head could fill either; walking the rest of the queue would only spend budget and one
  event per request to refuse each in turn. It also bounds per-flush drain work at O(1)
  under a binding cap, which matters given the flush's event ceiling (RP-12).
- **Withdrawals partially fill on the same principle.** A head whose payout exceeds idle
  is paid what idle covers and keeps the balance queued, rather than carrying whole. The
  shares to burn are floored from available idle and the payout is then quoted from
  those shares by the same helper a full fill uses, so a partial exit prices identically
  to a whole one and the pool never releases cash it has not destroyed shares for. With
  no withdraw fee set, at most one ulp of idle is left behind rather than the requester being
  shorted. With the withdraw fee set the inversion is deliberately conservative: idle is inverted
  at the *gross* price, so the leftover is the slice's fee plus that ulp (bounded by the
  `0..5%` envelope). Grossing idle up by `1/(1 - rate)` would fill marginally more but
  needs a second inversion rounded the pool's way at both steps; the remainder is
  bounded and the next flush picks it up.
- **Carried limits are rescaled, rounded in the requester's favour.** A partially filled
  request keeps asking for the same *price*, so its `min_output` is scaled to the
  remaining amount and rounded **up** — at worst the carried request is held to a
  fractionally stricter limit than it originally signed, never a laxer one.
- **Ordering — the limit is checked first.** A partial fill mints fewer shares (or pays
  less DUSDC) than the whole request, so it is only defensible if the *price* was
  acceptable. Pricing is linear at a frozen mark, so "this prefix clears the LP's rate"
  is exactly the existing `shares >= min_output` test on the full amount — checking the
  limit first costs no new arithmetic and makes `min_output` a **price floor rather than
  an absolute output floor**. A request that both misses its limit and finds a full pool
  reports the limit miss, and an attempt-bearing request keeps its resting behaviour
  rather than being consumed by a transient capacity state.
- **Reasoning:** capacity is a pool-level property, and pool value is exact only
  at the flush — an admission-time check would have to compare against a stale
  snapshot, since no NAV is stored between flushes. Enforcing at the drain keeps
  the cap exact at the cost of holding escrow for one flush interval. Capping
  *value* rather than cumulative deposits avoids new running-total state that
  every fill and withdrawal would have to maintain, and it measures the quantity an
  operator actually wants bounded — pool size. The consequence is that trading
  profit alone can carry a pool above its cap, after which supplies wait
  until NAV falls back; that is intended, and it is why the setter is documented as
  closing the pool rather than forcing an exit. Withdrawals drain after supplies,
  so the headroom an exit frees is priced at the *next* flush, not the current one
  — the mark is frozen, and re-reading it mid-drain would break the single-mark
  guarantee that makes supply and withdraw prices agree.
- **Risk profile:** `BEST-GUESS`. The mechanism is pinned by tests, but no launch
  figure has been chosen and the cap is inert at its default, so nothing about how
  it behaves against real deposit flow has been measured.
- **Pinning tests:** `lp_book_tests.move` — `supply_within_pool_cap_fills`,
  `supply_larger_than_headroom_partially_fills_to_the_cap`,
  `supply_carries_when_the_pool_has_no_headroom`,
  `supplies_cannot_collectively_exceed_the_pool_cap_in_one_flush`,
  `supply_carries_when_pool_is_already_over_cap`,
  `pool_cap_does_not_gate_withdrawals`,
  `full_pool_holds_the_supply_queue_instead_of_clearing_it`,
  `partially_filled_head_keeps_its_place_across_flushes`,
  `withdrawals_partially_fill_when_idle_runs_dry_and_carry_the_rest`, and
  `capped_flush_fills_withdraws_and_leaves_headroom_for_the_next_flush` end to end.
  The branch order is pinned by `over_cap_and_under_limit_takes_the_limit_branch`,
  which reads it off queue state — a limit miss pops and refunds the head while a
  capacity stop leaves it queued and spends no budget — plus
  `limit_miss_is_not_partially_filled_into_available_headroom` and, for the prefix
  price guard, `supply_prefix_below_the_requests_price_is_carried_not_filled` and
  `withdraw_prefix_below_the_requests_price_is_carried_not_paid`. The fee-set
  leftover bound above is pinned by
  `withdraw_partial_fill_charges_the_slice_fee_and_leaves_it_in_idle`, and the
  prefix price guard under a fee by
  `capped_partial_supply_at_its_own_price_fills_with_the_fee`.
  `lp_flow_tests.move` pins the cap to configured state rather than a constant
  (`flush_holds_a_supply_that_would_breach_the_configured_pool_cap`, with
  `flush_fills_the_same_supply_when_the_pool_is_uncapped` as the control).
  `protocol_config_tests.move` pins the shipped default and the valuation-lock
  guard; `risk_config_tests.move` pins the bounds and the floor.
- **Reopen when:** a launch figure is set (the profile should become `MEASURED`
  against observed deposit flow); or a request-time admission check is wanted for
  UX, which needs a stored last-flush NAV snapshot and makes the cap two-sided; or
  withdrawals are ever drained before supplies, which would change whose headroom is
  being measured; or per-flush drain work is bounded structurally rather than by the
  operator's budgets, which would also bound how much of a capped pool's queue one
  flush churns through (see RP-12's per-flush cost note).

---

## RP-24: Same-transaction oracle writes cannot feed a live pricer

- **Trigger state:** a PTB writes a Propbook observation (Pyth Lazer update or
  Block Scholes batch) and then builds a live `Pricer` that would consume that
  observation for the returned forward or SVI.
- **Controller:** external / adversarial — Propbook writes are permissionless
  once the caller holds a verifier-produced payload (`LazerUpdate`,
  `ValueBatch`, `SviBatch`). A trader running their own Pyth Lazer subscription
  can obtain such a payload.
- **Blast radius:** every live-pricing path that loads a pricer
  (`mint_*`, `redeem_live`, `plp::value_expiry`). One push
  re-anchors every live market on that underlying.
- **Response:** **abort** at `pricing::resolve_live_pricer` with
  `EOracleWrittenInThisTransaction` when any observation that feeds the returned
  price carries this transaction's digest. Pyth is checked only on the
  re-anchor branch (`use_pyth_spot_for_forward` and a fresh read); when the flag
  is off or the read is stale, Pyth is provenance-only and must not trip the
  guard.
- **Reasoning:** Without the guard, Variant A (mint → update → mint of the
  complement) extracts a risk-free box: the two legs together pay $1 and cost
  less than $1 against a stale-then-fresh forward. Variant C (update → redeem a
  seasoned position) marks an older position at the inflated print in the same
  PTB. `EMintRedeemSameTimestamp` only partially covers mint→redeem of a
  freshly opened order and does not cover cross-leg minting or seasoned
  redeems. Rejected alternatives: mint-path-only guard (reroutable through
  redeem/second market); clock-timestamp comparison (Sui's `Clock`
  advances per checkpoint, so honest trades sharing a checkpoint with the
  updater would false-positive); `ctx.sender()` (cannot distinguish a router);
  EWMA/smoothed oracle (`oracle_lane::update` no-ops on non-advancing
  timestamps, so a buffer of signed payloads can converge an EWMA in one PTB,
  and smoothing desynchronises mint from exact settlement). The transaction
  digest is constant across a PTB and differs between transactions — zero false
  positives for honest trades that never write a feed.
- **Risk profile:** `BEST-GUESS` for the atomic path — unit-pinned under
  `oracle_same_tx_guard_tests.move`; a dated testnet measurement record is not
  yet filed under `evidence/`. Residual cross-transaction risk is accepted: a
  trader can still write in tx N and trade in N+1, or sandwich the updater's
  ~1.4–1.8s push, but then carries inventory and cannot guarantee ordering — a
  directional bet, not risk-free extraction. Pricing that residual is separate
  ΔP-surcharge work. Also noted without acting: `pyth_spot_freshness_ms`
  defaults to 10_000, a wide staleness budget relative to 1m markets.
- **Pinning tests:**
  `write_feed_then_load_pricer_same_tx_aborts`,
  `write_feed_then_mint_next_tx_succeeds`,
  `variant_a_mint_update_mint_aborts_on_second_pricer`,
  `variant_c_write_then_redeem_seasoned_position_aborts`,
  `ordinary_mint_without_oracle_write_succeeds`,
  `multi_leg_mints_share_one_pricer_without_oracle_write`,
  `write_bs_forward_only_then_load_pricer_same_tx_aborts`,
  `write_bs_svi_only_then_load_pricer_same_tx_aborts`,
  `write_fresh_pyth_only_then_load_pricer_same_tx_aborts`,
  `pyth_write_same_tx_succeeds_when_reanchor_disabled`,
  `pyth_write_same_tx_succeeds_when_pyth_read_is_stale`,
  `price_then_write_same_tx_is_permitted`.
  Propbook also pins digest survival across project_read in its own suite
  (outside this package's test tree).
- **Reopen when:** a ΔP surcharge or similar cross-tx oracle-move fee lands; the
  redundant `EMintRedeemSameTimestamp` guard is removed as a follow-up; or
  `load_exact_spot` (settlement / reference-tick exact history) is brought
  under a same-tx policy after an explicit threat-model review (different path:
  `insert_at` already bounds carry via `ESettlementCarryExceedsWindow`).
- **Layout note:** adding `writer_digest` to `OracleRead` / `BsRead` changes
  Propbook struct layouts — requires a fresh publish of propbook and predict,
  not a compatible upgrade.

---

## RP-25: Block Scholes stores are permanent per underlying (resolves P-26)

- **Trigger state / threat:** an operator attempts to create a second Block
  Scholes store pair for an underlying, the pair was created with the wrong
  provider base asset, or the current pair needs recovery from bad observations
  or a future store-version change.
- **Controller:** protocol administration creates the pair once; the signed
  provider advances observations in that pair; package upgrades own structural
  recovery.
- **Blast radius:** one underlying and every Predict market that reads its
  canonical pair. A structurally unusable pair can block live pricing and the
  pool-wide flush until an upgrade supplies a recovery path.
- **Response:** reject replacement with
  `EBlockScholesStoresAlreadyExist`. Correct provider data by writing a newer
  signed observation into the existing pair; migrate its stored version in
  place with `migrate_value_store` / `migrate_svi_store`; if the immutable
  base-asset binding is wrong or a future shape cannot be migrated in place,
  add the concrete structural recovery in a package upgrade. There is
  deliberately no pre-deployed admin rebind.
- **Reasoning:** a Pyth wrapper represents one replaceable provider source, but
  a Block Scholes pair permanently binds one Propbook underlying to an immutable
  provider base asset and the descriptor-derived spot, forward, and SVI series
  for that asset. A bad observation can advance in place; a wrong base-asset
  spelling cannot, so it must be prevented by confirming the provider's
  acknowledged subscription before creation. A generic rebind would instead let
  an admin switch all markets to fresh empty state without a concrete migration
  requirement; an additive upgrade can introduce a narrower recovery if one
  becomes necessary.
- **Risk profile:** `BEST-GUESS` — correction by newer observations and the
  current version gate are deterministic; no structural failure requiring
  replacement has been observed.
- **Pinning tests:** `registry_tests.move` —
  `creating_a_second_store_pair_for_an_underlying_aborts`;
  `block_scholes_store_tests.move` —
  `a_new_store_reports_its_base_asset_and_running_version`,
  `migrating_older_stores_advances_them_to_the_running_version`,
  `migrating_a_value_store_already_at_the_running_version_aborts`, and
  `migrating_an_svi_store_already_at_the_running_version_aborts`.
- **Reopen when:** a concrete failure cannot be corrected by a newer signed
  observation or in-place migration, and an additive package upgrade cannot
  provide a sufficiently narrow recovery path.

---

## RP-26: Log-moneyness is a difference of logarithms, so the digital tails follow the surface

- **Trigger state / threat:** a strike far enough from the forward that forming the
  fixed-point ratio `strike * 1e9 / forward` destroys it — the quotient floors to
  zero below a ratio of 1e-9 and leaves `u64` above 1.8e10, and just inside those
  limits it survives as a handful of raw units carrying tens of percent of
  truncation error. `compute_nd2` previously short-circuited there, returning the
  exact digital limits `1e9` and `0` **without reading the surface**.
- **Controller:** nobody, which is what made it dangerous. The branch fired on
  `strike/forward` alone, so neither the Block Scholes publisher nor a trader had to
  do anything unusual; the surface determined whether the returned limit was true.
- **Blast radius:** every consumer of `range_price` on the affected market, all
  reading the same wrong number — the mint's entry probability and the NAV mark
  the pool-wide flush consumes. Both directions existed: two saturating boundaries
  collapse a range to zero, one saturating boundary against a finite one inflates it
  toward 1.0. Nothing downstream caught either — a constant `1e9` across ticks is
  monotone non-increasing, so `ENonMonotonePriceMemo` did not fire.
- **Response:** compute `k = ln(strike) - ln(forward)` instead of `ln` of the ratio,
  and delete both short-circuits. `ln` is defined across the whole positive `u64`
  domain, so the difference is well-conditioned over every representable pair:
  `|k| <= 44.4` against the `[-20.72, +23.64]` the ratio form could reach, at 1e-7
  relative error per term rather than an error that grows without bound as the tail
  deepens. The
  tails still reach their limits, now through `d2`'s existing normal-CDF clamp
  (RP-20) — computed rather than asserted.
- **Reasoning:** the saturations were a repair for a self-inflicted precision loss,
  and they repaired it with a claim that is only conditionally true. The exactness
  of the digital limits at `|k| = 20.7` is not a property of the market — it is a
  property of total variance, and the admissible envelope permits variance where the
  limits are wrong by 100%. Constraining the surface to keep the shortcut honest was
  considered and rejected: the binding quantity is the wing slope `b(1 + |rho|)` at
  the saturation boundary, Lee's moment formula makes `b(1 + |rho|) <= 2` a
  *necessary no-arbitrage condition*, and a surface sitting at that bound — perfectly
  arbitrage-free — gives `w = 41.4`, `d2 = 0` and a true deep-ITM digital of exactly
  0.5 against a returned 1.0. No envelope that admits arbitrage-free surfaces can
  make the shortcut sound, so the shortcut is the thing that had to go. Removing the
  precision loss removes the need for both.
- **Risk profile:** `BEST-GUESS`. The identity is exact in reals, and the fixed-point
  error *bound* is uniformly better: two `ln` evaluations instead of one `ln` of a
  truncated quotient, which removes a term that grows without bound as the tail
  deepens. Measured over 200,000 random `(strike, forward)` pairs, worst
  `|k - k_exact|` is 2.2e-8 for the difference form against 5.4e-7 for the ratio form
  over representable ratios and unbounded outside them. **Pointwise it is not
  strictly better** — the difference form is the less accurate of the two on ~13% of
  pairs, by at most 1.2e-8 — so the claim to rely on is the bound, not per-point
  dominance. Existing exact-value coverage is unchanged: the four real-scenario
  reference tests and the flat-surface at-the-forward digital all still hold to their
  derived budgets, with worst-case budget usage unchanged at 61%. One differential
  test moved off a bit-equality that held only for the old path's price low bits (see
  below). No dated findings record is
  filed under `evidence/`, so this entry does not yet claim a measured risk
  profile; filing the 200,000-pair run there promotes it.
- **Envelope unchanged:** `max_svi_input` stays at 100. It was tightened in an
  earlier draft of this policy and reverted after checking calibrated raw-SVI
  parameters for real BTC surfaces — `b` reaches 0.21 across maturities and 0.10
  within the cadence ladder Predict trades, and `sigma` reaches 1.00, so caps sized
  to make the saturations exact would have rejected real surfaces and converted a
  latent correctness bug into a fail-closed pricing halt.
- **Pinning tests:** `pricing_guard_tests.move` —
  `deep_itm_up_price_follows_the_surface_not_the_strike_ratio` (the same deep-ITM
  strike as the ordinary-surface test, on a surface with `w = 481` at that strike,
  asserting 0 where the ratio path returned `1e9`; mutation-checked by restoring the
  ratio path), alongside the unchanged `deep_itm_up_price_saturates_to_one` and
  `deep_otm_up_price_saturates_to_zero`, which now reach their limits through the
  computed path. `payout_tree_walk_tests.move` —
  `gc_mutated_tree_walk_matches_rebuilt_survivor_tree` asserts the walk is within
  one raw unit of, and never below, the per-order reference (`Σ floor(p·qᵢ) <=
  floor(p·Σqᵢ)`, protocol-favoured per R2) rather than bit-equal.
- **Reopen when:** `math::ln` changes its domain or error budget, the digital's 1e9
  output scale changes, or a strike/forward pair is admitted whose `|k|` exceeds
  44.4 (impossible while both are `u64` at 1e9).

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
user-facing outflows round down (redeem, withdraw, payout);
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
value (RP-8). NAV: round so it cannot overstate recoverable value; one-unit
dust biases toward incumbents/the protocol, never toward overpaying a
withdrawal.

**Audit obligation.** Every money flow is checked against R1 and R2 — mint
contribution, live redeem, settled payout, fees,
LP supply/withdraw pricing, NAV. If a flow
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

## RP-27: Guards deleted with leverage — duty inventory (2026-08-14)

- **Trigger state:** not a runtime state. `move.md` requires that deleting or
  weakening a guard is preceded by an inventory of what it *incidentally* bounded,
  recorded here rather than only in a commit message. Leverage removal deleted
  several asserts; this entry is that inventory.
- **Controller:** protocol (all of these guard protocol-written state).
- **`order::EInvalidFloorShares` (`floor_shares <= quantity`).** Stated purpose: a
  floor cannot exceed the max payout. Incidental duty: underflow headroom for four
  bare subtractions — `payout_terms_from_order`'s `quantity - floor_shares`,
  `quote_settled_close`'s `quantity - floor_shares`, `process_live_close`'s
  `floor_shares - remove_floor_shares`, and the per-order non-negativity that
  `total - max` / `range_max - payout` rely on. The first three expressions are
  deleted by the same change. The fourth survives, now over raw `quantity`, where
  non-negativity is unconditional — strictly stronger than the guard it replaces.
  It was never an encoding dependency: the floor occupied a full 64-bit field, so
  any `u64` value fit regardless of the bound.
- **`strike_exposure_config::EInvalidLeverage` (`leverage >= 1x`).** Stated
  purpose: reject sub-1x leverage. Incidental duty: it was the only thing keeping
  `div_down(entry_value, leverage)` and `mul_div_down(p, Q, leverage)` from
  dividing by zero, and the only thing keeping `entry_value - net_premium`
  non-negative. All three expressions are deleted.
- **`pricing::ETickNotInPriceMemo`.** Stated purpose: a finite boundary tick must
  be present in the per-flush cache. Incidental duty: it was a cross-index
  consistency proof — every active leveraged order's boundary had to be a
  payout-tree node — so it would also have caught a tree GC that dropped a live
  boundary. The second index is gone, so the cross-index claim is vacuous; the
  residual GC-detection duty is carried, one transaction later, by
  `remove_range`'s underflow abort.
- **`strike_payout_tree`'s cross-field `net_payout <= quantity` assert in
  `apply_terms_delta`.** Stated purpose: a desync that under-removes net payout
  cannot leave a boundary holding phantom payout above zero quantity. With one
  stored atom there is no cross-field invariant left to violate; the surviving
  per-boundary `apply_net_delta` underflow still detects over-removal, which is
  the same direction the deleted assert's sibling covered.
- **`liquidation_book::EMaxActiveLeveragedOrders` (5,000 per market).** Stated
  purpose: bound the per-market active *leveraged* set — `insert_order` returned
  early for a 1x order, so unleveraged open-order count was already unbounded at
  `dfc74cb4`. Incidental duty: it bounded the only per-order iteration in the
  flush (`correction_value`). Nothing iterates orders now — the flush's per-market
  cost is `walk_linear` over tree nodes, still capped by
  `constants::max_payout_tree_nodes`, which bounds distinct boundary *ticks* and
  never bounded order count. So the removal does not reopen the
  liveness-time-bomb class `move.md` describes; it removes a cap on a set that no
  longer exists.
- **Response:** all of the above are removals of guards whose duties are either
  deleted alongside them or re-homed strictly stronger. No replacement guard is
  required. The one guard that was *narrowed* rather than deleted — the
  non-monotone surface check — is recorded separately in RP-15 and is now enforced
  at every payout-tree boundary again, pinned by
  `payout_tree_walk_tests::inversion_on_a_cancelling_last_boundary_still_aborts`.
- **Risk profile:** `BEST-GUESS` — no runtime state is involved; the judgement is
  static reachability of the deleted expressions, verified by grep against HEAD.
- **Pinning tests:** `order_tests.move` — `open_lower_order_packs_to_independent_layout`,
  `finite_range_order_packs_to_independent_layout`, `every_getter_decodes_its_own_field`,
  `from_order_id_rejects_bits_above_envelope`, `max_quantity_lots_round_trips_without_truncation`.
- **Reopen when:** leverage is reintroduced in any form, or a per-order term is
  added back to the payout tree.

---


## RP-28: Guards deleted with staking and the trading-loss rebate — duty inventory (2026-08-18)

- **Trigger state:** not a runtime state. `move.md` requires that deleting or weakening a guard is preceded by an inventory of what it *incidentally* bounded, recorded here rather than only in a commit message. Removing DEEP staking and the trading-loss rebate deleted one solvency term and ten error constants; this entry is that inventory.
- **Controller:** protocol (all of these guard protocol-written state).
- **The `+ rebate_reserve` term in `expiry_cash::required_cash` (and its mirror in `free_cash`).** Stated purpose: an expiry must hold cash for rebates it may owe on top of its payout liability. Incidental duty: it made expiry cash *strictly* conservative — the reserve was cash the market could not sweep, so it also absorbed any rounding gap between the payout liability and the actual settled payout, and it kept the settled sweep from returning cash that a later claim would need. Both duties die with the claim: no flow pays out of that reserve any more, the settled payout is derived from the same packed atoms as the liability (R1 bit-equal pairing, unchanged), and the surviving `assert_backing` still requires `balance >= payout_liability + inventory_impact_reserve` after every cash movement. The removal *loosens* what the market may sweep by exactly the amount that used to fund rebates, which is the intended behavior change; it does not loosen what backs a winner's payout.
- **`expiry_cash::ERebateBasisExceedsFee` (`rebate_fee_basis <= fee.value()`).** Stated purpose: the caller cannot designate more rebate basis than the cash it is delivering. Incidental duty: it was the trust boundary on the one two-argument fee-collection call — the only place a caller could inflate a liability without delivering the cash to back it. The two-argument form is gone; fee cash now joins through `receive`, which takes only the balance, so the inflatable argument no longer exists.
- **`expiry_cash::EUnresolvedTradingFeesUnderflow` (`unresolved_trading_fees_paid >= trading_fees_paid`).** Stated purpose: a claim cannot resolve more fee basis than the expiry has unresolved. Incidental duty: it was the cross-object consistency proof between the account's per-expiry summary and the market's running basis — a double-resolve or a summary/market drift aborted here. Both sides of that pair are deleted.
- **`predict_account::EExpirySummaryHasOpenPositions`.** Stated purpose: an account's rebate resolves only once every position in that expiry is closed. Incidental duty: it was the ordering gate that made the claim's fee basis final. The claim is gone; nothing else reads a per-expiry aggregate.
- **`predict_account::EInsufficientPosition` (`open_position_count > 0` on remove).** Stated purpose: the per-expiry counter cannot underflow. Incidental duty: it was a second, independent existence check on a position being removed. That duty is unconditionally carried by `EPositionNotFound`, which the same function asserts against the `positions` table one line earlier — the counter was the derived copy, the table is the source of truth.
- **`stake_config::EInvalidBenefitPowers` (`upper > 2 * lower`).** Stated purpose: reject a benefit curve whose segments are not ordered. Incidental duty, named in its own source comment: it was the only thing keeping the upper-segment denominator (`upper_benefit_power - lower_benefit_power`) positive in `stake_curve`. Both the divisor and the curve are deleted, so the duty has no surviving expression — this is the one deleted guard that carried a documented incidental duty, and it dies with its arithmetic.
- **`plp::EMarketNotSettled`.** Stated purpose: a rebate claim requires a settled market. Incidental duty: none — it was the pool-side half of a check `expiry_market::claim_trading_loss_rebate` also made. The name survives in `expiry_market`, where the settled-redeem path still enforces the same lifecycle precondition.
- **The four `config_constants` validators** (`EInvalidTradingLossRebateRate`, `EInvalidMaxBenefitRatio`, `EInvalidLowerBenefitPower`, `EInvalidUpperBenefitPower`). Stated purpose: bound the admin setters for the rebate rate and the benefit curve. Incidental duty: none beyond their stated ranges — each is a pure `min <= v <= max` check over a config field that no longer exists, and no runtime expression read those bounds. Their admin entrypoints are deleted in the same change, so no setter is left unbounded.
- **Response:** every guard above is removed with the state it guarded, or its duty is carried by a surviving check that is at least as strong. No replacement guard is required. The one behavior change worth stating plainly: a settled market now returns all cash above payout liability and the impact escrow in the settled sweep, instead of holding a per-account reserve until a keeper resolved it, so an expiry no longer strands cash waiting on a cleanout.
- **Risk profile:** `BEST-GUESS` — no runtime state is involved; the judgement is static reachability of the deleted expressions, verified by grep against HEAD plus the cash-sheet flow tests below.
- **Pinning tests:** `cash_backing_flow_tests.move` — `cash_sheet_exact_after_every_flow` (exact expiry cash and payout liability after every LIVE cash-mutating step — mint, mint, partial close — with `assert_market_backed` on each; the settled sweep is covered by the two tests below, not by this one); `settlement_flow_tests.move` — `explicit_settlement_then_standalone_rebalance_sweeps_market`; `protocol_profit_deferral_tests.move` — `settled_sweep_defers_protocol_cut_then_drains_on_later_sweep`.
- **Reopen when:** a loss rebate, a fee-basis reserve, or any other per-account liability funded out of expiry cash is reintroduced — the backing term and its resolve-side underflow guard come back together, and the settled sweep must hold the reserve back again.

---
