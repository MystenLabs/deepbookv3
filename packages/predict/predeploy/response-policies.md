# Predict Response-Policy Register

Updated 2026-07-08. This is the tracked register of **settled response-policy
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
  `scope_flow__intent_policy__pool_valuation_tests::finish_flush_with_zero_pool_nav_and_empty_queues_succeeds`,
  `scope_flow__intent_policy__pool_valuation_tests::finish_flush_with_low_plp_price_and_empty_queues_succeeds`,
  `scope_flow__intent_policy__pool_valuation_tests::finish_flush_with_high_plp_price_and_empty_queues_succeeds`.
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
  `scope_mechanics__intent_policy__lp_book_response_tests::priced_supply_with_zero_pool_value_refunds`,
  `scope_mechanics__intent_policy__lp_book_response_tests::priced_supply_that_rounds_to_zero_shares_refunds`,
  `scope_mechanics__intent_policy__lp_book_response_tests::priced_withdraw_that_rounds_to_zero_payout_refunds`,
  `scope_mechanics__intent_policy__lp_book_response_tests::supply_at_min_executable_plp_price_fills`,
  `scope_mechanics__intent_policy__lp_book_response_tests::supply_below_min_executable_plp_price_refunds`,
  `scope_mechanics__intent_policy__lp_book_response_tests::supply_at_max_executable_plp_price_fills`,
  `scope_mechanics__intent_policy__lp_book_response_tests::supply_above_max_executable_plp_price_refunds`,
  `scope_mechanics__intent_policy__lp_book_response_tests::oversized_supply_that_exceeds_u64_shares_refunds`,
  `scope_mechanics__intent_policy__lp_book_response_tests::non_executable_supply_refunds_spend_supply_budget`,
  `scope_mechanics__intent_policy__lp_book_response_tests::non_executable_withdraw_refunds_spend_withdraw_budget`, and
  `scope_mechanics__intent_policy__lp_book_response_tests::withdrawals_stop_when_idle_is_dry_and_carry`. The fixed_math package
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
- **Pinning tests:** `pool_valuation_flow_tests.move` ·
  `scope_flow__intent_policy__pool_valuation_tests::finish_flush_with_zero_pool_nav_and_empty_queues_succeeds` proves the flush
  survives a NAV==0 mark (gross reaches zero through a backing-floor-exact
  position marked at full probability); and `protocol_profit_flow_tests.move` ·
  `scope_flow__intent_policy__protocol_profit_tests::carried_protocol_profit_is_held_out_of_the_flush_mark` pins the clamp's own
  trigger directly — a carried protocol cut exceeding a positive gross clamps
  the mark to zero instead of underflowing.
- **Reopen when:** the exclusion basis becomes non-sticky, or RP-2's
  implementation changes what a zero mark means for the queues.

## RP-4: Past-expiry-but-unsettled market blocks the flush (no substitute mark)

- **Trigger state:** an active market is past expiry but Propbook has no
  normalized spot at the exact expiry millisecond yet.
- **Controller:** external — resolution relayer liveness (Pyth Lazer
  resolution endpoints supply the exact-timestamp print).
- **Blast radius:** the whole flush aborts while the market is in the window.
- **Response:** `pause`-with-recovery — abort and retry; the recovery path is
  the permissionless exact-ms insert followed by `try_settle`. Standalone cash
  rebalance is a no-op in the window, and the keeper does not flush until the
  transition succeeds. Deliberately **no substitute
  mark**: a settlement-dependent market has no well-defined true value, and
  the single mark prices both queue directions — contribute-0 dilutes
  incumbents on supply, free-cash overpays withdrawals.
- **Reasoning + evidence:** `evidence/rp4-settlement-liveness.md` (accepted
  operational assumption, testnet evidence); grid-snap at creation makes the
  key representable, resolution endpoints make it producible.
- **Risk profile:** `MEASURED` (testnet evidence in
  `evidence/rp4-settlement-liveness.md`);
  residual = prolonged relayer outage blocks LP fills pool-wide, disclosed in
  `risks.md`.
- **Pinning tests:** `settlement_flow_tests.move` —
  `scope_flow__intent_policy__settlement_tests::try_settle_without_exact_expiry_spot_returns_false_without_mutation`,
  `scope_flow__intent_policy__settlement_tests::expired_unsettled_standalone_rebalance_moves_no_cash`, and
  `scope_flow__intent_policy__settlement_tests::explicit_settlement_unblocks_pool_valuation_sweep`.
- **Reopen when:** settlement-v2 introduces a valuation-safe representation
  for unsettled past-expiry markets.

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
- **Pinning tests:** `live_pricer_behavior_tests.move` —
  `scope_structure__intent_behavior__live_pricer_tests::live_pricer_accepts_pricing_safe_cross_feed_deviation` exercises the accepted
  absence of a cross-feed deviation guard beyond the former Block Scholes basis limit.
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
- **Pinning tests:** `trading_pause_guard_tests.move` independently pins global and per-market mint rejection; `redeem_accounting_tests.move` · `scope_flow__intent_accounting__redeem_tests::global_trading_pause_keeps_exact_full_live_redeem_available` pins exact live-exit accounting with both pauses engaged.
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
- **Pinning tests:** `protocol_profit_flow_tests.move` ·
  `scope_flow__intent_policy__protocol_profit_tests::carried_protocol_profit_is_held_out_of_the_flush_mark` (the cut is capped at
  available idle, the remainder carries, and the carried amount is held out of
  the pool NAV mark) and
  `scope_flow__intent_policy__protocol_profit_tests::carried_protocol_profit_realizes_on_the_next_cash_abundant_sweep` (a later
  sweep that refills idle realizes the carry plus its own cut exactly);
  `settlement_flow_tests.move` ·
  `scope_flow__intent_policy__settlement_tests::owner_auth_rebate_claim_survives_predict_app_deauth` pins the rebate-residual
  re-materialization path; the local carry legs (loss carry-forward, partial
  refill, idle-shortfall realization) are pinned in
  `pool_accounting_accounting_tests.move`.
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
- **Pinning tests:** `scope_mechanics__intent_behavior__ewma_tests::extreme_first_observation_suppresses_penalty_for_later_trades`
  (ewma_tests, charge-then-fold narrative),
  `scope_flow__intent_accounting__quote_mint_tests::ewma_penalty_included_in_quote_and_mint_debits_exactly`
  (quote_mint_tests, nonzero pre-fold penalty quoted and charged identically in
  one transaction),
  `scope_flow__intent_accounting__quote_mint_tests::quote_matches_independent_costs_and_mint_debits_exactly_all_in_cost`
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
- **Pinning tests:** `settlement_flow_tests.move` — `scope_flow__intent_policy__settlement_tests::rebate_claim_requires_settled_market`
  and `scope_flow__intent_policy__settlement_tests::rebate_claim_with_open_position_aborts` pin the claim preconditions (settled market,
  no open positions); `scope_flow__intent_policy__settlement_tests::deauthorized_predict_app_blocks_permissionless_rebate_claim` and
  `scope_flow__intent_policy__settlement_tests::authorized_predict_app_permissionless_rebate_claim_resolves_account` pin the app-auth gate in
  both directions (an authorized permissionless claim resolves the account; deauthorization
  revokes it), and `scope_flow__intent_policy__settlement_tests::owner_auth_rebate_claim_survives_predict_app_deauth` pins the owner-auth
  fallback with the exact residual return. `scope_flow__intent_policy__settlement_tests::prepare_settled_loss_with_inactive_rebate_stake` is an
  independent staging pin that asserts the inactive-rebate-stake state the app-auth pins rely on
  (stake added in the market's own epoch stays inactive through settlement). The claim-time-stake
  *pricing* (active stake read at claim, `expiry_market::claim_trading_loss_rebate`) is not pinned
  by a dedicated Move assertion — it
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
  `scope_mechanics__intent_policy__lp_book_response_tests::supply_limit_miss_carries_then_fills_when_mark_improves`,
  `scope_mechanics__intent_policy__lp_book_response_tests::supply_limit_expires_after_three_misses`,
  `scope_mechanics__intent_policy__lp_book_response_tests::withdraw_limit_miss_carries_then_fills_when_mark_improves`, and
  `scope_mechanics__intent_policy__lp_book_response_tests::withdraw_limit_expires_after_three_misses`.
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
- **Pinning tests:** `mint_budget_accounting_tests.move` —
  `scope_flow__intent_accounting__mint_budget_tests::oversized_budget_saturates_at_the_lot_cap_without_aborting` (u64-max budget
  quotes the lot-cap premium, the former abort domain),
  `scope_flow__intent_accounting__mint_budget_tests::budget_mints_largest_fitting_quantity_and_debits_its_exact_cost` and
  `scope_flow__intent_accounting__mint_budget_tests::budget_at_next_lot_premium_mints_the_next_lot` (sizing pinned from both
  sides at the exact ATM probability); `mint_budget_guard_tests.move` —
  `scope_flow__intent_guard__mint_budget_tests::budget_fill_below_min_quantity_aborts` (fill floor) and
  `scope_flow__intent_guard__mint_budget_tests::mint_exact_amount_below_min_quantity_aborts`
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
- **Pinning tests:** `reference_tick_behavior_tests.move` —
  `scope_structure__intent_behavior__reference_tick_tests::set_reference_tick_floors_spot_and_is_idempotent`; `reference_tick_guard_tests.move` —
  `scope_structure__intent_guard__reference_tick_tests::set_reference_tick_missing_exact_history_aborts` and `scope_structure__intent_guard__reference_tick_tests::set_reference_tick_wrong_pyth_feed_aborts`.
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
- **Pinning tests:** `live_valuation_guard_tests.move` —
  `scope_mechanics__intent_guard__live_valuation_tests::price_memo_rejects_non_monotone_surface_over_active_ticks`; and
  `current_nav_flow_tests.move` —
  `scope_flow__intent_guard__current_nav_tests::current_nav_rejects_non_monotone_active_book_surface`.
- **Reopen when:** NAV valuation gains a safe per-market skip/carry design, the
  LP flush no longer uses one shared mark for both queues, or the production BS
  verifier proves monotonicity before the surface reaches Predict.

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
