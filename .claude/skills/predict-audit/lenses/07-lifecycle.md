# Lens 07 — State Machine, Lifecycle & Sequencing

## STEP 0 — read shared context (required)
Read `../primer.md` in full first. Treat it as binding. If you cannot read it, stop and ask.

## Your lens
State machine, lifecycle & sequencing. The question: is the protocol correct in TIME and ORDERING — across
every phase transition, every partial state, and every interleaving of calls within a PTB? You care about
temporal correctness (pre/postconditions of transitions, reachable intermediate states, locks, idempotency),
not static economic invariants or pricing math (other lenses own those). Treat each shared object as a state
machine and each public entry as a transition.

**Produce a STATE-MACHINE MODEL, then audit it:**

1. **PER-OBJECT LIFECYCLE** — for `ExpiryMarket`, `PoolVault`, `predict_account`, the propbook feeds, and the
   `account::Account`, draw the state machine: states (created → active → settled → compacted;
   trading-enabled/paused; valuation-locked/unlocked; stake-epoch states) and per transition: entry
   function(s), precondition gates (phase, pause, version, valuation lock), postconditions it must establish.
   Flag any transition whose precondition set is incomplete or whose postcondition isn't guaranteed on every
   path (including early returns and abort-after-partial-mutation).

2. **PHASE / GATE CONSISTENCY** — confirm the mutually-exclusive locks are exclusive: which ops require
   trading-enabled-and-not-paused, which require NOT valuation-in-progress, which require valuation-in-progress.
   Find any op reachable in a wrong phase, or any pair runnable in an order the code assumes impossible (settle
   a paused market? compact an unsettled one? mint into a settling one? create a market mid-valuation?).
   Per move.md, exits/settlement/valuation should be blocked only by the valuation lock, not trading-pause —
   verify that holds.

3. **VALUATION-LOCK ATOMICITY** — the full-pool valuation (`PoolValuation` hot potato) must open and close
   within ONE tx, snapshot the active-expiry set, value each expiry exactly once, and price PLP shares only
   against a fully-finished sync. Stress it: can the lock be left open or closed early? Can the expected set
   drift between snapshot and finish? Can a market be created/registered or a config changed mid-valuation?
   Can shares price against a partially-built NAV? Can an expiry be valued twice or zero times? Note: the flush
   prices supply AND withdraw at one frozen mark — a half-built mark breaks both.

4. **INTRA-PTB INTERLEAVING (high-value hazard)** — within one PTB the attacker sequences calls freely. Find
   transitions that run OTHER state machines as a side effect (a mint/redeem/supply/withdraw that triggers a
   budgeted passive-liquidation pass; a permissionless sync that triggers liquidation + cash rebalance). For
   each: what intermediate state does the outer call expose, can a user observe/exploit being-acted-on mid-call
   (an order liquidated during its own redeem), is the outcome order-dependent in a surprising way? Map every
   "function A internally drives state machine B" coupling.

5. **IDEMPOTENCY & RE-ENTRY** — passive settlement is terminal/first-writer-wins; position add/remove; summary
   resolve-when-empty; partial-close → replacement-order. Verify each is safe in the orders that can actually
   occur, that "do it twice" no-ops or aborts cleanly (never double-applies), and "do it in the wrong order" is
   blocked. Check the partial-close → reinsert path keeps position/exposure/payout-tree/accounting in lockstep.

6. **NON-LANDABLE / STRANDED STATES** — sequences that leave the system where a required follow-up can't happen
   or value is stuck: a market compacted without the pool-coordination step (cash/capital stranded); a settled
   expiry not unregistered from the active set; an unsettled past-expiry market blocking the whole flush
   (documented precondition — confirm it fails closed, don't re-flag as new); funds owed but unreachable; a
   cadence deploy that hard-aborts instead of skipping an occupied slot.

7. **KEEPER / PERMISSIONLESS TIMING** — passive-liquidation budgets, scan cursors/watermarks, permissionless
   sync: can keeper-action ordering starve a needed transition, advance a cursor past unprocessed work, or let
   a griefer force/skip transitions for others?

## Output
For each finding: the objects/states involved, the exact PTB-ordered sequence reaching the bad state, whether
it's attacker-reachable or only operator error, the consequence (brick / value-stranded / order-dependent
payout / double-apply), confidence, Evidence. Emit in the primer's report format; list the state machines
modeled + transitions verified, and Top 3. Return structured findings to the orchestrator or write the solo
report. Never modify source.
