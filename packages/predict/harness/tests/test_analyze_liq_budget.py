"""Analysis checks for the liq-budget section (liqBudgetProbe.ts, DBU-695).

The section turns a run's trace into the number `max_trade_liquidation_budget` gets set from, so
its arithmetic is worth pinning without an hour of localnet. Each case synthesises a trace from a
KNOWN cost model — comp = base + slope*min(budget, book) — and asserts the reported slope, base
and cap crossing recover it, in both the wall-reached and wall-not-reached branches.

Expected values are hand-computed and written as literals (the working is shown at each one), not
re-derived with the fit's own formula, so a change to that formula fails these tests instead of
moving the goalposts with them.
"""

from __future__ import annotations

import io
import json
import re
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from harness import analyze

BASE = 400_000_000
CAP = 5_000_000_000  # the per-tx computation cap, asserted against analyze.COMP_CAP below
LADDER = [(0, 24), (900, 512), (1800, 1500), (2700, 3000)]
# Six probes per rung, offsets summing to exactly zero so the fitted base is not pulled off the
# true one by the fixture's own noise.
NOISE = [(2 * k - 5) * 100_000 for k in range(6)]



def _write_trace(path: Path, rows: list[dict]) -> None:
    """Write trace rows, stamping the schema the real producer (`appendTrace`) stamps.

    Routed through one helper so a fixture cannot drift from what the loader accepts — the
    stricter loader rejects an unversioned record, which is exactly the drift worth preventing.
    """
    path.write_text("\n".join(json.dumps({**row, "schema": 1}) for row in rows))


def _synthesise(root: Path, books: list[int], slope: int) -> Path:
    """One instance dir whose single-mint probes follow base + slope*min(budget, book) exactly.

    Two properties of this fixture are load-bearing, each pinning one way the analysis could go
    wrong and still look right:

    * At the second rung the BOOK is smaller than the budget, so the pass walks the book, not the
      budget. A fit that regresses on budget rather than min(budget, book) gets a different slope
      here — where a fixture whose book always exceeds the budget could not tell them apart.
    * The first rung also carries a real multi-mint batch. Every mint in a PTB runs its own
      ambient pass, so an N-mint batch costs ~N times a single one; a fit that forgets to restrict
      to n==1 swallows that point and the slope collapses.
    * Each rung change plants a probe inside the request-to-landed window, priced at the OLD rung.
      Counting it drags the slope down and the ceiling up — the unsafe direction — so the analysis
      has to discard the window rather than attribute it to either side.

    A probe whose modelled cost exceeds the cap is emitted as an OOG rather than a successful
    mint, which is what the strategy itself does at the wall.
    """
    inst = root / "inst"
    (inst / "trace").mkdir(parents=True)
    keeper, trader = [], []
    ts = 1_000_000
    for i, ((elapsed_s, budget), book) in enumerate(zip(LADDER, books)):
        # The rung's set-tx is requested a tick before it lands, and a probe inside that window ran
        # under an indeterminate budget. One such probe is planted per rung, priced at the OLD rung
        # so that counting it would visibly drag the fit — the analysis must drop it.
        requested = ts + 50
        if i > 0:
            prev_budget, prev_book = LADDER[i - 1][1], books[i - 1]
            trader.append({"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "gas": BASE + slope * min(prev_budget, prev_book),
                           "compGas": BASE + slope * min(prev_budget, prev_book),
                           "book": book, "batch": 1, "ts": requested + 10})
        ts += 1_000
        keeper.append({"type": "liqBudget", "budget": budget, "elapsedMs": elapsed_s * 1000,
                       "requestedAtMs": requested, "ts": ts})
        single = BASE + slope * min(budget, book)
        if i == 0:
            # The fill phase's batched mints, at the one rung cheap enough for a batch to fit.
            ts += 100
            trader.append({"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 8, "gas": 8 * single, "compGas": 8 * single,
                           "book": book, "batch": 8, "ts": ts})
        for offset in NOISE:
            ts += 100
            comp = single + offset
            trader.append(
                {"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "book": book, "batch": 1, "ts": ts,
                 "family": "liq-budget", "profile": "healthy", "oog": True, "err": "InsufficientGas"}
                if comp > CAP
                else {"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "gas": comp, "compGas": comp,
                      "book": book, "batch": 1, "ts": ts}
            )
    _write_trace(inst / "trace" / "keeper.jsonl", keeper)
    _write_trace(inst / "trace" / "trader.jsonl", trader)
    return inst


def _run(books: list[int], slope: int) -> tuple[str, list[str]]:
    with tempfile.TemporaryDirectory() as tmp:
        inst = _synthesise(Path(tmp), books, slope)
        buf = io.StringIO()
        with redirect_stdout(buf):
            signals = analyze._analyze_one(inst)
        return buf.getvalue(), signals


def _report(books: list[int], slope: int) -> str:
    return _run(books, slope)[0]


def _int_after(report: str, pattern: str) -> int:
    m = re.search(pattern, report)
    assert m, f"pattern {pattern!r} not found in:\n{report}"
    return int(m.group(1).replace(",", ""))


class LiqBudgetAnalysisTests(unittest.TestCase):
    def test_computation_cap_is_the_value_the_expectations_below_were_computed_against(self) -> None:
        # Every crossing literal in this file was worked out against this number; if the protocol
        # constant moves, those literals are stale and must be recomputed, not silently re-derived.
        self.assertEqual(analyze.COMP_CAP, CAP)

    def test_fit_recovers_the_cost_model_and_reports_no_wall_when_none_is_reached(self) -> None:
        # 1,086,000/candidate is the pre-memo correction_value slope — the sweep's closest measured
        # analogue. Crossing: (5,000,000,000 - 400,000,000) / 1,086,000 = 4,600,000,000 / 1,086,000
        # = 4235.7 -> 4235, which sits ABOVE the 3,000 budget max. So the top rung costs
        # 400,000,000 + 1,086,000*3000 = 3,658,000,000 (73% of cap) and no wall is reached.
        # Books: rung 2 is book-limited (300 < 512), so candidates are 24 / 300 / 1500 / 3000.
        report = _report([100, 300, 2000, 3400], 1_086_000)

        self.assertEqual(_int_after(report, r"~([\d,]+) comp/candidate"), 1_086_000)
        self.assertEqual(_int_after(report, r"\+([\d,]+) base mint"), BASE)
        self.assertEqual(_int_after(report, r"stops fitting one tx at ~([\d,]+) candidates"), 4235)
        self.assertIn("no single-mint OOG", report)
        self.assertNotIn("EMPIRICAL wall", report)

    def test_steeper_cost_reports_the_empirical_wall(self) -> None:
        # The adverse branch also pays index + payout-tree removal per liquidated candidate, so the
        # slope is steeper. Crossing: 4,600,000,000 / 1,700,000 = 2705.9 -> 2705, INSIDE the allowed
        # budget range, so the 3,000 rung costs 400,000,000 + 5,100,000,000 = 5.5e9 and every probe
        # there OOGs. The fit then runs on the three rungs below it and must still recover the model.
        report = _report([100, 300, 2000, 4600], 1_700_000)

        self.assertEqual(_int_after(report, r"~([\d,]+) comp/candidate"), 1_700_000)
        self.assertEqual(_int_after(report, r"stops fitting one tx at ~([\d,]+) candidates"), 2705)
        self.assertRegex(report, r"EMPIRICAL wall: a single mint OOG'd at budget 3000 / book 4600")
        self.assertNotIn("no single-mint OOG", report)

    def test_an_undeclared_wall_fails_the_run(self) -> None:
        # These fixtures carry no `expect` record, i.e. the arm never declared it was probing for a
        # wall — so a single mint that cannot fit is an unexpected finding and must fail the run.
        # The OOG is traced as a mintBatch record rather than a `fail`, so the bug oracle cannot see
        # it; without an explicit signal the run would print the wall and still exit 0.
        report, signals = _run([100, 300, 2000, 4600], 1_700_000)

        self.assertIn("EMPIRICAL wall", report)
        self.assertTrue(
            any(s.startswith("liq-budget-wall-undeclared") for s in signals),
            f"expected an undeclared-wall signal, got {signals}",
        )

    def test_a_declared_wall_does_not_fail_the_run(self) -> None:
        # The adverse arm declares the computation cap, so reaching it is the point, not a surprise.
        with tempfile.TemporaryDirectory() as tmp:
            inst = _synthesise(Path(tmp), [100, 300, 2000, 4600], 1_700_000)
            trace = inst / "trace" / "trader.jsonl"
            trace.write_text(
                trace.read_text()
                + "\n"
                + json.dumps({"type": "expect", "strategy": "liq-budget-adverse", "terminal": ["InsufficientGas"], "ts": 999_999, "schema": 1})
            )
            buf = io.StringIO()
            with redirect_stdout(buf):
                signals = analyze._analyze_one(inst)

        # The whole run must come back clean, not merely free of the undeclared-wall signal: the
        # trader submits via a path that writes no failed-tx artifact and traces its OOG as a
        # mintBatch rather than a `fail`, so neither source the declared-wall check normally reads
        # can see it — an arm that reached exactly the wall it declared would be failed VACUOUS.
        self.assertIn("EMPIRICAL wall", buf.getvalue())
        self.assertEqual(signals, [], f"a declared, reached wall must not fail the run: {signals}")

    def test_wall_reports_the_smallest_candidate_count_not_the_last_or_largest(self) -> None:
        # Two rungs OOG a single mint, at different books. The wall worth reporting is the CHEAPEST
        # state that could not fit — a ceiling set from the largest would be set above a budget
        # already known to break. Rungs 1500 (book 1600 -> 1500 candidates) and 3000 (book 3400 ->
        # 3000 candidates) both OOG at slope 3,000,000: 400,000,000 + 3,000,000*1500 = 4.9e9 fits,
        # so make it 3,200,000 -> 5.2e9 at 1500 candidates and 9.6e9 at 3000. Smallest = 1500.
        report = _report([100, 300, 1600, 3400], 3_200_000)

        self.assertRegex(report, r"EMPIRICAL wall: a single mint OOG'd at budget 1500 / book 1600")
        self.assertNotIn("budget 3000 / book 3400", report)

    def test_a_multi_leg_batch_oog_is_not_reported_as_the_wall(self) -> None:
        # An N-mint PTB pays N ambient passes, so it OOGs long before a single mint does. Treating
        # that as the wall would report a ceiling several times lower than the truth and, at the
        # extreme, condemn a budget that ordinary trading handles comfortably.
        with tempfile.TemporaryDirectory() as tmp:
            inst = Path(tmp) / "inst"
            (inst / "trace").mkdir(parents=True)
            _write_trace(inst / "trace" / "keeper.jsonl", [{"type": "liqBudget", "budget": 512, "requestedAtMs": 900, "ts": 1000}])
            _write_trace(inst / "trace" / "trader.jsonl", [
                # A 40-leg batch cannot fit; single mints at the same budget and book still do.
                {"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 40, "book": 900, "batch": 40, "ts": 1100,
                 "family": "liq-budget", "profile": "healthy", "oog": True, "err": "InsufficientGas"},
                {"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "gas": 900_000_000, "compGas": 900_000_000,
                 "book": 900, "batch": 1, "ts": 1200},
                {"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "gas": 902_000_000, "compGas": 902_000_000,
                 "book": 1000, "batch": 1, "ts": 1300},
            ])
            buf = io.StringIO()
            with redirect_stdout(buf):
                analyze._analyze_one(inst)
            report = buf.getvalue()

        self.assertIn("no single-mint OOG", report)
        self.assertNotIn("EMPIRICAL wall", report)

    def test_book_is_the_active_index_not_mints_issued(self) -> None:
        # The adverse arm's ambient pass knocks orders out as it goes, so mints issued runs ahead of
        # the live index. Reading issued mints as the book overstates the candidates scanned, which
        # understates the per-candidate slope and overstates the ceiling — the unsafe direction.
        # Here the true book is a third of mints issued; the fit must recover the true slope.
        with tempfile.TemporaryDirectory() as tmp:
            inst = Path(tmp) / "inst"
            (inst / "trace").mkdir(parents=True)
            _write_trace(inst / "trace" / "keeper.jsonl", [{"type": "liqBudget", "budget": 3000, "requestedAtMs": 900, "ts": 1000}])
            rows = []
            for i, book in enumerate([200, 400, 600, 800]):
                rows.append({"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "book": book, "gas": BASE + 1_000_000 * book, "compGas": BASE + 1_000_000 * book,
                             "batch": 1, "ts": 1100 + i * 100})
            _write_trace(inst / "trace" / "trader.jsonl", rows)
            buf = io.StringIO()
            with redirect_stdout(buf):
                analyze._analyze_one(inst)
            report = buf.getvalue()

        # Against `book` the slope is exactly 1,000,000. Against `minted` (3x the x-values) it
        # would read 333,333 and the ceiling would be inflated threefold.
        self.assertEqual(_int_after(report, r"~([\d,]+) comp/candidate"), 1_000_000)
        self.assertEqual(_int_after(report, r"stops fitting one tx at ~([\d,]+) candidates"), 4600)

    def _one_rung_trace(self, tmp: Path, rows: list[dict], budget: int = 3000) -> tuple[str, list[str]]:
        inst = tmp / "inst"
        (inst / "trace").mkdir(parents=True)
        _write_trace(inst / "trace" / "keeper.jsonl", [{"type": "liqBudget", "budget": budget, "requestedAtMs": 900, "ts": 1000}])
        _write_trace(inst / "trace" / "trader.jsonl", rows)
        buf = io.StringIO()
        with redirect_stdout(buf):
            signals = analyze._analyze_one(inst)
        return buf.getvalue(), signals

    def test_wall_is_keyed_on_candidates_not_on_the_budget_alone(self) -> None:
        # The pass walks min(budget, book), so the cheapest state that failed to fit is the one with
        # the fewest CANDIDATES — which need not be the one with the lowest budget. Here budget 3000
        # at book 500 scans 500 candidates while budget 1500 at book 2000 scans 1500, so the wall is
        # the 3000/500 row. Keying on budget would report 1500 and set a ceiling three times too high.
        with tempfile.TemporaryDirectory() as tmp:
            inst = Path(tmp) / "inst"
            (inst / "trace").mkdir(parents=True)
            _write_trace(inst / "trace" / "keeper.jsonl", [
                {"type": "liqBudget", "budget": 1500, "requestedAtMs": 900, "ts": 1000},
                {"type": "liqBudget", "budget": 3000, "requestedAtMs": 2900, "ts": 3000},
            ])
            _write_trace(inst / "trace" / "trader.jsonl", [
                {"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "book": 2000, "batch": 1, "ts": 2000,
                 "family": "liq-budget", "profile": "healthy", "oog": True, "err": "InsufficientGas"},
                {"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "book": 500, "batch": 1, "ts": 4000,
                 "family": "liq-budget", "profile": "healthy", "oog": True, "err": "InsufficientGas"},
            ])
            buf = io.StringIO()
            with redirect_stdout(buf):
                analyze._analyze_one(inst)

        self.assertRegex(buf.getvalue(), r"EMPIRICAL wall: a single mint OOG'd at budget 3000 / book 500 \(~500 candidates\)")

    def test_probes_before_the_first_rung_are_ignored(self) -> None:
        # Before any rung lands the in-force budget is the contract default, which the harness does
        # not assume. A probe from that window has no known budget and must not enter the fit.
        with tempfile.TemporaryDirectory() as tmp:
            report, _ = self._one_rung_trace(Path(tmp), [
                # ts 500 is before the rung's ts 1000 — unknown budget, must be dropped.
                {"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "gas": 99, "compGas": 99, "book": 40, "batch": 1, "ts": 500},
                {"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "gas": 900_000_000, "compGas": 900_000_000,
                 "book": 500, "batch": 1, "ts": 1100},
                {"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "gas": 2_400_000_000, "compGas": 2_400_000_000,
                 "book": 2000, "batch": 1, "ts": 1200},
            ])

        self.assertNotIn("book   40", report)
        # Two kept samples: (500, 9e8) and (2000, 2.4e9) -> slope exactly 1,000,000. Including the
        # pre-rung sample at (40, 99) would drag it to ~1,180,000 and the ceiling with it.
        self.assertEqual(_int_after(report, r"~([\d,]+) comp/candidate"), 1_000_000)

    def test_a_run_that_collected_no_samples_says_so_and_fails(self) -> None:
        # The failure this guards is a run that measured nothing yet printed an affirmative
        # "affordable" line and exited 0 — an affirmative safety claim from zero evidence.
        with tempfile.TemporaryDirectory() as tmp:
            report, signals = self._one_rung_trace(Path(tmp), [
                {"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 40, "gas": 3_000_000_000, "compGas": 3_000_000_000,
                 "book": 900, "batch": 40, "ts": 1100},
            ])

        self.assertIn("measured nothing", report)
        self.assertNotIn("affordable", report)
        self.assertIn("liq-budget-no-samples", signals)

    def test_a_fit_over_a_narrow_cluster_is_refused_not_extrapolated(self) -> None:
        # Samples spanning 23-29 candidates cannot support a ceiling near 4,000: the recovered slope
        # is dominated by noise and the crossing came out 2.4x off truth in simulation, printed to
        # the same decimal places as a real measurement. Refuse rather than report.
        with tempfile.TemporaryDirectory() as tmp:
            rows = [
                {"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "gas": 400_000_000 + 1_086_000 * bk,
                 "compGas": 400_000_000 + 1_086_000 * bk, "book": bk, "batch": 1, "ts": 1100 + i}
                for i, bk in enumerate([23, 25, 27, 29])
            ]
            report, signals = self._one_rung_trace(Path(tmp), rows)

        self.assertIn("fit SKIPPED", report)
        self.assertNotIn("stops fitting one tx", report)
        self.assertIn("liq-budget-fit-unusable", signals)

    def test_an_unphysical_negative_base_mint_is_refused_even_on_a_wide_span(self) -> None:
        # A wide span is necessary but not sufficient. If cost grows super-linearly in the book
        # (page splits, tree depth), a straight line through the samples cuts the axis below zero:
        # here (100, 1.0e9) and (2000, 4.8e9) give slope 2,000,000 and base 1.0e9 - 2.0e8 = ... in
        # fact 8.0e8; use a steeper pair so the intercept is genuinely negative —
        # (100, 1.0e8) and (2000, 4.0e9): slope = 3.9e9/1900 = 2,052,631, base = 1e8 - 2.053e8 < 0.
        # A mint cannot cost less than nothing, so the line is not describing the candidate count and
        # its crossing must not be reported however wide the span (20x here).
        with tempfile.TemporaryDirectory() as tmp:
            report, signals = self._one_rung_trace(Path(tmp), [
                {"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "gas": 100_000_000, "compGas": 100_000_000,
                 "book": 100, "batch": 1, "ts": 1100},
                {"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "gas": 4_000_000_000, "compGas": 4_000_000_000,
                 "book": 2000, "batch": 1, "ts": 1200},
            ])

        self.assertNotIn("fit SKIPPED", report)  # the span guard is NOT what catches this
        self.assertIn("fit REJECTED", report)
        self.assertNotIn("stops fitting one tx", report)
        self.assertIn("liq-budget-fit-unusable", signals)

    def test_section_is_skipped_when_no_budget_ladder_ran(self) -> None:
        # With no rung applied the in-force budget is the contract default, which the harness must
        # not assume — an ordinary run has nothing to sweep and prints no liq-budget section.
        with tempfile.TemporaryDirectory() as tmp:
            inst = Path(tmp) / "inst"
            (inst / "trace").mkdir(parents=True)
            _write_trace(inst / "trace" / "trader.jsonl", [{"type": "mintBatch", "strategy": "liq-budget-healthy", "n": 1, "gas": 5, "compGas": 5, "ts": 1}])
            buf = io.StringIO()
            with redirect_stdout(buf):
                analyze._analyze_one(inst)
            self.assertNotIn("liq-budget —", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
