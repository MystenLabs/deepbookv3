# Lens 06 — Assertions, Validation & Error Model

## STEP 0 — read shared context (required)
Read `../primer.md` in full first. Treat it as binding. If you cannot read it, stop and ask.

## Your lens
Assertions, validation & the error model. The question: is every precondition checked at the right BOUNDARY,
by the right OWNER, exactly ONCE, with a correctly-named error — and can the error constants and their checks
be consolidated more cleanly? You care about guard correctness and placement, not exploit construction or
pricing math (other lenses own those). Assertion density clusters in `config_constants`, the propbook feeds,
`order`, `plp`, and `strike_exposure` — start where guards cluster.

**Produce a VALIDATION MAP (boundary × owner)** and audit it on these axes:

1. **OWNERSHIP** — does each guard live in the module that OWNS the invariant?
   - Math/utility/leaf modules (`fixed_math`, the index structures, `oracle_lane`) guard MATH preconditions
     only (div-by-zero, overflow, insufficient balance, ordering the algorithm requires). They must NOT encode
     application policy ("this state shouldn't happen", "this user type differs", "this rate is too high").
   - Application guards (eligibility, admission policy, economic limits, phase rules) belong in the calling/
     owning module, not pushed into a leaf.
   - Relational checks across fields (min < max, upper > 2*lower) belong WITH the multi-field setter that can
     violate them — not split across single-field setters each individually bounded but jointly inconsistent.
   - Flag every guard whose precondition is enforced OUTSIDE the function that depends on it (a denominator-zero
     protection in config validation rather than the math; an invariant a leaf assumes but a parent
     establishes). Judge whether the indirection is safe or a footgun for future callers.

2. **MISSING** — preconditions assumed but not asserted: fields that should be relationally constrained but
   aren't; subtractions that could underflow with no guard and no proof of safety; inputs trusted without a
   shape check; state transitions with no phase/precondition gate. Distinguish "provably safe, no assert
   needed" from "actually unguarded". (Note: per move.md, do NOT recommend adding asserts that merely replace
   Move's native overflow/underflow VM aborts — those are free invariant checks.)

3. **REDUNDANT / DUPLICATED** — the same precondition in caller and callee; validation re-done after an
   upstream guarantee holds; duplicate assertions; checks that can never fail given the type system or prior
   validation. Propose which copy to keep (favor the owner / earliest correct boundary), per the leaf-guard
   rule (don't move a leaf's self-consistency guard to its caller).

4. **CONSOLIDATION & GROUPING** — can scattered checks become one clearly-named `assert_*` that call sites
   share? Families of bounds in `config_constants` that should be one envelope? (Apply the loop-hoist caution:
   don't move a check in a way that changes WHEN it fires on a hot path.)

5. **ERROR-NAME CORRECTNESS** — does each error constant's name cover EVERY case that triggers it (a name
   implying "exceeds max" that also fires on zero is wrong — prefer a neutral name)? Codes distinct where
   tests/aborts must tell them apart? Any constant defined but never raised, or two distinct conditions sharing
   one code? Any expected_failure test asserting the wrong code, or a renumbered-with-a-gap constant set?

## Output
For each finding: location(s), the precondition, the axis (ownership / missing / redundant / consolidation /
naming), the concrete fix (move here / add this / delete this / rename to X / group as assert_Y), confidence.
Separate correctness-relevant (missing/mis-owned guard permitting bad state) from hygiene (naming/dedup/
grouping). Emit in the primer's report format; list the modules mapped + error-constant count accounted for vs
total, and Top 3 (correctness first). Return structured findings to the orchestrator or write the solo report.
Never modify source.
