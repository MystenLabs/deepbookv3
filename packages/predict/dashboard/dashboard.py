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
    from textual.containers import Container, VerticalScroll
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


def _rule(label: str, right: str, width: int = 96) -> str:
    left = f"── {label} "
    tail = f" {right} ──"
    fill = "─" * max(3, width - len(left) - len(right) - 4)
    return f"[dim]{left}{fill}{tail}[/]"


# Loading screen: a candlestick chart "draws in" left→right as the load progresses,
# crossing a dim track and then consuming the DEEPBOOK PREDICT wordmark letter by
# letter until, at 100%, it's a full chart. Heights are a fixed, slightly-bullish
# sequence so the reveal reads as one coherent chart rather than flicker.
_EIGHTHS = " ▁▂▃▄▅▆▇█"
_LOADING_TEXT = "DEEPBOOK PREDICT"
_LOADING_CHART = (
    3, 4, 5, 4, 3, 4, 5, 6, 5, 4, 5, 6, 7, 6, 5, 6, 5, 4, 5, 6, 7,
    6, 7, 8, 7, 6, 7, 8, 7, 6, 7, 8, 7, 8, 7, 8, 6, 7, 8, 7, 8, 8,
)


def loading_markup(progress: int, label: str | None = None) -> str:
    progress = max(0, min(100, progress))
    width = len(_LOADING_CHART)
    tstart = width - len(_LOADING_TEXT)  # column where the wordmark begins
    filled = round(width * progress / 100)
    candles = "".join(_EIGHTHS[_LOADING_CHART[i]] for i in range(filled))
    if filled < tstart:
        track = "·" * (tstart - filled)
        text = _LOADING_TEXT
    else:  # the chart has started eating into the wordmark
        track = ""
        text = _LOADING_TEXT[filled - tstart:]
    line = (
        f"[{fmt.BLUE}]{candles}[/][dim]{track}[/][b {fmt.BLUE}]{text}[/]"
        f"  [b {fmt.BLUE}]{progress:>3}%[/]"
    )
    # `label` is only used to surface a load error under the bar.
    return line if label is None else f"{line}\n[red]{escape(label)}[/]"


def _progress_bar(frac: float, width: int = 8) -> str:
    """Plain-text elapsed bar (must stay markup-free: the tile cell escapes it)."""
    frac = 0.0 if frac < 0 else 1.0 if frac > 1 else frac
    filled = round(frac * width)
    return "█" * filled + "░" * (width - filled)


def _slot_body(slot, period_ms: int, now_ms: int) -> str:
    state = _synthetic_slot_state(slot, now_ms)
    if state == "live":
        ttl = slot.expiry_ms - now_ms
        frac = (period_ms - ttl) / period_ms if period_ms else 0.0
        return f"{_progress_bar(frac)} {fmt.duration(ttl)}"
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


def _reference_price(slot, markets_snapshot) -> int | None:
    """The market's reference strike as a 1e9-scaled price. `reference_tick` is a tick
    COUNT (floor(spot / tick_size)), so multiply by tick_size to get a price — this is
    correct regardless of the cadence's tick size (e.g. $1 vs $0.01)."""
    if slot.market is None or not markets_snapshot:
        return None
    snap = markets_snapshot.get(slot.market.market_id)
    if snap is None or snap.reference_tick is None:
        return None
    return snap.reference_tick * snap.tick_size


def _market_tile(slot, period_ms: int, now_ms: int, markets_snapshot=None, width: int = 20) -> list[str]:
    state = _synthetic_slot_state(slot, now_ms)
    color, _ = fmt.STATE_STYLE[state]
    source_label = getattr(slot, "source_label", None)
    title = _slot_title_for_state(state)
    if source_label:
        title = f"{source_label} {title}"
    body = _slot_body(slot, period_ms, now_ms)
    clock = _clock(slot.expiry_ms, now_ms)
    addr = "-" if slot.market is None else fmt.short_id(slot.market.market_id)
    ref = _reference_price(slot, markets_snapshot)
    ref_line = f"ref {fmt.price(ref)}" if ref is not None else "ref -"

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
        cell(ref_line),
        cell(addr),
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


def cadence_markup(cadence, now_ms: int, cadences=(), markets_snapshot=None) -> str:
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
    lines.extend(_join_tiles([
        _market_tile(slot, cadence.period_ms, now_ms, markets_snapshot) for slot in slots
    ]))
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


def _spot(data: OperationalStatus) -> int | None:
    """Current 1e9-scaled spot from any present pyth oracle read in the snapshot."""
    for oracle in data.snapshot.oracles.values():
        if oracle.pyth.present and oracle.pyth.value is not None:
            return oracle.pyth.value
    return None


def _next_settle_ttl(data: OperationalStatus, now_ms: int) -> int | None:
    """Time until the soonest-expiring live market settles, across all cadences."""
    ttls = [
        slot.expiry_ms - now_ms
        for cadence in data.report.cadences
        for slot in cadence.slots
        if slot.state == "live"
    ]
    return min(ttls) if ttls else None


def _vitals_line(data: OperationalStatus, now_ms: int) -> str:
    spot = _spot(data)
    spot_str = "—" if spot is None else fmt.price(spot)
    nxt = _next_settle_ttl(data, now_ms)
    nxt_str = "" if nxt is None else f"    next settle [b]{fmt.duration(nxt)}[/]"
    ckpt = _compact_int(data.chain.latest_checkpoint)
    return (
        f"oracle {_oracle_vital(data, now_ms)}    spot [b]{spot_str}[/]    "
        f"[b]{data.report.pool.active_market_count}[/] mkts{nxt_str}    chain {ckpt}"
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
        #loading-card { width: auto; height: auto; }
        #dashboard {
            height: 1fr;
            layout: vertical;
            background: #101418;
        }
        #status-surface {
            height: auto;
            border-left: thick #6b7a89;
            padding: 1 2;
            margin: 1 1 0 1;
            background: #141a20;
        }
        #footer { height: auto; padding: 0 2; margin: 0 1; color: #6b7a89; }
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
            self._last_fetch_ms: int | None = None
            self.theme = "nord"

        def compose(self) -> ComposeResult:
            yield Header(show_clock=True)
            with Container(id="loading"):
                yield Static(id="loading-card")
            with Container(id="dashboard"):
                yield Static(id="status-surface")
                yield VerticalScroll(id="cadences")
                yield Static(id="footer")
            yield Footer()

        def on_mount(self) -> None:
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
                    self.query_one("#status-surface", Static).update(f"[{fmt.RED}]load error:[/] {escape(str(exc))}")
                else:
                    self.query_one("#loading-card", Static).update(
                        loading_markup(self._loading_progress, f"load error: {exc}")
                    )
                return
            finally:
                self._loading = False
            if not self._initial_loaded:
                self._loading_progress = 100
                self.query_one("#loading-card", Static).update(loading_markup(100))
                await asyncio.sleep(0.2)
                self._hide_loading()
                self._initial_loaded = True
            self._last_fetch_ms = int(time.time() * 1000)
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
            self._render_time_sensitive(data)

        def _render_time_sensitive(self, data: OperationalStatus) -> None:
            now_ms = int(time.time() * 1000)
            surface = self.query_one("#status-surface", Static)
            _, color = _verdict(data)
            surface.styles.border_left = ("thick", color)
            surface.update(surface_markup(data, now_ms))
            self.query_one("#footer", Static).update(
                footer_markup(self._last_fetch_ms, now_ms, self._refresh_s, data.indexer)
            )
            cadences = self.query_one("#cadences", VerticalScroll)
            cadences.remove_children()
            for cadence in data.report.cadences:
                cadences.mount(
                    Static(
                        cadence_markup(cadence, now_ms, data.report.cadences, data.snapshot.markets),
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
