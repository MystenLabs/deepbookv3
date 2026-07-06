# Predict Response-Policy Register

Updated 2026-07-06. This is the tracked register of **settled response-policy
decisions**: for each degenerate or adversarial state the protocol can reach,
the behavior someone deliberately chose, why, and the tests that pin it.

`open-items.md` tracks work that is still open; when an item closes, the
*decision* it produced graduates into an entry here instead of surviving only
in a commit message. `docs/risks.md` is the public disclosure and must describe
the behavior recorded here — a `risks.md` claim about failure behavior that has
no register entry (or contradicts one) is a finding.

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
  was incidentally the only u64-headroom bound on fill math; at a
  dust-but-nonzero mark a supply fill can overflow u64 or ratchet
  `total_supply` — reopened as the C-4 extension (see RP-2).
- **Pinning tests:** `pool_valuation_flow_tests.move` —
  `finish_flush_with_zero_pool_nav_and_empty_queues_succeeds`,
  `finish_flush_with_low_plp_price_and_empty_queues_succeeds`,
  `finish_flush_with_high_plp_price_and_empty_queues_succeeds`.
- **Reopen when:** the fill-site policy (RP-2 / C-4) turns out not to cover a
  mark-level degeneracy.

## RP-2: Degenerate LP fills at the drain — skip/refund (decided; implementation open, C-4)

- **Trigger state:** at the frozen mark, the head request's fill is not
  executable: supply mints zero shares, withdraw pays zero, `pool_value == 0`,
  or (dust-but-nonzero mark) the share computation exceeds u64.
- **Controller:** market (the mark) × user (request size). The one
  protocol-controlled action in the loop is share issuance itself.
- **Blast radius:** `lp_book::drain` runs inside `finish_flush`; an aborting
  fill aborts the entire pool-wide flush until the request owner voluntarily
  cancels. A hostile or absent owner stalls it indefinitely.
- **Response — current code:** `abort` (`EInvalidDrainMark` for the zero/zero
  cases; a raw untracked u64-cast abort in `math::mul_div_down` for the
  overflow case). This rung is wrong for a mandatory path.
- **Response — decided:** `skip/carry` (or auto-cancel-and-refund). Fills are
  computed in u128 and classified before execution; "does not fit u64" is the
  same outcome as "rounds to zero" — not executable this flush, flush
  completes. Whether supply fills execute at all below an executable mark
  price (ratchet prevention: never mint into a degenerate ratio) is decided
  together with the P-7 limit-field policy. Implementation tracked as C-4.
- **Reasoning:** the drain must be total over request content. Beyond the
  stall, a fill that *fits* at a dust mark mints ~1e18 shares; `total_supply`
  only shrinks via withdrawals, so the inflated supply persists after NAV
  recovery, permanently pinning PLP price at dust and widening the overflow
  band (one dust fill converts a micro-DUSDC fragile window into a
  thousands-of-DUSDC one). Skipping fills at inexecutable marks enforces the
  one maintainable direction of the old invariant: the protocol never
  *manufactures* the degenerate ratio, even though it cannot forbid NAV
  collapse.
- **Risk profile:** `BEST-GUESS` — organic reachability requires near-total LP
  wipeout (pool value in a micro-DUSDC band at the flush instant) and cannot
  be cheaply forced (attacker must win oracle-priced bets). The asymmetry is
  the ratchet: improbable per flush, irreversible once. Harness campaign
  candidate: drive NAV collapse and measure the window width and ratchet
  onset.
- **Pinning tests (current abort behavior):** `lp_book_tests.move` —
  `priced_supply_with_zero_pool_value_aborts`,
  `priced_supply_that_rounds_to_zero_shares_aborts`,
  `priced_withdraw_that_rounds_to_zero_payout_aborts`. The u64-overflow
  boundary is untested; the C-4 fix must add boundary tests on both sides of
  each classification.
- **Reopen when:** C-4 lands (rewrite this entry to the implemented behavior)
  or P-7 chooses stay-queued semantics that interact with skip.
- **Note:** `docs/risks.md` claimed the skip/refund behavior as shipped from
  PR #1071 until corrected on 2026-07-02 — a decision documented without a
  pinning test un-decides itself.

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
  pinned — tracked as a test gap in open-items C-4-adjacent follow-up.
- **Reopen when:** the exclusion basis becomes non-sticky, or RP-2's
  implementation changes what a zero mark means for the queues.

## RP-4: Past-expiry-but-unsettled market blocks the flush (no substitute mark)

- **Trigger state:** an active market is past expiry but Propbook has no
  normalized spot at the exact expiry millisecond yet.
- **Controller:** external — resolution relayer liveness (Pyth Lazer
  resolution endpoints supply the exact-timestamp print).
- **Blast radius:** the whole flush aborts while the market is in the window.
- **Response:** `pause`-with-recovery — abort and retry; the recovery path is
  the permissionless exact-ms insert followed by passive settlement. The
  keeper does not flush inside the window. Deliberately **no substitute
  mark**: a settlement-dependent market has no well-defined true value, and
  the single mark prices both queue directions — contribute-0 dilutes
  incumbents on supply, free-cash overpays withdrawals.
- **Reasoning + evidence:** `settlement-liveness.md` (accepted operational
  assumption, testnet evidence); grid-snap at creation makes the key
  representable, resolution endpoints make it producible.
- **Risk profile:** `MEASURED` (testnet evidence in `settlement-liveness.md`);
  residual = prolonged relayer outage blocks LP fills pool-wide, disclosed in
  `risks.md`.
- **Pinning tests:** not yet catalogued — fill in when this entry is next
  touched.
- **Reopen when:** settlement-v2 introduces a valuation-safe representation
  for unsettled past-expiry markets.

## RP-5: BS-vs-Pyth basis/deviation circuit breakers removed

- **Trigger state / threat:** a compromised or adversarial Block Scholes
  operator steering live pricing away from the Pyth spot.
- **Controller:** external (oracle operator).
- **Blast radius:** every live price — entry prices, NAV marks, liquidation.
- **Response:** accept + disclose (commit `057f9565`). The cross-feed
  deviation guards are gone; the static pricing-safe envelope remains
  (positive spot/forward, bounded basis, bounded SVI inputs, `|rho| ≤ 1`,
  sigma band). A correct-but-adversarial source can steer prices anywhere
  inside that envelope.
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
  (`rounding-policy.md` R1); seniority must be explicit so the deferred cut
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
  wall. Findings: `stress/mint-batch-findings-2026-07-01.md`. Magnitude is
  book- and transaction-shape-dependent — localnet gives mechanism and
  direction, not a permanent production multiplier; flows designed near the
  ceiling should measure, not assume.
- **Pinning tests:** not yet catalogued — platform metering behavior, not
  pinnable in Move unit tests by nature; the evidence is the harness finding
  linked above (`experiments.md` E4).
- **Reopen when:** Sui's metering model changes materially, or a production
  measurement diverges from the localnet ceiling enough to invalidate the
  integrator guidance.

---

## Update rules

- New entries come from: closing an `open-items.md` item that embodied a
  response decision; removing/weakening any guard (mandatory duty-inventory
  entry); an audit or review finding an undecided state that is then decided.
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
  findings doc under `stress/` or a dated findings file.
