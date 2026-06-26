from __future__ import annotations

import asyncio
import json
import time
import urllib.request
from dataclasses import dataclass, field

from .config import DeploymentConfig, load_testnet_config
from .constants import POS_INF_TICK
from .observability import ObservabilityClient, PredictStatusReport
from .portfolio import Portfolio, PortfolioReader
from .rpc import SuiRpcObjectReader

# Live TUI "dashboard mode": a clean, READ-ONLY monitor for one Predict account.
# It never trades — it only assembles a Portfolio + PredictStatusReport into panels
# that auto-refresh off the UI thread. All display logic lives in the pure
# data-assembly functions below (no Textual import), so it is unit-testable without a
# terminal; the Textual `App` is a thin shell that renders the assembled `DashboardData`.
#
# `textual` is an OPTIONAL dependency (the `[tui]` extra): the import is guarded so the
# module — and every pure data function — imports fine even when Textual is absent.

DEFAULT_RPC_URL = "https://fullnode.testnet.sui.io:443"

# Decimals of the on-chain assets we display (raw integer amounts -> human strings).
_DUSDC_DECIMALS = 6
_SUI_DECIMALS = 9

# pnl coloring decisions surface as plain color names so the pure layer stays
# Textual-free; the widgets wrap them in Rich markup.
_GREEN, _RED, _DIM = "green", "red", "dim"


# === pure formatting helpers (no Textual; fully unit-tested) ===

def fmt_units(raw: int | None, decimals_in: int, decimals_out: int = 2) -> str:
    """Render a raw fixed-point integer as a grouped decimal string, truncating
    toward zero to `decimals_out` places. `None` -> em dash."""
    if raw is None:
        return "—"
    negative = raw < 0
    raw = -raw if negative else raw
    whole, frac = divmod(raw, 10**decimals_in)
    frac_str = f"{frac:0{decimals_in}d}"[:decimals_out]
    formatted = f"{whole:,}.{frac_str}" if decimals_out else f"{whole:,}"
    return f"-{formatted}" if negative else formatted


def fmt_money(raw: int | None, decimals: int = 2) -> str:
    """Raw 6-dp DUSDC -> money string, e.g. 98_500_000 -> "98.50"."""
    return fmt_units(raw, _DUSDC_DECIMALS, decimals)


def fmt_sui(raw: int | None) -> str:
    """Raw 9-dp MIST -> SUI string, e.g. 1_500_000_000 -> "1.5000"."""
    return fmt_units(raw, _SUI_DECIMALS, 4)


def fmt_signed_money(raw: int | None) -> str:
    """Money string with an explicit leading sign for positive gains."""
    if raw is None:
        return "—"
    formatted = fmt_money(raw)  # already carries "-" for negatives
    return f"+{formatted}" if raw > 0 else formatted


def pnl_color(raw: int | None) -> str:
    """Coloring decision for a signed PnL figure: green up, red down, dim flat."""
    if raw is None or raw == 0:
        return _DIM
    return _GREEN if raw > 0 else _RED


def fmt_prob(raw_1e9: int | None) -> str:
    """1e9-scaled probability -> percent, e.g. 985009513 -> "98.5%"."""
    if raw_1e9 is None:
        return "—"
    return f"{raw_1e9 / 1e9 * 100:.1f}%"


def fmt_ticks(lower: int, higher: int) -> str:
    """Strike range as raw tick indices; the open upper bound shows as ∞."""
    hi = "∞" if higher >= POS_INF_TICK else str(higher)
    return f"{lower} → {hi}"


def fmt_age(opened_ms: int, now_ms: int) -> str:
    """Coarse age of a position (seconds -> minutes -> hours -> days)."""
    ms = now_ms - opened_ms
    if ms < 0:
        return "0s"
    seconds = ms // 1000
    if seconds < 60:
        return f"{seconds}s"
    minutes = seconds // 60
    if minutes < 60:
        return f"{minutes}m"
    hours = minutes // 60
    if hours < 24:
        return f"{hours}h {minutes % 60:02d}m"
    days = hours // 24
    return f"{days}d {hours % 24:02d}h"


def short_id(value: str) -> str:
    """Abbreviate a 0x object/account id for compact display."""
    if not isinstance(value, str) or len(value) <= 15:
        return value
    return f"{value[:8]}…{value[-5:]}"


# === pure data-assembly (Portfolio + report -> renderable rows/strings) ===

@dataclass(frozen=True)
class PositionRow:
    market: str
    strike: str
    quantity: str
    entry: str
    premium: str
    age: str


@dataclass(frozen=True)
class StatusLine:
    live: bool
    mintable: bool
    oracle_fresh: bool
    summary: str  # "3 markets · 1 live · 2 cadences"


@dataclass(frozen=True)
class DashboardData:
    address: str
    address_short: str
    network: str
    dusdc: str
    sui: str
    realized_pnl: str
    realized_color: str
    premium_at_risk: str
    open_count: int
    closed_count: int
    premium_paid: str
    proceeds: str
    status: StatusLine
    positions: list[PositionRow] = field(default_factory=list)


def build_position_rows(portfolio: Portfolio, now_ms: int) -> list[PositionRow]:
    rows: list[PositionRow] = []
    for position in portfolio.positions:
        # premium attributable to the still-open quantity (round down; user-facing).
        open_premium = (
            position.net_premium * position.open_quantity // position.quantity
            if position.quantity
            else 0
        )
        rows.append(
            PositionRow(
                market=short_id(position.market_id),
                strike=fmt_ticks(position.lower_tick, position.higher_tick),
                quantity=fmt_money(position.open_quantity),
                entry=fmt_prob(position.entry_probability),
                premium=fmt_money(open_premium),
                age=fmt_age(position.opened_ms, now_ms),
            )
        )
    return rows


def build_status_line(report: PredictStatusReport) -> StatusLine:
    live_markets = sum(
        1 for cadence in report.cadences for slot in cadence.slots if slot.state == "live"
    )
    summary = (
        f"{len(report.markets)} markets · {live_markets} live "
        f"· {len(report.cadences)} cadences"
    )
    return StatusLine(
        live=report.is_live,
        mintable=report.is_mintable,
        oracle_fresh=report.oracle.fresh,
        summary=summary,
    )


def build_dashboard_data(
    address: str,
    network: str,
    dusdc_raw: int | None,
    sui_raw: int | None,
    portfolio: Portfolio,
    report: PredictStatusReport,
    now_ms: int,
) -> DashboardData:
    return DashboardData(
        address=address,
        address_short=short_id(address),
        network=network,
        dusdc=fmt_money(dusdc_raw),
        sui=fmt_sui(sui_raw),
        realized_pnl=fmt_signed_money(portfolio.realized_pnl),
        realized_color=pnl_color(portfolio.realized_pnl),
        premium_at_risk=fmt_money(portfolio.open_premium),
        open_count=portfolio.open_count,
        closed_count=portfolio.closed_count,
        premium_paid=fmt_money(portfolio.premium_paid),
        proceeds=fmt_money(portfolio.proceeds),
        status=build_status_line(report),
        positions=build_position_rows(portfolio, now_ms),
    )


# === network loaders (I/O; kept off the pure path and out of the UI thread) ===

def _fetch_balance(rpc_url: str, address: str, coin_type: str, timeout: float) -> int:
    payload = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": "suix_getBalance", "params": [address, coin_type]}
    )
    request = urllib.request.Request(
        rpc_url, data=payload.encode("utf-8"),
        headers={"content-type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = json.loads(response.read().decode("utf-8"))
    if body.get("error") is not None:
        raise RuntimeError(f"suix_getBalance error: {body['error']}")
    result = body.get("result") or {}
    return int(result.get("totalBalance", 0))


def load_dashboard_data(
    config: DeploymentConfig,
    address: str,
    asset: str,
    rpc_url: str,
    *,
    timeout: float = 10,
    now_ms: int | None = None,
) -> DashboardData:
    """Fetch everything one refresh needs over JSON-RPC, then assemble (pure) it."""
    now_ms = int(time.time() * 1000) if now_ms is None else now_ms
    reader = SuiRpcObjectReader(rpc_url, timeout=timeout)
    report = ObservabilityClient(config, reader).status(asset, now_ms=now_ms)
    predict_pkg = config.package_id("predict")
    dusdc_type = config.linked_package_id("dusdc") + "::dusdc::DUSDC"
    portfolio = PortfolioReader(address, predict_pkg, rpc_url, timeout=timeout).load()
    dusdc_raw = _fetch_balance(rpc_url, address, dusdc_type, timeout)
    sui_raw = _fetch_balance(rpc_url, address, "0x2::sui::SUI", timeout)
    return build_dashboard_data(
        address, config.network, dusdc_raw, sui_raw, portfolio, report, now_ms
    )


def _default_address() -> str:
    try:
        from .signer import load_signer

        return load_signer().address
    except Exception as exc:  # missing key / missing pynacl
        raise RuntimeError(
            "no address provided and none could be loaded from SUI_PRIVATE_KEY; "
            "pass run_dashboard(address=...)"
        ) from exc


# === Textual app (optional import; the whole UI layer is guarded) ===

try:
    from rich.text import Text
    from textual.app import App, ComposeResult
    from textual.containers import Horizontal
    from textual.widgets import DataTable, Footer, Header, Static

    _TEXTUAL_AVAILABLE = True
    _TEXTUAL_IMPORT_ERROR: ImportError | None = None
except ImportError as exc:  # textual not installed
    _TEXTUAL_AVAILABLE = False
    _TEXTUAL_IMPORT_ERROR = exc


_MISSING_TEXTUAL = (
    "dashboard mode requires the 'textual' package; install it with "
    "`pip install textual` (or the SDK's `[tui]` extra)"
)


if _TEXTUAL_AVAILABLE:

    def _dot(ok: bool) -> str:
        return f"[{_GREEN}]●[/]" if ok else f"[{_RED}]●[/]"

    class PredictDashboardApp(App):
        """Read-only live monitor for one Predict account."""

        TITLE = "Predict Monitor"
        ENABLE_COMMAND_PALETTE = False
        CSS = """
        Screen { layout: vertical; background: $surface; }

        #summary {
            height: auto;
            border: round $accent;
            border-title-color: $accent;
            padding: 0 2;
            margin: 1 1 0 1;
        }

        #positions {
            height: 1fr;
            border: round $primary;
            border-title-color: $primary;
            margin: 1;
        }

        #bottom { height: auto; margin: 0 1 1 1; }

        #pnl, #status {
            width: 1fr;
            height: auto;
            border: round $primary;
            border-title-color: $primary;
            padding: 0 2;
        }
        #pnl { margin: 0 1 0 0; }
        """

        BINDINGS = [
            ("q", "quit", "Quit"),
            ("r", "refresh", "Refresh"),
        ]

        def __init__(self, loader, refresh_s: int = 5):
            super().__init__()
            self._loader = loader
            self._refresh_s = max(1, int(refresh_s))
            self.theme = "nord"

        def compose(self) -> ComposeResult:
            yield Header(show_clock=True)
            yield Static(id="summary")
            yield DataTable(id="positions", zebra_stripes=True, cursor_type="row")
            with Horizontal(id="bottom"):
                yield Static(id="pnl")
                yield Static(id="status")
            yield Footer()

        def on_mount(self) -> None:
            table = self.query_one("#positions", DataTable)
            table.add_columns("Market", "Strike (ticks)", "Qty", "Entry", "Premium", "Age")
            self.query_one("#summary", Static).border_title = "Account"
            self.query_one("#positions", DataTable).border_title = "Open Positions"
            self.query_one("#pnl", Static).border_title = "PnL & Activity"
            self.query_one("#status", Static).border_title = "Protocol"
            self.refresh_data()
            self.set_interval(self._refresh_s, self.refresh_data)

        def refresh_data(self) -> None:
            # Exclusive worker: never stack refreshes if a fetch runs long.
            self.run_worker(self._load(), exclusive=True, group="load")

        def action_refresh(self) -> None:
            self.refresh_data()

        async def _load(self) -> None:
            self.sub_title = "refreshing…"
            try:
                data = await asyncio.to_thread(self._loader)
            except Exception as exc:  # surface, don't crash the UI
                self.sub_title = "error"
                self.query_one("#status", Static).update(f"[{_RED}]load error:[/] {exc}")
                return
            self._apply(data)
            self.sub_title = f"updated {time.strftime('%H:%M:%S')}"

        def _apply(self, data: DashboardData) -> None:
            self.query_one("#summary", Static).update(self._summary_markup(data))
            table = self.query_one("#positions", DataTable)
            table.clear()
            for row in data.positions:
                table.add_row(
                    row.market, row.strike, row.quantity, row.entry, row.premium, row.age
                )
            if not data.positions:
                table.add_row(Text("— no open positions —", style="dim"), "", "", "", "", "")
            self.query_one("#pnl", Static).update(self._pnl_markup(data))
            self.query_one("#status", Static).update(self._status_markup(data))

        @staticmethod
        def _summary_markup(data: DashboardData) -> str:
            realized = f"[{data.realized_color}]{data.realized_pnl}[/]"
            return "\n".join(
                [
                    f"[b]{data.address_short}[/]   [dim]·[/]   {data.network}",
                    f"DUSDC [b]{data.dusdc}[/]    [dim]·[/]    SUI [b]{data.sui}[/]",
                    f"realized PnL {realized}    [dim]·[/]    "
                    f"premium at risk [yellow]{data.premium_at_risk}[/]",
                ]
            )

        @staticmethod
        def _pnl_markup(data: DashboardData) -> str:
            realized = f"[{data.realized_color}]{data.realized_pnl}[/]"
            return "\n".join(
                [
                    f"realized PnL   {realized}",
                    f"open {data.open_count}   [dim]·[/]   closed {data.closed_count}",
                    f"premium paid   {data.premium_paid}",
                    f"proceeds       {data.proceeds}",
                ]
            )

        @staticmethod
        def _status_markup(data: DashboardData) -> str:
            status = data.status
            return "\n".join(
                [
                    f"{_dot(status.live)} {'live' if status.live else 'degraded'}"
                    f"   [dim]·[/]   {_dot(status.mintable)} "
                    f"{'mintable' if status.mintable else 'not mintable'}",
                    f"{_dot(status.oracle_fresh)} oracle "
                    f"{'fresh' if status.oracle_fresh else 'stale'}",
                    f"[dim]{status.summary}[/]",
                ]
            )


def run_dashboard(
    address: str | None = None,
    refresh_s: int = 5,
    *,
    asset: str = "BTC_USD",
    rpc_url: str | None = None,
) -> None:
    """Wire a PortfolioReader + ObservabilityClient loader and launch the TUI monitor."""
    if not _TEXTUAL_AVAILABLE:
        raise RuntimeError(_MISSING_TEXTUAL) from _TEXTUAL_IMPORT_ERROR
    config = load_testnet_config()
    rpc_url = rpc_url or DEFAULT_RPC_URL
    address = address or _default_address()

    def loader() -> DashboardData:
        return load_dashboard_data(config, address, asset, rpc_url)

    PredictDashboardApp(loader, refresh_s=refresh_s).run()
