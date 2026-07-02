# Lens 01 — Economic Invariants & Solvency

## STEP 0 — read shared context (required)
Read `../primer.md` in full first (protocol, current module map, scope, prior-awareness, the empirical
toolbox, the report format). Treat it as binding. If you cannot read it, stop and ask.

## Your lens
Economic invariants & solvency — **constructive + empirical**. Build the protocol's invariant spec, verify
the code maintains it across every flow, and **prove the load-bearing ones with a sim** rather than by prose.
You are not primarily hunting exploits (lens 02 does that); you establish what must always hold and check it
holds. The spec itself is a deliverable even where you find no bug.

Produce:

1. **INVARIANT LEDGER** — every invariant the protocol relies on to stay solvent, consistent, and fair. For
   each: state it precisely; cite where it is ESTABLISHED and where it is DEPENDED ON (file:line); classify
   it (solvency / accounting-consistency / ordering / conservation); judge whether the code maintains it
   across ALL touching flows. Give special weight to **cross-module and cross-package** invariants — a
   property established in one module/package and silently relied on in another (e.g. `expiry_cash`'s
   `cash_balance >= payout_liability + rebate_reserve`; the exact `current_nav` mark used identically for PLP
   supply and withdraw; the `strike_payout_tree::payout_terms` round-trip — mint insert must add bit-equal what remove subtracts).

2. **ECONOMIC FLOW MAP** — trace every path where value (DUSDC, DEEP, SUI, PLP) enters, moves, or leaves:
   mint, live redeem, settled redeem, passive liquidation, rebate claim, async supply/withdraw + privileged
   flush, fee / builder-fee / EWMA-penalty routing, incentive vesting, stake/unstake, protocol-profit
   materialization (`pending_protocol_profit`, D033). For each: what is conserved, what is created/destroyed,
   and who is the counterparty to every gain and loss (trader / LP / protocol / builder).

3. **RISK-INCREASING vs RISK-REDUCING INVENTORY** — classify each state-changing action by whether it raises
   or lowers protocol/LP risk. Confirm risk-increasing actions are gated/collateralized at entry, and
   risk-reducing actions (passive liquidation, settlement, surplus release, flush) cannot be indefinitely
   blocked, starved, or front-run.

4. **LEAK ANALYSIS** — for each flow: can value be minted from nothing, double-counted, stranded/trapped, or
   transferred without consideration? Where does rounding accrue, in which direction, to whose benefit
   (apply `packages/predict/predeploy/rounding-policy.md` R1/R2)? Is every subtraction on a settle/redeem/backing/withdraw path provably
   non-underflowing or saturating?

**Focus areas (scope, not conclusions):**
- The cash-backing invariant (`expiry_cash`) and whether it is re-checked after every cash mutation
  (mint, redeem, liquidation, settlement, compaction, flush rebalance).
- The relationship between the pre-settlement live backing (the exact `quantity - floor_shares` plus the aggregate λ buffer, D030) and the exact
  settled liability — what guarantees the former bounds the latter for every order.
- The exact `current_nav` mark (payout-tree `walk_linear` − leveraged `correction_value`, floored) and the
  precondition it rests on (every order whose gross value crossed its knock-out level (`floor_amount / liquidation_ltv`) has been liquidated before valuation — the
  aggregate-floor precondition; see move.md NAV rules + the C3 note in `packages/predict/predeploy/rounding-policy.md`).
- PLP share-pricing symmetry: supply and withdraw priced at the SAME frozen `current_nav` in `finish_flush` /
  `drain_lp_requests`; confirm `supply_NAV = TRUE = withdraw_NAV` at the valuation boundary (no over/under-count).
- The rebate-reserve lifecycle (growth from fees, resolution, residual handling) and `pool_accounting` profit
  basis / loss watermarks / funding caps / `pending_protocol_profit` deferred-carry.
- Any accumulator using unchecked arithmetic; the partial-close → reinsert path keeping the
  exposure/payout-tree/accounting machines in lockstep.
- Event-VALUE correctness (not naming/hygiene — that's the rule-sweep): are the amounts emitted by money events (`OrderMinted` net_premium/financed_amount, vault/fill events) the REAL economic quantities, and do they suffice + round-trip for an off-chain solvency/PnL reconstruction? A wrong-but-well-named field misprices every downstream consumer and is invisible to the hygiene sweep.
- Sibling-package internal invariants (NOT just the trust boundary lens 08 owns): propbook's `oracle_lane` exact-timestamp/latest store + feed accept/no-op conditions, and `account`'s deposit/withdraw/settle balance conservation, each have their OWN solvency/consistency invariants — audit them first-class, not only through "what predict trusts them for."

## Empirical mandate (required — do not skip)
Back the load-bearing invariants with a sim, written to the scratchpad:
- Reuse `packages/predict/simulations/python_indexes/` (the Move `strike_payout_tree` + `liquidation_book`
  mirrors) and `python_replay.py` (mint admission / pricing / NAV mirror) to drive **randomized sequences**
  of mint/redeem/liquidate/supply/withdraw, asserting after each step: cash-backing holds, NAV supply==withdraw,
  no negative balances, conservation of DUSDC across the trader/LP/protocol/builder split, and rounding favors
  the protocol (never the user). Report any sequence that breaks an invariant as a finding with the seed/inputs.
- Python sims are subagent-safe. A **localnet** parity run (`bash run.sh`) is main-loop-only — if you need one,
  state the exact command + scenario and hand it back rather than running it yourself.
- Distinguish a real maintained-by-construction invariant (R1) from one that only happens to hold on the
  tested paths.

Deliver the full ledger and flow map regardless of how many issues you find.

## Output
Emit findings in the primer's report format (Severity / Location / Claim / Scenario / Impact / Confidence /
Settled-ref / Recommendation / Evidence). End with **Coverage** (invariants + flows you traced vs did not)
and **Top 3**. When run by the orchestrator, return the structured findings object it asks for; when run
solo, write the report to `.claude/predict-review/reports/<date>/01-invariants.report.md` (create it) or
print inline if writes are forbidden. Never modify any source file.
