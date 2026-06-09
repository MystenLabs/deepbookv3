# Predict Bug Ledger (framework bug-finding pass)

> **Status: EMPTY — to be populated by the executing session.** This is the deliverable
> ledger for the unit-test framework effort (see `.redesign/UNIT_TEST_FRAMEWORK_PLAN.md`).
>
> Each entry is a discrepancy between an **independently-derived** expected value and the
> contract's **actual** behavior, found by a test that is left **RED**. Bugs are **NOT fixed
> here** — fixes are a separate effort. Entries map 1:1 to `// KNOWN-FAILING: BUG-NNN` tags in
> the test tree and to the suite's failing-test count (the manifest check in the plan §7).
>
> **Cardinal rule:** never adjust an expected value to make a test pass, and never assert the
> buggy behavior as `expected_failure`. A failing test found a bug — leave it failing, record
> it here.

## Reconciliation

- Expected-failing tags in tree: `grep -rho 'KNOWN-FAILING: BUG-[0-9]\+' packages/predict/tests | sort -u`
- Ledger entries here: `grep -o 'BUG-[0-9]\+' .redesign/BUGS_FOUND.md | sort -u`
- The two lists **must match**, and the count **must equal** the suite's failing-test count.

## Special status: DEFERRED (out of scope — do not treat as fresh findings)

- **R1 / `plp.move:619` (`synced_pool_value` unguarded subtraction underflow)** — flagged-not-fixed; owned by a separate effort. Overlaps C3.
- **C3 (`strike_nav_matrix::live_value` aggregate-floor precondition)** — product decision; separate effort.

If a P0-3 (PLP sync NAV) test naturally hits either, ledger it under this section as `DEFERRED`, not as a new BUG-NNN.

---

<!-- Entries begin here. Template per the plan:

## BUG-001 — <one-line title>
- **Test:** `<module>::<fn>` (`packages/predict/tests/<path>:<line>`)
- **Inputs:** <exact inputs>
- **Expected (independent):** <value + how derived: hand math / scipy fixture / spec>
- **Actual (contract):** <value>
- **Suspected root cause:** <file:line + reasoning>
- **Class:** economic | liveness | correctness | rounding
- **Severity:** critical | high | medium | low
- **Status:** RED (known-failing)

-->

_No bugs recorded yet._
