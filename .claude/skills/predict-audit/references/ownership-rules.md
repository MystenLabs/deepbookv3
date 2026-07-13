# Ownership, boundary & policy rules (R1–R7) — the ownership-walk spec

This is the rule-set the **ownership walk** checks at every function node. It is the contextual subset of
the repo's rules (distilled from `.claude/rules/move.md` + the absorbed `rule-auditor` families 6/8/9) —
the rules whose violation is **invisible in a normal read and surfaces only as money drifting**.

## The thesis (why these exist)
Every concern — a fact, a guard, a derivation, a policy decision, a piece of state — should have **exactly
one owner**: the place whose contract depends on it AND that has the knowledge to compute it correctly. The
failure mode of scattered ownership is a specific dangerous bug: the same economic quantity computed/clamped/
guarded in two places **drifts → double-count, gap, or silent bypass**. Single ownership also buys local
reasoning (verify in one place) and safe evolution (change in one place, no surprised caller). The patterns
lean into Move's grain: fields are module-private (only the declarer mutates correctly); txs are atomic
(defensive "in case the callee aborts" preflight adds no safety, only drift surface).

## How to apply (per function)
For each function, ask its node's questions below against the module's **responsibility-map entry** (what it
SHOULD own) and the entries of modules it composes. A violation is a **misplaced responsibility**, not a
style nit. Before flagging, check the **known intentional exceptions** in `AGENTS.md` and committed
predeploy policy/open items — these rules false-positive heavily on deliberate architecture.

---

## R1 — Producer-fact / single source of truth
**Rule:** A module returns facts it owns (quantities it's the source of truth for, derived within its own
domain). It must NOT pre-shape a return for one consumer's policy, and must NOT apply a **lossy transform**
(clamp-at-zero, `min`/`max` against another quantity, `saturating_sub`, rounding) to a value that **any
consumer does further arithmetic on**. Each economic quantity is clamped exactly once, at the policy owner,
as the last step before use.
- **Why:** lossy ops are one-way — the consumer can't recover what was removed, so a correction derived from
  the pre-transform identity double-counts or gaps. This is the rule behind Predict's worst near-misses
  (disjoint-backing under-reservation, the conservative-NAV Q-haircut, C1 partial-close rounding).
- **Per-function check:** does this return value get clamped/rounded/min-maxed, and does a caller then do
  arithmetic on it? Does the return name encode a stance (`*_optimistic`, `*_conservative`, `net_*`)? Is the
  same excess clamped here AND at the caller?
- **Signatures:** stance-named returns; a consumer/test that adds-back, re-derives, or inverts a producer's
  step; the same quantity clamped at two altitudes.
- **Intentional exceptions (do NOT flag):** a producer using a clamped value in its OWN assert/internal state
  (the rule governs returned shape only); a `saturating_sub` that IS the policy applied once at the owner
  with a why-clamp comment (e.g. `current_nav`'s degenerate-underwater cash floor — it maximizes NAV when it
  fires, by design); the most-derived owned fact (a reserve from the module's own fee basis is a fact, not a
  raw internal).

## R2 — Derived-value single ownership
**Rule:** Compute a derived value at the leaf that actually needs it. Do NOT thread a derived value through
conduit helpers (A derives x → returns to B → B passes x to C: move the derivation into C). EXCEPTION that
proves the rule: when multiple call sites must produce **bit-identical** terms for a stored aggregate's
round-trip (insert/remove/settlement-recompute), the derivation is ONE owned function every site calls —
never re-implemented per site.
- **Why:** threading couples A/B/C to x's shape and makes B a pointless conduit; re-implementing a shared
  derivation lets the sites drift, and for a stored aggregate that means the remove doesn't cancel the insert
  → accounting bug.
- **Per-function check:** is a derived accounting/index value passed through a helper only so another helper
  can write/assert it? Is a formula re-expressed at a second call site instead of calling the canonical
  evaluator? For aggregate insert/remove/recompute, do all sites call the SAME function?
- **Signatures:** a helper chain that only shuttles a derived value; a formula duplicated across mint-insert
  and settlement-recompute; a lossy repack of `quantity`/`floor_shares` through the packed
  order id.
- **Input shape corollary:** signature shape is part of ownership. Pass a domain object when the callee needs
  that object's identity, authority, current state, invariants, or several facts owned by that object. Pass a
  narrow value when the callee is a pure formula and should not know the broader object/config concept. A run
  of same-typed primitive fields from one owner is a transposition risk; prefer the owner or a named summary
  unless the primitive signature is deliberately preserving a pure math/test-oracle boundary.
- **Intentional exceptions:** `strike_payout_tree::payout_terms` IS the one canonical evaluator — every
  site calling it is the rule working, not a violation; a deliberate loop-invariant hoist (computed once
  above a loop) is not "should compute at use"; values returned because the caller genuinely cannot derive
  them (order ids, payouts, fees, event data) or that must be sampled once (expensive / must stay identical
  across a local flow).

## R3 — Guard ownership / layer placement
**Rule:** Every assertion has one owner: the module/function whose contract depends on it. Flow gates
(pause/valuation-lock/auth/user-permission) live in the public flow fn; cross-object **binding** checks live
in the **composing** module (only it knows objects A,B,C are meant to go together); local operation
preconditions live in the **callee**; math/utility/leaf modules guard **math only** (div-by-zero, overflow,
data-structure bounds) — never application policy ("this state shouldn't happen", "this user type differs",
"this rate is too high"). Relational checks across fields live with the multi-field setter that can violate
them. *(ex-rule-auditor Agent 6)*
- **Why:** a guard in the wrong layer is either redundant (and drifts from its twin) or a hidden cross-module
  invariant that ambushes a future caller; a leaf that encodes policy silently enforces business rules a new
  caller can't see; a flow re-implementing leaf math duplicates a source of truth.
- **Per-function check:** is this assert about a fact THIS function's contract depends on? Is app policy
  sitting in a leaf/math module? Is a binding check in a leaf instead of the composer? Is a relational
  invariant split across single-field setters?
- **Intentional exceptions:** a `public(package) assert_can_*` exposed because a composer must know a fact
  before sequencing objects; a config bound read directly as an upgrade-required hard cap.

## R4 — Validate-before-mutate
**Rule:** Before mutating state, a function first validates the **mutation-independent** facts it owns: flow
gates, authorization, object binding, branch/lifecycle policy, static creation inputs. Validate before
consuming **irreversible** resources (burning coins, destroying objects, compaction replacing dense state).
A post-mutation-dependent calculation is allowed only after the mutation-independent facts are checked and
the dependency is obvious or commented. A mid-function assert is often a phase boundary → extract a helper
that owns its own pre/postconditions. *(ex-rule-auditor Agent 8)*
- **Why:** atomicity reverts a failed tx, but the SHAPE matters — "prove you may act, then act" is auditable;
  abort-after-partial-mutation and pre/post-state checks tangled together are not; and you must prove
  validity before irreversibly consuming a resource.
- **Per-function check:** are auth/gate/binding checks before the first state write? Is anything irreversible
  consumed before its validity is proven? Is there a mid-function assert that's really a second phase?
- **Intentional exceptions:** quote/liability/accounting values that intentionally depend on post-mutation
  state, when the flow facts are already checked and it's commented.

## R5 — Leaf self-consistency & no defensive duplication
**Rule:** Leaf primitives in `public(package)` data structures stay self-consistent for the domain facts
they own (valid ranges, sufficient quantity/balance) REGARDLESS of caller validation — don't move a leaf's
guard up to "the current caller validates first". Conversely, a caller that merely duplicates a leaf's exact
semantic guard is clutter (keep it only for a richer business error or a strictly tighter bound). Don't add
overflow/underflow/cast asserts that only replace Move's VM aborts. Don't preflight another module's leaf
precondition just to avoid a later abort. *(ex-rule-auditor Agent 9, contextual half)*
- **Why:** a leaf that trusts callers is fragile the moment a new caller forgets; a redundant caller guard is
  pure drift surface; re-implementing Move's free atomic overflow check is noise.
- **Per-function check:** does a leaf rely on its caller for a domain fact it owns? Does a caller re-assert a
  leaf's exact guard with no added value? Is there a manual overflow/cast assert duplicating a VM abort?
- **Intentional exceptions:** a caller guard with a semantically richer error for a different business
  precondition, or a strictly tighter bound; named semantic/solvency/auth/lifecycle/gas asserts (keep).
- **Trust-boundary carve-out:** at the protocol's outer trust boundary (a public entrypoint taking
  attacker-chosen primitives, external coins, or oracle payloads) input validation is owned by the boundary
  regardless of any downstream leaf guard (fail-fast). Do NOT flag such a boundary check as a removable
  defensive duplicate; R5 non-redundancy governs internal package composition only.

## R6 — Encapsulation (Move's grain)
**Rule:** A public entrypoint that mutates a `Balance`/field lives in the module that **declares** that field
(fields are module-private). Pass other domain objects as params rather than adding leaky `join_x`/`split_x`
accessors. Once a typed domain object exists, use it through the flow instead of re-passing/recomputing its
raw fields (use `Order`, not the unpacked order-id fields, except at entry/exit/storage boundaries).
- **Why:** only the declaring module can keep a field's invariants; leaky accessors export internals and let
  the invariant be broken from outside; re-passing raw fields loses the type's guarantees.
- **Per-function check:** is a field mutated from outside its declaring module via an accessor? Does this
  thread raw primitive fields where the typed object should travel? Is the move-version gate on the mutated
  object (not an unrelated one)?

## R7 — Ownership clarity
**Rule:** For each piece of state / policy / fact this function touches, is it **clear who owns it**? Or is a
responsibility smeared across modules — two places that both think they own it, or a field whose sole writer
and sole reader live in different modules with no clear owner of the lifecycle? A write-only field (sole
consumer removed) and a read-only mirror are ownership-clarity failures.
- **Why:** unclear ownership is where the next bug hides — nobody is responsible for the invariant, so it
  drifts (the trading-loss rebate reserve became write-only when its consumer was deleted: the field's
  lifecycle had no owner).
- **Per-function check:** does this write a field nothing reads, or read a mirror nothing maintains? Is the
  policy this enforces owned here, or borrowed from a module that should own it?

---

## Classification (every confirmed violation)
Tag each: `fix-code` (smallest change + tests), `update-rule` (the violation is defensible → draft the
narrowest `move.md`/`AGENTS.md` exception + rationale), `design-decision` (intentional, needs a human call),
or `false-positive`. **Calibration:** a rule tripped repeatedly by intentional architecture is a candidate
rule-exception, not N repeat findings — rules stay strict enough to catch real risk, precise enough not to
flag deliberate design.
