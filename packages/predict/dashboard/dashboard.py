from __future__ import annotations

import argparse
import asyncio
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

THIS_DIR = Path(__file__).resolve().parent
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))

import fmt
from config import load_testnet_config
from constants import DEFAULT_TESTNET_RPC_URL
from status import OperationalStatus, StatusLoader
from sui import OnchainSnapshotReader, SuiReadClient

try:
    from rich.markup import escape
    from textual.app import App, ComposeResult
    from textual.containers import Container, Horizontal, VerticalScroll
    from textual.widgets import Footer, Header, Static

    _TEXTUAL_AVAILABLE = True
    _TEXTUAL_IMPORT_ERROR: ImportError | None = None
except ImportError as exc:
    _TEXTUAL_AVAILABLE = False
    _TEXTUAL_IMPORT_ERROR = exc


@dataclass(frozen=True)
class RenderSlot:
    expiry_ms: int
    position: int
    state: str
    market: object | None
    source_label: str | None = None


def _verdict(data: OperationalStatus) -> tuple[str, str]:
    report = data.report
    oracle_blockers = set(report.oracle.blockers)
    if any(blocker not in oracle_blockers for blocker in report.blockers):
        return "✗ BLOCKED", fmt.RED
    if not report.has_live_market:
        return "✗ NO LIVE MARKETS", fmt.RED
    if not report.oracle.fresh:
        return "⚠ ORACLE STALE", fmt.AMBER
    if report.is_mintable:
        return "● LIVE", fmt.GREEN
    return "⚠ DEGRADED", fmt.AMBER


def _chip(label: str, color: str) -> str:
    return f"[black on {color}] {escape(label)} [/]"


def _rule(label: str, right: str, width: int = 96) -> str:
    left = f"── {label} "
    tail = f" {right} ──"
    fill = "─" * max(3, width - len(left) - len(right) - 4)
    return f"[dim]{left}{fill}{tail}[/]"


def loading_markup(progress: int, label: str = "loading operational status") -> str:
    width = 34
    progress = max(0, min(100, progress))
    filled = round(width * progress / 100)
    bar = "█" * filled + "░" * (width - filled)
    return "\n".join(
        [
            "[b]PREDICT[/]",
            f"[dim]{escape(label)}[/]",
            "",
            f"[{fmt.BLUE}]▕{bar}▏[/] [b]{progress:>3}%[/]",
        ]
    )


def banner_markup(data: OperationalStatus, now_ms: int) -> str:
    report = data.report
    verdict, color = _verdict(data)
    as_of = time.strftime("%H:%M:%S", time.localtime(now_ms / 1000))
    chain = (
        "-"
        if data.chain.latest_checkpoint is None
        else str(data.chain.latest_checkpoint)
    )
    indexer = "OK" if data.indexer.reachable and data.indexer.ok else "DEGRADED"
    return (
        f"[b]PREDICT OPERATIONAL STATUS[/]  {_chip(verdict, color)}\n"
        f"[dim]{escape(report.network)} / {escape(report.asset)}  |  "
        f"chain {escape(report.chain_id)}  |  checkpoint {chain}  |  "
        f"indexer {indexer}  |  pool {fmt.short_id(report.pool_vault_id)}  |  "
        f"as of {as_of}[/]"
    )


def attention_markup(data: OperationalStatus) -> str:
    if not data.attention:
        return "[green]all systems nominal[/]"
    parts = []
    for item in data.attention:
        block = item.severity == "block"
        color = fmt.RED if block else fmt.AMBER
        glyph = "✗" if block else "⚠"
        parts.append(f"[{color}]{glyph} {escape(item.text)}[/]")
    return "   ".join(parts)


def pool_markup(data: OperationalStatus) -> str:
    pool = data.report.pool
    snapshot = data.snapshot.pool
    supply_pending = "-" if snapshot is None else str(snapshot.supply_requests_pending)
    withdraw_pending = "-" if snapshot is None else str(snapshot.withdraw_requests_pending)
    return "\n".join(
        [
            f"[dim]idle[/]       [b]{fmt.money(pool.idle_balance)}[/]",
            f"[dim]PLP[/]        [b]{fmt.money(pool.plp_total_supply)}[/]",
            "",
            f"[dim]markets[/]    [b]{pool.active_market_count}[/]",
            f"[dim]queues[/]     supply {supply_pending} / withdraw {withdraw_pending}",
        ]
    )


def oracle_markup(data: OperationalStatus, now_ms: int) -> str:
    lines = []
    for feed in data.report.oracle.feeds:
        color = fmt.GREEN if feed.fresh else fmt.RED
        age = fmt.age(feed.latest_source_timestamp_ms, now_ms)
        blocker = "" if feed.blocker is None else f"  [red]{escape(feed.blocker)}[/]"
        label = "FRESH" if feed.fresh else "STALE"
        lines.append(f"{_chip(label, color)}  {feed.name:<15} [b]{age}[/]{blocker}")
    return "\n".join(lines) or "[dim]no oracle feeds[/]"


def health_markup(data: OperationalStatus) -> str:
    chain = data.chain
    indexer = data.indexer
    if chain.reachable:
        chain_line = f"{_chip('CHAIN', fmt.GREEN)}  checkpoint [b]{chain.latest_checkpoint}[/]"
    else:
        chain_line = f"{_chip('CHAIN', fmt.AMBER)}  unavailable {escape(chain.error or '')}"

    if not indexer.reachable:
        indexer_line = f"{_chip('INDEXER', fmt.AMBER)} unreachable"
    elif not indexer.ok:
        indexer_line = f"{_chip('INDEXER', fmt.AMBER)} status not OK"
    else:
        lag = "-" if indexer.max_time_lag_seconds is None else f"{indexer.max_time_lag_seconds}s"
        indexer_line = f"{_chip('INDEXER', fmt.GREEN)} lag [b]{lag}[/]"

    return "\n".join(
        [
            chain_line,
            indexer_line,
            f"markets shown     [b]{len(data.report.markets)}[/]",
            f"cadences          [b]{len(data.report.cadences)}[/]",
        ]
    )


def _slot_body(slot, now_ms: int) -> str:
    state = _synthetic_slot_state(slot, now_ms)
    if state == "live":
        return fmt.duration(slot.expiry_ms - now_ms)
    if state == "scheduled":
        return fmt.duration(slot.expiry_ms - now_ms)
    if state == "awaiting_settle":
        return fmt.age(slot.expiry_ms, now_ms)
    if state == "settled":
        price = slot.market.settlement_price if slot.market else None
        return f"@ {fmt.price(price)}" if price is not None else "settled"
    if state in ("missing_live", "pending"):
        return "not created"
    if state == "skipped":
        return "proxied"
    return "-"


def _synthetic_slot_state(slot, now_ms: int) -> str:
    if slot.state in ("live", "scheduled") and slot.expiry_ms <= now_ms:
        return "awaiting_settle"
    if slot.state == "scheduled" and slot.position == 0:
        return "live"
    if slot.state == "pending" and slot.position == 0:
        return "missing_live"
    return slot.state


def _clock(ms: int, now_ms: int) -> str:
    moment = time.localtime(ms / 1000)
    if time.strftime("%Y%m%d", moment) != time.strftime("%Y%m%d", time.localtime(now_ms / 1000)):
        return time.strftime("%m/%d %H:%M", moment)
    return time.strftime("%H:%M:%S", moment)


def _market_tile(slot, now_ms: int, width: int = 20) -> list[str]:
    state = _synthetic_slot_state(slot, now_ms)
    color, _ = fmt.STATE_STYLE[state]
    source_label = getattr(slot, "source_label", None)
    title = _slot_title_for_state(state)
    if source_label:
        title = f"{source_label} {title}"
    body = _slot_body(slot, now_ms)
    clock = _clock(slot.expiry_ms, now_ms)
    market = "-" if slot.market is None else fmt.short_id(slot.market.market_id)

    def cell(text: str) -> str:
        clean = text if len(text) <= width else text[:width - 1] + "…"
        return f"[{color}]│[/] {escape(clean):<{width}} [{color}]│[/]"

    glyph = fmt.STATE_GLYPH.get(state, "·")
    head = f"{glyph} {title[:13]}"
    top = f"[{color}]╭ {head} " + "─" * max(0, width - len(head)) + "╮[/]"
    bottom = f"[{color}]╰" + "─" * (width + 2) + "╯[/]"
    return [
        top,
        cell(clock),
        cell(body),
        cell(market),
        bottom,
    ]


def _slot_title_for_state(state: str) -> str:
    if state == "live":
        return "LIVE"
    if state == "scheduled":
        return "NEXT"
    if state == "awaiting_settle":
        return "SETTLE"
    if state == "settled":
        return "DONE"
    if state == "missing_live":
        return "MISSING"
    if state == "expired_gone":
        return "PAST"
    if state == "skipped":
        return "PROXY"
    return "PENDING"


def _join_tiles(tiles: list[list[str]]) -> list[str]:
    if not tiles:
        return []
    height = max(len(tile) for tile in tiles)
    padded = [tile + [" " * 24] * (height - len(tile)) for tile in tiles]
    return ["  " + "  ".join(row) for row in zip(*padded)]


def _empty_slot_state(position: int, expiry_ms: int, now_ms: int) -> str:
    if expiry_ms <= now_ms:
        return "expired_gone"
    if position == 0:
        return "missing_live"
    return "pending"


def _owner_cadence(cadences, expiry_ms: int):
    owners = [cadence for cadence in cadences if expiry_ms % cadence.period_ms == 0]
    if not owners:
        return None
    return max(owners, key=lambda cadence: cadence.period_ms)


def _source_slot(owner, expiry_ms: int, position: int, now_ms: int) -> RenderSlot:
    existing = next((slot for slot in owner.slots if slot.expiry_ms == expiry_ms), None)
    if existing is not None:
        return RenderSlot(expiry_ms, position, existing.state, existing.market, owner.name)
    return RenderSlot(
        expiry_ms,
        position,
        _empty_slot_state(position, expiry_ms, now_ms),
        None,
        owner.name,
    )


def _visible_slots(cadence, now_ms: int, cadences) -> tuple[RenderSlot, ...]:
    live_expiry = ((now_ms // cadence.period_ms) + 1) * cadence.period_ms
    slots_by_expiry = {slot.expiry_ms: slot for slot in cadence.slots}
    visible: list[RenderSlot] = []
    for position in (-2, -1, 0, 1, 2):
        expiry = live_expiry + position * cadence.period_ms
        owner = _owner_cadence(cadences, expiry)
        if owner is not None and owner.cadence_id != cadence.cadence_id:
            visible.append(_source_slot(owner, expiry, position, now_ms))
            continue
        existing = slots_by_expiry.get(expiry)
        if existing is not None:
            visible.append(RenderSlot(expiry, position, existing.state, existing.market))
            continue
        visible.append(RenderSlot(expiry, position, _empty_slot_state(position, expiry, now_ms), None))
    return tuple(visible)


def cadence_markup(cadence, now_ms: int, cadences=()) -> str:
    cadences = tuple(cadences) or (cadence,)
    slots = _visible_slots(cadence, now_ms, cadences)
    live = sum(1 for slot in slots if _synthetic_slot_state(slot, now_ms) == "live")
    owned = sum(1 for slot in slots if slot.market is not None) + cadence.backlog_count
    summary = f"{owned} markets | {live} live"
    if cadence.backlog_count:
        summary += f" | {cadence.backlog_count} backlog"
    detail = (
        f"period {fmt.duration(cadence.period_ms)} | window {cadence.window_size} | "
        f"tick {cadence.tick_size / 1_000_000_000:g}"
    )
    lines = [_rule(cadence.name, f"{detail} | {summary}")]
    lines.extend(_join_tiles([_market_tile(slot, now_ms) for slot in slots]))
    return "\n".join(lines)


def _compact_int(n: int | None) -> str:
    if n is None:
        return "—"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def _oracle_vital(data: OperationalStatus, now_ms: int) -> str:
    stale = [feed for feed in data.report.oracle.feeds if not feed.fresh]
    if not stale:
        return f"[{fmt.GREEN}]● fresh[/]"
    ages = [now_ms - feed.latest_source_timestamp_ms for feed in stale if feed.latest_source_timestamp_ms]
    worst = fmt.duration(max(ages)) if ages else "?"
    return f"[{fmt.RED}]⚠ STALE {worst}[/]"


def _backing_vital(data: OperationalStatus) -> str:
    if data.snapshot.pool is None or data.backing is None:
        return "[dim]—[/]"
    backing = data.backing
    if backing.ratio is None:
        return f"[{fmt.GREEN}]✓ idle[/]"
    color = fmt.GREEN if backing.healthy else fmt.AMBER
    glyph = "✓" if backing.healthy else "⚠"
    return f"[{color}]{glyph} {backing.ratio:.2f}×[/]"


def _vitals_line(data: OperationalStatus, now_ms: int) -> str:
    pool = data.report.pool
    liq = f"{fmt.money(pool.idle_balance)}/{fmt.money(pool.plp_total_supply)}"
    ckpt = _compact_int(data.chain.latest_checkpoint)
    return (
        f"oracle {_oracle_vital(data, now_ms)}    backing {_backing_vital(data)}    "
        f"liq [b]{liq}[/]    [b]{pool.active_market_count}[/] mkts    chain {ckpt}"
    )


def surface_markup(data: OperationalStatus, now_ms: int) -> str:
    verdict, color = _verdict(data)
    report = data.report
    identity = f"[dim]{escape(report.network)} · {escape(report.asset)} · chain {escape(report.chain_id)}[/]"
    vitals = _vitals_line(data, now_ms)

    if not data.attention:
        return "\n".join(
            [
                f"[b {color}]{verdict}[/]          {identity}",
                f"[{color}]all systems nominal[/]",
                "",
                vitals,
            ]
        )

    issue_lines = []
    for item in data.attention:
        block = item.severity == "block"
        glyph = "✗" if block else "⚠"
        item_color = fmt.RED if block else fmt.AMBER
        issue_lines.append(f"[b {item_color}]{glyph} {escape(item.text)}[/]")
    count = f"[dim]{len(data.attention)} issue(s)[/]"
    return "\n".join(
        [
            f"[b {color}]{verdict}[/]   {count}      {identity}",
            *issue_lines,
            "",
            f"[dim]{vitals}[/]",
        ]
    )


def footer_markup(last_fetch_ms: int | None, now_ms: int, refresh_s: int, indexer) -> str:
    age = "—" if last_fetch_ms is None else fmt.duration(now_ms - last_fetch_ms)
    idx = "OK" if indexer.reachable and indexer.ok else "DEGRADED"
    lag = "" if indexer.max_time_lag_seconds is None else f" {indexer.max_time_lag_seconds}s"
    return f"[dim]data as of {age} · ↻ {refresh_s}s · idx {idx}{lag}[/]"


if _TEXTUAL_AVAILABLE:

    class PredictDashboard(App):
        TITLE = "Predict Operational Status"
        ENABLE_COMMAND_PALETTE = False
        BINDINGS = [
            ("q", "quit", "Quit"),
            ("r", "refresh", "Refresh"),
        ]
        CSS = """
        Screen { layout: vertical; background: #101418; color: #d7dde5; }
        Header { background: #161d24; color: #eef3f8; }
        Footer { background: #161d24; color: #8fa0af; }
        #loading {
            height: 1fr;
            align: center middle;
            background: #101418;
        }
        #loading-card {
            width: 72;
            height: auto;
            content-align: center middle;
            border: heavy #6ba6ff;
            border-title-color: #6ba6ff;
            padding: 2 4;
            background: #141a20;
        }
        #dashboard {
            height: 1fr;
            layout: vertical;
            background: #101418;
        }
        #banner {
            height: auto;
            border: heavy #6ba6ff;
            border-title-color: #6ba6ff;
            padding: 1 2;
            margin: 1 1 0 1;
            background: #141a20;
        }
        #attention {
            height: auto;
            padding: 0 2;
            margin: 1 1 0 1;
            color: #cbd5df;
        }
        #top { height: auto; margin: 1 1 0 1; }
        #pool, #oracle, #health {
            width: 1fr;
            height: auto;
            border: tall #3d4b59;
            border-title-color: #8fb7ff;
            background: #141a20;
            padding: 0 1;
        }
        #pool, #oracle { margin: 0 1 0 0; }
        #cadences { height: 1fr; padding: 0 1; margin: 1; background: #101418; }
        .cadence {
            height: auto;
            margin: 0 0 1 0;
            padding: 0 1 1 1;
            background: #101418;
        }
        """

        def __init__(self, loader: StatusLoader, refresh_s: int = 10) -> None:
            super().__init__()
            self._loader = loader
            self._refresh_s = max(1, int(refresh_s))
            self._loading = False
            self._initial_loaded = False
            self._loading_progress = 0
            self._latest_data: OperationalStatus | None = None
            self.theme = "nord"

        def compose(self) -> ComposeResult:
            yield Header(show_clock=True)
            with Container(id="loading"):
                yield Static(id="loading-card")
            with Container(id="dashboard"):
                yield Static(id="banner")
                yield Static(id="attention")
                with Horizontal(id="top"):
                    yield Static(id="pool")
                    yield Static(id="oracle")
                    yield Static(id="health")
                yield VerticalScroll(id="cadences")
            yield Footer()

        def on_mount(self) -> None:
            self.query_one("#banner", Static).border_title = "STATUS"
            self.query_one("#pool", Static).border_title = "POOL"
            self.query_one("#oracle", Static).border_title = "ORACLE"
            self.query_one("#health", Static).border_title = "CHAIN / INDEXER"
            self._show_loading()
            self.set_interval(0.08, self._tick_loading)
            self.set_interval(1.0, self._tick_clock)
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
            self.sub_title = "loading…" if not self._initial_loaded else "refreshing…"
            try:
                data = await asyncio.to_thread(self._loader.load)
            except Exception as exc:
                self.sub_title = "error"
                if self._initial_loaded:
                    self.query_one("#attention", Static).update(f"[red]load error:[/] {escape(str(exc))}")
                else:
                    self.query_one("#loading-card", Static).update(
                        loading_markup(self._loading_progress, f"load error: {exc}")
                    )
                return
            finally:
                self._loading = False
            if not self._initial_loaded:
                self._loading_progress = 100
                self.query_one("#loading-card", Static).update(loading_markup(100, "status loaded"))
                await asyncio.sleep(0.2)
                self._hide_loading()
                self._initial_loaded = True
            self._apply(data)
            self.sub_title = f"updated {time.strftime('%H:%M:%S')}"

        def _show_loading(self) -> None:
            self._loading_progress = 0
            self.query_one("#loading").display = True
            self.query_one("#dashboard").display = False
            self.query_one("#loading-card", Static).update(loading_markup(0))

        def _hide_loading(self) -> None:
            self.query_one("#loading").display = False
            self.query_one("#dashboard").display = True

        def _tick_loading(self) -> None:
            if self._initial_loaded:
                return
            if self._loading_progress < 70:
                self._loading_progress += 3
            elif self._loading_progress < 90:
                self._loading_progress += 1
            elif self._loading_progress < 95:
                self._loading_progress += 1
            else:
                return
            self.query_one("#loading-card", Static).update(
                loading_markup(self._loading_progress)
            )

        def _tick_clock(self) -> None:
            if not self._initial_loaded or self._latest_data is None:
                return
            self._render_time_sensitive(self._latest_data)

        def _apply(self, data: OperationalStatus) -> None:
            self._latest_data = data
            now_ms = int(time.time() * 1000)
            self.query_one("#banner", Static).update(banner_markup(data, now_ms))
            self.query_one("#attention", Static).update(attention_markup(data))
            self.query_one("#pool", Static).update(pool_markup(data))
            self.query_one("#health", Static).update(health_markup(data))
            self._render_time_sensitive(data)

        def _render_time_sensitive(self, data: OperationalStatus) -> None:
            now_ms = int(time.time() * 1000)
            self.query_one("#oracle", Static).update(oracle_markup(data, now_ms))
            cadences = self.query_one("#cadences", VerticalScroll)
            cadences.remove_children()
            for cadence in data.report.cadences:
                cadences.mount(
                    Static(
                        cadence_markup(cadence, now_ms, data.report.cadences),
                        classes="cadence",
                    )
                )


def run_dashboard(
    *,
    asset: str,
    rpc_url: str,
    indexer_url: str | None,
    refresh_s: int,
    timeout: float,
) -> None:
    if not _TEXTUAL_AVAILABLE:
        raise RuntimeError(
            "dashboard mode requires textual; install it with `pip install textual`"
        ) from _TEXTUAL_IMPORT_ERROR
    config = load_testnet_config()
    sui = SuiReadClient(rpc_url, timeout=timeout)
    loader = StatusLoader(
        config,
        asset=asset,
        indexer_url=indexer_url,
        snapshot_reader=OnchainSnapshotReader(config, client=sui),
        timeout=timeout,
    )
    PredictDashboard(loader, refresh_s=refresh_s).run()


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="predict-dashboard")
    parser.add_argument("--asset", default="BTC_USD")
    parser.add_argument("--rpc-url", default=DEFAULT_TESTNET_RPC_URL)
    parser.add_argument("--indexer-url", default=None)
    parser.add_argument("--refresh", type=int, default=10)
    parser.add_argument("--timeout", type=float, default=10)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    run_dashboard(
        asset=args.asset,
        rpc_url=args.rpc_url,
        indexer_url=args.indexer_url,
        refresh_s=args.refresh,
        timeout=args.timeout,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
