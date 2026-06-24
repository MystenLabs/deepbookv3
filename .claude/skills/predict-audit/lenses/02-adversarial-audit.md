# Lens 02 — Adversarial Security Audit

## STEP 0 — read shared context (required)
Read `../primer.md` in full first. Treat it as binding. If you cannot read it, stop and ask.

## Your lens
Adversarial security audit — **destructive**. Break the protocol: steal funds, mint value from nothing, brick
a flow, or extract value from another party. Assume a motivated, well-capitalized attacker who submits
arbitrary PTBs, controls ordering within their own txs, runs keeper ops, holds any permissionless object, and
times actions around oracle-freshness and flush windows. Do NOT assume any input is well-formed unless the
code provably forces it. This is the heavy, long-running pass — build concrete exploit chains, not abstract
worries, and where you can, **reproduce them** (Python for accounting/sequence logic; localnet for a full PoC,
handed back to the main loop).

**Work actor-by-actor.** Enumerate what each can call, then ask "what is the worst thing they can do to
someone else?":
- Malicious TRADER (owner + delegated cap/proof holder) — vs LPs, other traders, protocol.
- Malicious LP — async supply/withdraw timing against the frozen flush mark; incentive-vesting grab; NAV-mark gaming.
- Malicious/greedy KEEPER — passive-liquidation candidate selection, budget exhaustion, sync ordering side effects.
- Malicious BUILDER — fee attribution / claim paths.
- ORACLE OPERATOR — Block-Scholes spot/forward/SVI pushes into propbook (note: on-chain basis/deviation
  guards were removed by design per D031, so the operator is trusted **within** the consumer envelope in
  `predict::pricing` — your job is to find what the envelope does NOT bound, and any path that reaches pricing
  without it).
- ACCOUNT ADMIN — `deauthorize_app<PredictApp>` and other custody-layer authority intersecting an economic harm.
- Anonymous GRIEFER — anyone with gas and no special objects.

**Attack categories (build PTB-level chains):**
- Value extraction: rounding-direction abuse, double-counting, mint/redeem accounting mismatches, **NAV
  mark-to-flush timing** (supply before / withdraw after a favorable mark; price against a half-built NAV),
  settled-vs-live payout arbitrage, fee/penalty/builder-cap interactions, the exact-amount vs exact-quantity
  mint variants gamed against each other.
- Authorization bypass: any custody/payout move without the right proof/cap/owner; proof/cap reuse,
  forged-by-construction, or aimed at the wrong manager/market/expiry; the `account` app-auth boundary.
- Cross-object confusion: mismatched market ↔ propbook feed ↔ underlying ↔ manager bindings; passing one
  expiry's object into another's flow; stale mirrored state (versions, stake epoch).
- Sequencing/atomicity in one PTB: interleave mint/redeem/liquidate/sync/supply/withdraw to force an
  intermediate state the code assumes impossible; can the valuation lock be entered/left so shares price
  against a partial NAV?
- Sentinel/edge abuse: `pos_inf_tick`/`neg_inf` ranges, zero/extreme quantities, max-leverage, boundary
  ticks, the smallest non-trivial position, the largest.

**Explicit DoS / liveness sub-mandate (rank as high as theft — a bricked market is a failed launch):**
- Any underflow-aborting subtraction on a critical path (drive state so redeem/settle/supply/withdraw/
  liquidation permanently aborts — cross-reference ROUNDING_POLICY R1).
- Griefing via permissionless entry (forcing others to pay liquidation/sync work; reshaping NAV before a victim's tx).
- Unbounded/growing computation on hot paths (NAV valuation, treap `walk_linear`, liquidation-book paging/scan).
- Starvation of a needed risk-reducing action (under-floor liquidation, surplus release, settlement, flush).
- Funds trapped: value owed but unwithdrawable.

## Output
For each finding: the concrete PTB-ordered call sequence, the exploited state, realistic profit/damage,
preconditions, confidence, and Evidence (PoC sim/test if you built one). Emit in the primer's report format.
End with the attack-category × actor × subsystem matrix you exercised, where you ran out of time, and Top 3.
Return structured findings to the orchestrator, or write
`.claude/predict-review/reports/<date>/02-adversarial-audit.report.md` when solo. Never modify source.
