# Reimagined Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the account-centric Textual dashboard with a full-screen, live protocol-observability monitor (v1 zones: banner/verdict, attention strip, vitals, cadence hero, oracle, keepers/ops).

**Architecture:** A pure view-model layer assembles a `DashboardView` from three existing typed inputs — `PredictStatusReport` (observability), `OnchainSnapshot` (onchain reader), `ChainHealth` — with no I/O, so it is fully offline-testable. A thin Textual `App` renders one native widget per zone. A small loader gathers the three inputs off the UI thread. `dashboard.py` is split into a `dashboard/` package by responsibility.

**Tech Stack:** Python ≥3.9, Textual (optional `[tui]` extra), unittest (offline, fake transports), the existing `observability` / `onchain` / `indexer` clients.

## Global Constraints

- Python ≥3.9; `from __future__ import annotations` in every module (matches repo).
- Textual is an OPTIONAL dependency (`[tui]` extra) — guard the import; pure layers (`fmt`, `model`) must import with no Textual installed.
- Tests offline by default (D006): fake clients / typed fixtures; never require testnet RPC, keys, or funded wallets.
- Read-only: the dashboard never builds or submits a transaction.
- Raw integer units internally: DUSDC 6dp, SUI 9dp, probabilities/prices 1e9 (`constants.DUSDC_DECIMALS`, `SUI_DECIMALS`, `FLOAT_SCALING`).
- Run the suite from the package dir: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest discover -s tests`. Keep `python3 -m pyflakes predict_sdk/ tests/` clean.
- Data plane per `docs/data-architecture.md`: live state from the snapshot/report, discovery/history from the indexer; never call indexer endpoints that proxy chain.

## Sequencing & dependencies

Tasks 1–7 are **buildable now** — they consume the existing `PredictStatusReport`, `OnchainSnapshot`, and `ChainHealth` interfaces and are tested against typed fixtures, so they are insulated from the in-flight data consolidation. Task 8 (the live loader) wires `ObservabilityClient.status()` + `OnchainSnapshotReader.snapshot()` + `SuiReadClient.latest_checkpoint()`; its interface is stable but its field accuracy improves as the data deps in the spec land (per-market `mint_paused`/settlement into the snapshot, etc.). Where a field is unavailable, the view-model already degrades to `None`/"—". Deferred (not in this plan): activity feed, trends band, solvency/risk/PLP panels, account view.

## File structure

- Create `predict_sdk/dashboard/__init__.py` — `run_dashboard(...)` entry; re-exports.
- Create `predict_sdk/dashboard/fmt.py` — pure formatting helpers (moved from today's `dashboard.py` + a couple from `render.py`'s vocabulary).
- Create `predict_sdk/dashboard/model.py` — view-model dataclasses + pure builders (`derive_vitals`, `derive_attention`, `derive_keeper_health`, `build_dashboard_view`). No Textual, no I/O.
- Create `predict_sdk/dashboard/load.py` — `load_dashboard_view(...)`: gather the three inputs, call `build_dashboard_view`. The only data-plane-coupled file.
- Create `predict_sdk/dashboard/app.py` — Textual `App` + zone widgets (guarded import).
- Delete `predict_sdk/dashboard.py` (replaced by the package).
- Create `tests/test_dashboard_model.py` — pure builder tests (fixtures).
- Create `tests/test_dashboard_app.py` — Textual `Pilot` test with a fixed `DashboardView`.
- Delete `tests/test_dashboard.py` (its account-centric subject is gone; coverage moves to the two new files).
- Modify `predict_sdk/cli.py` — `_dashboard` keeps calling `run_dashboard(...)` (import path unchanged: `from .dashboard import run_dashboard`).

---

### Task 1: `fmt` helpers

**Files:**
- Create: `predict_sdk/dashboard/__init__.py` (empty for now)
- Create: `predict_sdk/dashboard/fmt.py`
- Test: `tests/test_dashboard_model.py` (start the file here)

**Interfaces:**
- Produces: `fmt_money(raw:int|None)->str`, `fmt_sui(raw:int|None)->str`, `fmt_prob(raw_1e9:int|None)->str`, `fmt_duration(ms:int|None)->str`, `fmt_age(ms:int|None,now_ms:int)->str`, `short_id(v:str)->str`.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_dashboard_model.py
import unittest
from predict_sdk.dashboard import fmt


class FmtTests(unittest.TestCase):
    def test_money_truncates_to_two_dp(self) -> None:
        self.assertEqual(fmt.fmt_money(19_990_000_000), "19,990.00")
        self.assertEqual(fmt.fmt_money(None), "—")

    def test_prob_percent(self) -> None:
        self.assertEqual(fmt.fmt_prob(985_009_513), "98.5%")
        self.assertEqual(fmt.fmt_prob(None), "—")

    def test_duration_and_age(self) -> None:
        self.assertEqual(fmt.fmt_duration(41_000), "41s")
        self.assertEqual(fmt.fmt_duration(192_000), "3m 12s")
        self.assertEqual(fmt.fmt_age(8_000, 1_000_000), "8s ago")

    def test_short_id(self) -> None:
        self.assertEqual(fmt.short_id("0x" + "ab" * 32), "0xababab…ababab"[:15] + "…" + ("ab" * 32)[-5:]
                         if False else fmt.short_id("0x" + "ab" * 32))  # shape only
        self.assertTrue(fmt.short_id("0x" + "ab" * 32).startswith("0x"))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_model -v`
Expected: FAIL with `ModuleNotFoundError: predict_sdk.dashboard` (no package yet).

- [ ] **Step 3: Write minimal implementation**

```python
# predict_sdk/dashboard/__init__.py
# (empty; run_dashboard added in Task 8)
```

```python
# predict_sdk/dashboard/fmt.py
from __future__ import annotations

from .._http import post_json  # noqa: F401  (placeholder import removed in step 4)
```

(Real `fmt.py` — replace the file with this; lift the truncating formatters from today's `dashboard.py`:)

```python
# predict_sdk/dashboard/fmt.py
from __future__ import annotations

from ..constants import DUSDC_DECIMALS, FLOAT_SCALING, SUI_DECIMALS


def _fixed(raw: int | None, decimals_in: int, decimals_out: int = 2) -> str:
    if raw is None:
        return "—"
    negative = raw < 0
    raw = -raw if negative else raw
    whole, frac = divmod(raw, 10 ** decimals_in)
    frac_str = f"{frac:0{decimals_in}d}"[:decimals_out]
    out = f"{whole:,}.{frac_str}" if decimals_out else f"{whole:,}"
    return f"-{out}" if negative else out


def fmt_money(raw: int | None) -> str:
    return _fixed(raw, DUSDC_DECIMALS, 2)


def fmt_sui(raw: int | None) -> str:
    return _fixed(raw, SUI_DECIMALS, 4)


def fmt_prob(raw_1e9: int | None) -> str:
    return "—" if raw_1e9 is None else f"{raw_1e9 / FLOAT_SCALING * 100:.1f}%"


def fmt_duration(ms: int | None) -> str:
    if ms is None:
        return "—"
    if ms < 0:
        return "expired"
    total = ms // 1000
    if total < 60:
        return f"{total}s"
    if total < 3600:
        m, s = divmod(total, 60)
        return f"{m}m {s:02d}s"
    if total < 86400:
        h, rem = divmod(total, 3600)
        return f"{h}h {rem // 60:02d}m"
    d, rem = divmod(total, 86400)
    return f"{d}d {rem // 3600:02d}h"


def fmt_age(ms: int | None, now_ms: int) -> str:
    if ms is None:
        return "—"
    delta = now_ms - ms
    return "just now" if delta < 1000 else f"{fmt_duration(delta)} ago"


def short_id(value: str) -> str:
    if not isinstance(value, str) or len(value) <= 15:
        return value
    return f"{value[:8]}…{value[-5:]}"
```

Delete the placeholder first version; keep only the real `fmt.py` above.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_model -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/predict/python_sdk/predict_sdk/dashboard/ packages/predict/python_sdk/tests/test_dashboard_model.py
git commit -m "Predict SDK dashboard: fmt helpers + package scaffold"
```

---

### Task 2: View-model dataclasses

**Files:**
- Create: `predict_sdk/dashboard/model.py`
- Test: `tests/test_dashboard_model.py`

**Interfaces:**
- Consumes: `observability.PredictStatusReport`.
- Produces: dataclasses `Vitals`, `AttentionItem(severity:str, text:str)`, `KeeperHealth`, `DashboardView(report, vitals, attention, keepers, chain_checkpoint)`.

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_dashboard_model.py
from predict_sdk.dashboard.model import AttentionItem, DashboardView, KeeperHealth, Vitals


class ModelShapeTests(unittest.TestCase):
    def test_dataclasses_construct(self) -> None:
        v = Vitals(is_live=True, is_mintable=True, oracle_fresh=True,
                   idle_balance=1, plp_supply=2, protocol_reserve=0, active_markets=3)
        a = AttentionItem(severity="warn", text="x")
        k = KeeperHealth(settlement_awaiting=0, oldest_awaiting_ms=None, unfunded_market_ids=(),
                         oracle_feeder_age_ms=8000, chain_checkpoint=12345)
        self.assertEqual(a.severity, "warn")
        self.assertEqual(k.settlement_awaiting, 0)
        self.assertTrue(v.is_live)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_model -v`
Expected: FAIL with `ModuleNotFoundError: predict_sdk.dashboard.model`.

- [ ] **Step 3: Write minimal implementation**

```python
# predict_sdk/dashboard/model.py
from __future__ import annotations

from dataclasses import dataclass, field

from ..observability import PredictStatusReport


@dataclass(frozen=True)
class Vitals:
    is_live: bool
    is_mintable: bool
    oracle_fresh: bool
    idle_balance: int | None
    plp_supply: int | None
    protocol_reserve: int | None
    active_markets: int


@dataclass(frozen=True)
class AttentionItem:
    severity: str   # "block" | "warn"
    text: str


@dataclass(frozen=True)
class KeeperHealth:
    settlement_awaiting: int
    oldest_awaiting_ms: int | None
    unfunded_market_ids: tuple[str, ...]
    oracle_feeder_age_ms: int | None
    chain_checkpoint: int | None


@dataclass(frozen=True)
class DashboardView:
    report: PredictStatusReport
    vitals: Vitals
    attention: list[AttentionItem] = field(default_factory=list)
    keepers: KeeperHealth | None = None
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_model -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/predict/python_sdk/predict_sdk/dashboard/model.py packages/predict/python_sdk/tests/test_dashboard_model.py
git commit -m "Predict SDK dashboard: view-model dataclasses"
```

---

### Task 3: `derive_vitals`

**Files:**
- Modify: `predict_sdk/dashboard/model.py`
- Test: `tests/test_dashboard_model.py`

**Interfaces:**
- Consumes: `PredictStatusReport`, `onchain.OnchainSnapshot`.
- Produces: `derive_vitals(report, snapshot) -> Vitals`.

- [ ] **Step 1: Write the failing test** — use the report fixture helper added here (reused by later tasks).

```python
# add to tests/test_dashboard_model.py
from predict_sdk.observability import (
    CadenceTimeline, MarketStatus, OracleFeedStatus, OracleStatus, PoolStatus,
    PredictStatusReport, TimelineSlot,
)
from predict_sdk.onchain import MarketSnapshot, OnchainSnapshot, OracleReadSnapshot, PoolSnapshot
from predict_sdk.dashboard.model import derive_vitals

NOW = 1_800_000_000_000
LIVE = "0x" + "1" * 64


def _report(*, is_live=True, is_mintable=True, oracle_fresh=True, markets=None, cadences=None):
    feeds = (OracleFeedStatus("pyth", NOW - 8000, 30000, oracle_fresh,
                              None if oracle_fresh else "pyth stale"),)
    return PredictStatusReport(
        network="testnet", chain_id="4c78", asset="BTC_USD",
        protocol_config_id="0xcfg", pool_vault_id="0xpool",
        is_live=is_live, is_mintable=is_mintable, blockers=[],
        oracle=OracleStatus("BTC_USD", 1, feeds),
        pool=PoolStatus("0xpool", 19_990_000_000, 0, 20_000_000_000, (LIVE,)),
        markets=markets if markets is not None else [],
        cadences=cadences if cadences is not None else [],
    )


def _snapshot(markets=None):
    return OnchainSnapshot(
        pool=PoolSnapshot("0xpool", 0, 19_990_000_000, 50_000_000, 0, 20_000_000_000,
                          0, 0, (), 0, 0, 0),
        markets=markets or {},
        oracles={},
    )


class VitalsTests(unittest.TestCase):
    def test_vitals_pull_from_report_and_snapshot(self) -> None:
        v = derive_vitals(_report(), _snapshot())
        self.assertTrue(v.is_live and v.is_mintable and v.oracle_fresh)
        self.assertEqual(v.idle_balance, 19_990_000_000)
        self.assertEqual(v.plp_supply, 20_000_000_000)
        self.assertEqual(v.protocol_reserve, 50_000_000)   # from snapshot pool
        self.assertEqual(v.active_markets, 1)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_model.VitalsTests -v`
Expected: FAIL with `ImportError: cannot import name 'derive_vitals'`.

- [ ] **Step 3: Write minimal implementation** (append to `model.py`; add `from .onchain ...` import at top)

```python
# top of model.py
from ..onchain import OnchainSnapshot

# append:
def derive_vitals(report: PredictStatusReport, snapshot: OnchainSnapshot) -> Vitals:
    pool = snapshot.pool
    return Vitals(
        is_live=report.is_live,
        is_mintable=report.is_mintable,
        oracle_fresh=report.oracle.fresh,
        idle_balance=report.pool.idle_balance,
        plp_supply=report.pool.plp_total_supply,
        # reserve detail is richer on the chain snapshot than the report
        protocol_reserve=pool.protocol_reserve_balance if pool else report.pool.protocol_reserve_balance,
        active_markets=report.pool.active_market_count,
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_model.VitalsTests -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Predict SDK dashboard: derive_vitals"
```

---

### Task 4: `derive_attention` (the rules)

**Files:**
- Modify: `predict_sdk/dashboard/model.py`
- Test: `tests/test_dashboard_model.py`

**Interfaces:**
- Consumes: `PredictStatusReport`, `OnchainSnapshot`.
- Produces: `derive_attention(report, snapshot, now_ms) -> list[AttentionItem]` ordered block→warn; empty when all-nominal.

Rules (from spec): blocked/paused (report.blockers minus oracle) → block; oracle stale (`not report.oracle.fresh`) → block; under-backed (`payout_liability > cash_balance` per snapshot market) → warn; settlement backlog (`awaiting_settle` slots in report.cadences) → warn with count; unfunded live (`cash_balance == 0` for a snapshot market whose report slot is `live`/`missing_live`) → warn; snapshot errors → warn.

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_dashboard_model.py
from predict_sdk.dashboard.model import derive_attention


def _slot(expiry, pos, state, market=None):
    return TimelineSlot(expiry, pos, state, market)


def _cadence(name, slots):
    return CadenceTimeline(1, name, 300_000, 3, 1_000_000_000, tuple(slots), backlog_count=0)


def _msnap(market_id, *, cash, liability):
    return MarketSnapshot(
        market_id=market_id, propbook_underlying_id=1, expiry_ms=NOW + 60_000,
        cash_balance=cash, rebate_reserve=0, fee_incentive_balance=0,
        trading_loss_rebate_rate=0, liquidation_ltv=0, max_admission_leverage=0,
        backing_buffer_lambda=0, expiry_fee_window_ms=0, expiry_fee_max_multiplier=0,
        tick_size=1_000_000_000, admission_tick_size=10_000_000_000,
        reference_tick=64_250, reference_tick_source_timestamp_ms=NOW - 8000,
        payout_liability=liability,
    )


class AttentionTests(unittest.TestCase):
    def test_all_nominal_is_empty(self) -> None:
        self.assertEqual(derive_attention(_report(), _snapshot(), NOW), [])

    def test_paused_is_a_block(self) -> None:
        r = _report(is_live=False)
        r.blockers.append("protocol trading is paused")
        items = derive_attention(r, _snapshot(), NOW)
        self.assertEqual(items[0].severity, "block")
        self.assertIn("paused", items[0].text)

    def test_unfunded_and_underbacked_are_warns(self) -> None:
        live_slot = _slot(NOW + 60_000, 0, "live", _market_status(LIVE))
        report = _report(cadences=[_cadence("1m", [live_slot])])
        snap = _snapshot({LIVE: _msnap(LIVE, cash=0, liability=10)})
        texts = " ".join(i.text for i in derive_attention(report, snap, NOW))
        self.assertIn("unfunded", texts)
        self.assertIn("under-backed", texts)

    def test_settlement_backlog_counts_awaiting(self) -> None:
        slots = [_slot(NOW - 60_000, -1, "awaiting_settle", _market_status("0xold"))]
        report = _report(cadences=[_cadence("1m", slots)])
        items = derive_attention(report, _snapshot(), NOW)
        self.assertTrue(any("settlement backlog" in i.text for i in items))
```

(Add a small `_market_status(mid)` helper near `_report` returning a `MarketStatus` with `expiry_ms=NOW`, `settled=False`, `blockers=[]`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_model.AttentionTests -v`
Expected: FAIL with `ImportError: cannot import name 'derive_attention'`.

- [ ] **Step 3: Write minimal implementation** (append to `model.py`)

```python
def derive_attention(report, snapshot, now_ms) -> list[AttentionItem]:
    items: list[AttentionItem] = []
    oracle_blockers = set(report.oracle.blockers)
    for b in dict.fromkeys(report.blockers):
        if b not in oracle_blockers:
            items.append(AttentionItem("block", b))
    if not report.oracle.fresh:
        items.append(AttentionItem("block", "oracle stale"))

    # snapshot-derived per-market signals
    live_ids = {
        slot.market.market_id
        for cad in report.cadences for slot in cad.slots
        if slot.market is not None and slot.state in ("live", "missing_live")
    }
    unfunded = [
        mid for mid, m in snapshot.markets.items()
        if mid in live_ids and m.cash_balance == 0
    ]
    if unfunded:
        items.append(AttentionItem("warn", f"{len(unfunded)} unfunded live market(s)"))
    underbacked = [
        mid for mid, m in snapshot.markets.items()
        if m.payout_liability > m.cash_balance
    ]
    if underbacked:
        items.append(AttentionItem("warn", f"{len(underbacked)} under-backed market(s)"))

    awaiting = [
        slot for cad in report.cadences for slot in cad.slots
        if slot.state == "awaiting_settle"
    ]
    if awaiting:
        oldest = min(slot.expiry_ms for slot in awaiting)
        items.append(AttentionItem("warn", f"settlement backlog {len(awaiting)} · oldest {fmt_age(oldest, now_ms)}"))

    if snapshot.errors:
        items.append(AttentionItem("warn", "on-chain snapshot unavailable"))

    items.sort(key=lambda i: 0 if i.severity == "block" else 1)
    return items
```

Add `from .fmt import fmt_age` at the top of `model.py`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_model.AttentionTests -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Predict SDK dashboard: attention rules"
```

---

### Task 5: `derive_keeper_health`

**Files:**
- Modify: `predict_sdk/dashboard/model.py`
- Test: `tests/test_dashboard_model.py`

**Interfaces:**
- Consumes: `PredictStatusReport`, `OnchainSnapshot`, `onchain.ChainHealth`.
- Produces: `derive_keeper_health(report, snapshot, chain) -> KeeperHealth`.

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_dashboard_model.py
from predict_sdk.onchain import ChainHealth, MarketOracleSnapshot
from predict_sdk.dashboard.model import derive_keeper_health


class KeeperTests(unittest.TestCase):
    def test_backlog_unfunded_feeder_checkpoint(self) -> None:
        awaiting = _slot(NOW - 480_000, -1, "awaiting_settle", _market_status("0xold"))
        live = _slot(NOW + 60_000, 0, "live", _market_status(LIVE))
        report = _report(cadences=[_cadence("1m", [awaiting, live])])
        oracles = {LIVE: MarketOracleSnapshot(
            pyth=OracleReadSnapshot(True, NOW - 9000, NOW - 8000, 1),
            bs_spot=OracleReadSnapshot(False), bs_forward=OracleReadSnapshot(False),
            bs_svi=OracleReadSnapshot(False))}
        snap = OnchainSnapshot(pool=_snapshot().pool,
                               markets={LIVE: _msnap(LIVE, cash=0, liability=0)},
                               oracles=oracles)
        k = derive_keeper_health(report, snap, ChainHealth(True, 12345))
        self.assertEqual(k.settlement_awaiting, 1)
        self.assertEqual(k.oldest_awaiting_ms, NOW - 480_000)
        self.assertEqual(k.unfunded_market_ids, (LIVE,))
        self.assertEqual(k.oracle_feeder_age_ms, None) or self.assertIsInstance(k.oracle_feeder_age_ms, int)
        self.assertEqual(k.chain_checkpoint, 12345)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_model.KeeperTests -v`
Expected: FAIL with `ImportError: cannot import name 'derive_keeper_health'`.

- [ ] **Step 3: Write minimal implementation** (append to `model.py`; add `ChainHealth` import)

```python
from ..onchain import ChainHealth, OnchainSnapshot  # update import line

def derive_keeper_health(report, snapshot, chain) -> KeeperHealth:
    awaiting = [
        slot for cad in report.cadences for slot in cad.slots
        if slot.state == "awaiting_settle"
    ]
    oldest = min((slot.expiry_ms for slot in awaiting), default=None)

    live_ids = {
        slot.market.market_id
        for cad in report.cadences for slot in cad.slots
        if slot.market is not None and slot.state in ("live", "missing_live")
    }
    unfunded = tuple(
        mid for mid, m in snapshot.markets.items()
        if mid in live_ids and m.cash_balance == 0
    )

    # feeder heartbeat = newest oracle update_timestamp across the snapshot
    update_ts = [
        read.update_timestamp_ms
        for o in snapshot.oracles.values()
        for read in (o.pyth, o.bs_spot, o.bs_forward, o.bs_svi)
        if read.present and read.update_timestamp_ms is not None
    ]
    feeder_latest = max(update_ts) if update_ts else None

    return KeeperHealth(
        settlement_awaiting=len(awaiting),
        oldest_awaiting_ms=oldest,
        unfunded_market_ids=unfunded,
        oracle_feeder_age_ms=feeder_latest,
        chain_checkpoint=chain.latest_checkpoint if chain and chain.reachable else None,
    )
```

(Note: `oracle_feeder_age_ms` stores the latest update *timestamp*; the widget converts to an age with `fmt_age` at render. Rename the field to `oracle_feeder_latest_ms` for honesty and update Task 2's dataclass + this test accordingly.)

- [ ] **Step 4: Run test to verify it passes** (after the rename, assert `oracle_feeder_latest_ms == NOW - 8000`)

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_model.KeeperTests -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Predict SDK dashboard: keeper/ops health"
```

---

### Task 6: `build_dashboard_view`

**Files:**
- Modify: `predict_sdk/dashboard/model.py`
- Test: `tests/test_dashboard_model.py`

**Interfaces:**
- Consumes: `PredictStatusReport`, `OnchainSnapshot`, `ChainHealth`, `now_ms`.
- Produces: `build_dashboard_view(report, snapshot, chain, now_ms) -> DashboardView`.

- [ ] **Step 1: Write the failing test**

```python
# add to tests/test_dashboard_model.py
from predict_sdk.dashboard.model import build_dashboard_view


class BuildViewTests(unittest.TestCase):
    def test_assembles_all_zones(self) -> None:
        view = build_dashboard_view(_report(), _snapshot(), ChainHealth(True, 42), NOW)
        self.assertIs(view.report, view.report)
        self.assertTrue(view.vitals.is_live)
        self.assertEqual(view.attention, [])
        self.assertEqual(view.keepers.chain_checkpoint, 42)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_model.BuildViewTests -v`
Expected: FAIL with `ImportError: cannot import name 'build_dashboard_view'`.

- [ ] **Step 3: Write minimal implementation** (append to `model.py`)

```python
def build_dashboard_view(report, snapshot, chain, now_ms) -> DashboardView:
    return DashboardView(
        report=report,
        vitals=derive_vitals(report, snapshot),
        attention=derive_attention(report, snapshot, now_ms),
        keepers=derive_keeper_health(report, snapshot, chain),
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_model -v`
Expected: PASS (whole file).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Predict SDK dashboard: build_dashboard_view"
```

---

### Task 7: Textual app + zone widgets

**Files:**
- Create: `predict_sdk/dashboard/app.py`
- Test: `tests/test_dashboard_app.py`

**Interfaces:**
- Consumes: `DashboardView` (Task 6), `fmt` (Task 1), `observability` cadence/oracle/slot types.
- Produces: `PredictDashboardApp(loader: Callable[[], DashboardView], refresh_s: int)`; helper render functions `attention_markup(view)`, `vitals_markup(view)`, `keepers_markup(view)`, `cadence_lines(cadence, now_ms)`, `oracle_markup(report)` (module-level, pure str → unit-testable without a terminal).

**Design:** the guarded Textual import (mirror today's `dashboard.py`). The app composes: `Static#banner`, `Static#attention`, `Static#vitals`, a `VerticalScroll#cadences` filled with one `Static` per cadence (native widget rendering the box rows via `cadence_lines`), and a bottom `Horizontal` with `Static#oracle` and `Static#keepers`. Each `Static` is updated from `DashboardView` on refresh. The pure `*_markup` / `cadence_lines` functions hold all formatting (Rich markup strings) so they are tested directly; the widgets just call `.update(...)`.

- [ ] **Step 1: Write the failing test** (pure markup functions — no terminal needed)

```python
# tests/test_dashboard_app.py
import unittest

from predict_sdk.dashboard import app
from tests.test_dashboard_model import _report, _snapshot, NOW   # reuse fixtures
from predict_sdk.dashboard.model import build_dashboard_view
from predict_sdk.onchain import ChainHealth


class MarkupTests(unittest.TestCase):
    def _view(self):
        return build_dashboard_view(_report(), _snapshot(), ChainHealth(True, 42), NOW)

    def test_vitals_markup_has_idle_and_supply(self) -> None:
        out = app.vitals_markup(self._view())
        self.assertIn("19,990.00", out)
        self.assertIn("20,000.00", out)

    def test_attention_collapses_to_nominal(self) -> None:
        self.assertIn("nominal", app.attention_markup(self._view()).lower())

    def test_keepers_markup_shows_checkpoint(self) -> None:
        self.assertIn("42", app.keepers_markup(self._view()))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_app -v`
Expected: FAIL with `ImportError` / `AttributeError: module 'app' has no attribute 'vitals_markup'`.

- [ ] **Step 3: Write minimal implementation**

```python
# predict_sdk/dashboard/app.py
from __future__ import annotations

import asyncio
import time
from typing import Callable

from .fmt import fmt_age, fmt_duration, fmt_money, fmt_prob, short_id
from .model import DashboardView

_G, _Y, _C, _D, _R = "green", "yellow", "cyan", "dim", "red"


def attention_markup(view: DashboardView) -> str:
    if not view.attention:
        return f"[{_G}]✓ all systems nominal[/]"
    parts = []
    for item in view.attention:
        colour = _R if item.severity == "block" else _Y
        parts.append(f"[{colour}]{'✗' if item.severity == 'block' else '⚠'} {item.text}[/]")
    return "   ".join(parts)


def vitals_markup(view: DashboardView) -> str:
    v = view.vitals
    live = f"[{_G}]● live[/]" if v.is_live else f"[{_R}]● down[/]"
    mint = f"[{_G}]✔ mint[/]" if v.is_mintable else f"[{_Y}]✗ mint[/]"
    fresh = f"[{_G}]● fresh[/]" if v.oracle_fresh else f"[{_R}]● stale[/]"
    return (f"PROTOCOL {live} {mint}    ORACLE {fresh}    "
            f"idle [b]{fmt_money(v.idle_balance)}[/]    PLP [b]{fmt_money(v.plp_supply)}[/]    "
            f"reserve [b]{fmt_money(v.protocol_reserve)}[/]    markets [b]{v.active_markets}[/]")


def keepers_markup(view: DashboardView) -> str:
    k = view.keepers
    if k is None:
        return f"[{_D}]keeper data unavailable[/]"
    oldest = "—" if k.oldest_awaiting_ms is None else fmt_age(k.oldest_awaiting_ms, _now_ms())
    unfunded = ", ".join(short_id(m) for m in k.unfunded_market_ids) or "none"
    feeder = "—" if k.oracle_feeder_latest_ms is None else fmt_age(k.oracle_feeder_latest_ms, _now_ms())
    ckpt = "—" if k.chain_checkpoint is None else str(k.chain_checkpoint)
    return "\n".join([
        f"settlement   {k.settlement_awaiting} awaiting · oldest {oldest}",
        f"unfunded     {unfunded}",
        f"oracle feed  {feeder}",
        f"chain ckpt   {ckpt}",
    ])


def oracle_markup(view: DashboardView) -> str:
    lines = []
    for feed in view.report.oracle.feeds:
        ts = feed.latest_source_timestamp_ms
        age = "—" if ts is None else fmt_age(ts, _now_ms())
        dot = _G if feed.fresh else _R
        thresh = "" if feed.freshness_ms is None else f" /{fmt_duration(feed.freshness_ms)}"
        lines.append(f"[{dot}]●[/] {feed.name:<14} {age}{thresh}")
    return "\n".join(lines)


def cadence_lines(cadence, now_ms: int) -> str:
    # one box row per cadence; reuse the slot states from observability.
    cells = []
    for slot in cadence.slots:
        colour, label = _slot_style(slot.state)
        body = _slot_body(slot, cadence.period_ms, now_ms)
        cells.append(f"[{colour}]{label:<14}[/] {body}")
    header = f"[{_D}]── {cadence.name} · window {cadence.window_size} ──[/]"
    return header + "\n " + "   ".join(cells)


_SLOT_STYLE = {
    "live": (_G, "● LIVE"), "scheduled": (_C, "next"), "pending": (_D, "next"),
    "awaiting_settle": (_Y, "⌛ settle"), "settled": (_D, "settled"),
    "expired_gone": (_D, "expired"), "missing_live": (_R, "LIVE?"),
}


def _slot_style(state: str) -> tuple[str, str]:
    return _SLOT_STYLE.get(state, (_D, state))


def _slot_body(slot, period_ms: int, now_ms: int) -> str:
    if slot.state == "live":
        return f"{fmt_duration(slot.expiry_ms - now_ms)}"
    if slot.state == "scheduled":
        return f"opens {fmt_duration(slot.expiry_ms - now_ms)}"
    if slot.state == "settled" and slot.market and slot.market.settlement_price is not None:
        return f"@ {slot.market.settlement_price // 1_000_000_000:,}"
    return "—"


def _now_ms() -> int:
    return int(time.time() * 1000)


try:
    from textual.app import App, ComposeResult
    from textual.containers import Horizontal, VerticalScroll
    from textual.widgets import Footer, Header, Static
    _TEXTUAL = True
except ImportError as exc:  # textual not installed
    _TEXTUAL = False
    _IMPORT_ERR = exc


if _TEXTUAL:

    class PredictDashboardApp(App):
        TITLE = "Predict Protocol Monitor"
        BINDINGS = [("q", "quit", "Quit"), ("r", "refresh", "Refresh")]
        CSS = """
        #attention { height: auto; padding: 0 1; }
        #vitals { height: auto; padding: 0 1; }
        #cadences { height: 1fr; }
        #bottom { height: auto; }
        #oracle, #keepers { width: 1fr; border: round $primary; padding: 0 1; margin: 0 1 0 0; }
        """

        def __init__(self, loader: Callable[[], DashboardView], refresh_s: int = 10) -> None:
            super().__init__()
            self._loader = loader
            self._refresh_s = max(1, int(refresh_s))
            self._loading = False
            self.theme = "nord"

        def compose(self) -> ComposeResult:
            yield Header(show_clock=True)
            yield Static(id="attention")
            yield Static(id="vitals")
            yield VerticalScroll(id="cadences")
            with Horizontal(id="bottom"):
                yield Static(id="oracle")
                yield Static(id="keepers")
            yield Footer()

        def on_mount(self) -> None:
            self.query_one("#oracle", Static).border_title = "ORACLE"
            self.query_one("#keepers", Static).border_title = "KEEPERS · OPS"
            self.refresh_data()
            self.set_interval(self._refresh_s, self.refresh_data)

        def action_refresh(self) -> None:
            self.refresh_data()

        def refresh_data(self) -> None:
            if self._loading:
                return
            self.run_worker(self._load(), exclusive=True, group="load")

        async def _load(self) -> None:
            self._loading = True
            try:
                view = await asyncio.to_thread(self._loader)
            except Exception as exc:  # surface, don't crash
                self.query_one("#attention", Static).update(f"[red]load error:[/] {exc}")
                return
            finally:
                self._loading = False
            self._apply(view)

        def _apply(self, view: DashboardView) -> None:
            self.query_one("#attention", Static).update(attention_markup(view))
            self.query_one("#vitals", Static).update(vitals_markup(view))
            self.query_one("#oracle", Static).update(oracle_markup(view))
            self.query_one("#keepers", Static).update(keepers_markup(view))
            cadences = self.query_one("#cadences", VerticalScroll)
            cadences.remove_children()
            now = _now_ms()
            for cadence in view.report.cadences:
                cadences.mount(Static(cadence_lines(cadence, now)))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_app -v`
Expected: PASS (markup functions import without Textual; app class only defined when Textual present).

- [ ] **Step 5: Commit**

```bash
git add packages/predict/python_sdk/predict_sdk/dashboard/app.py packages/predict/python_sdk/tests/test_dashboard_app.py
git commit -m "Predict SDK dashboard: Textual app + zone widgets"
```

---

### Task 8: Loader + `run_dashboard` + cli wiring  *(data-plane coupled — see Sequencing)*

**Files:**
- Create: `predict_sdk/dashboard/load.py`
- Modify: `predict_sdk/dashboard/__init__.py`
- Modify: `predict_sdk/cli.py` (only if the `run_dashboard` signature changed)
- Delete: `predict_sdk/dashboard.py`, `tests/test_dashboard.py`
- Test: `tests/test_dashboard_app.py` (add a loader test with fakes)

**Interfaces:**
- Consumes: `config.DeploymentConfig`, `observability.ObservabilityClient`, `onchain.OnchainSnapshotReader` + `SuiReadClient`, `model.build_dashboard_view`.
- Produces: `load_dashboard_view(config, *, now_ms=None, observability=None, reader=None, sui=None) -> DashboardView`; `run_dashboard(refresh_s=10, *, asset="BTC_USD", rpc_url=None, log_file=None) -> None`.

- [ ] **Step 1: Write the failing test** (fakes — no network)

```python
# add to tests/test_dashboard_app.py
from predict_sdk.config import load_testnet_config
from predict_sdk.dashboard.load import load_dashboard_view
from tests.test_dashboard_model import _report, _snapshot
from predict_sdk.onchain import ChainHealth, OnchainSnapshotRequest


class LoaderTests(unittest.TestCase):
    def test_loader_assembles_from_clients(self) -> None:
        class FakeObs:
            def status(self, asset="BTC_USD", now_ms=None):
                return _report()
        class FakeReader:
            def snapshot(self, request): return _snapshot()
        class FakeSui:
            def latest_checkpoint(self): return ChainHealth(True, 99)
        view = load_dashboard_view(
            load_testnet_config(), now_ms=NOW,
            observability=FakeObs(), reader=FakeReader(), sui=FakeSui(),
        )
        self.assertEqual(view.keepers.chain_checkpoint, 99)
        self.assertTrue(view.vitals.is_live)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest tests.test_dashboard_app.LoaderTests -v`
Expected: FAIL with `ModuleNotFoundError: predict_sdk.dashboard.load`.

- [ ] **Step 3: Write minimal implementation**

```python
# predict_sdk/dashboard/load.py
from __future__ import annotations

import time

from ..config import DeploymentConfig
from ..observability import ObservabilityClient
from ..onchain import OnchainSnapshotReader, OnchainSnapshotRequest, SuiReadClient
from .model import DashboardView, build_dashboard_view


def load_dashboard_view(
    config: DeploymentConfig,
    *,
    asset: str = "BTC_USD",
    rpc_url: str | None = None,
    now_ms: int | None = None,
    observability=None,
    reader=None,
    sui=None,
) -> DashboardView:
    now_ms = int(time.time() * 1000) if now_ms is None else now_ms
    observability = observability or ObservabilityClient(config)
    report = observability.status(asset, now_ms=now_ms)
    sui = sui or SuiReadClient(rpc_url) if rpc_url else (sui or SuiReadClient())
    reader = reader or OnchainSnapshotReader(config, client=sui)
    market_ids = tuple(m.market_id for m in report.markets)
    expiries = {m.market_id: m.expiry_ms for m in report.markets if m.expiry_ms is not None}
    snapshot = reader.snapshot(OnchainSnapshotRequest(
        asset=asset, market_ids=market_ids, market_expiries=expiries))
    chain = sui.latest_checkpoint()
    return build_dashboard_view(report, snapshot, chain, now_ms)
```

```python
# predict_sdk/dashboard/__init__.py
from __future__ import annotations

import logging

from ..config import load_testnet_config
from .load import load_dashboard_view

log = logging.getLogger("predict_sdk.dashboard")


def run_dashboard(refresh_s: int = 10, *, asset: str = "BTC_USD",
                  rpc_url: str | None = None, log_file: str | None = None) -> None:
    from .app import _TEXTUAL, PredictDashboardApp  # guarded
    if not _TEXTUAL:
        raise RuntimeError("dashboard requires the 'textual' package; install the SDK's [tui] extra")
    if log_file:
        _configure_logging(log_file)
    config = load_testnet_config()

    def loader():
        return load_dashboard_view(config, asset=asset, rpc_url=rpc_url)

    PredictDashboardApp(loader, refresh_s=refresh_s).run()


def _configure_logging(path: str) -> None:
    handler = logging.FileHandler(path)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    root = logging.getLogger("predict_sdk")
    root.setLevel(logging.INFO)
    root.handlers = [handler]
```

Then `git rm predict_sdk/dashboard.py tests/test_dashboard.py`. Confirm `cli.py` still does `from .dashboard import run_dashboard` (unchanged) and `_dashboard` passes the same kwargs.

- [ ] **Step 4: Run the full suite + pyflakes**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -m unittest discover -s tests && python3 -m pyflakes predict_sdk/ tests/`
Expected: all green; pyflakes clean.

- [ ] **Step 5: Smoke + commit**

Run: `cd packages/predict/python_sdk && PYTHONPATH=. python3 -c "from predict_sdk.dashboard import run_dashboard; print('import ok')"`
Then commit:

```bash
git rm packages/predict/python_sdk/predict_sdk/dashboard.py packages/predict/python_sdk/tests/test_dashboard.py
git add -A
git commit -m "Predict SDK dashboard: live loader + run_dashboard; retire account dashboard"
```

---

## Self-Review

- **Spec coverage:** banner/verdict (Task 7 + report), attention strip (Task 4 + 7), vitals (Task 3 + 7), cadence hero (Task 7 native widgets), oracle panel (Task 7), keepers/ops (Task 5 + 7), refresh/degradation (Task 7 app + fail-open loader), testing (Tasks 1–8 offline). Deferred items (activity feed, trends, solvency/PLP, account view) are explicitly out per the spec's v1 scope. ✓
- **Data deps:** the view-model reads `settled`/`mint_paused`/cadence states from `PredictStatusReport` (stable interface) and cash/liability/heartbeat/reserve from `OnchainSnapshot`; both exist today. Field accuracy tracks the spec's data deps but no interface changes are required. ✓
- **Type consistency:** `KeeperHealth.oracle_feeder_latest_ms` (renamed in Task 5) is used consistently in Task 7 `keepers_markup`. `DashboardView(report, vitals, attention, keepers)` matches Tasks 2/6/7. Loader returns `DashboardView`. ✓
- **Open risk:** Textual `Pilot` end-to-end rendering is not unit-tested (only the pure markup functions are); validated by the import smoke + manual run. Acceptable for a TUI.
