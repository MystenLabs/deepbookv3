from __future__ import annotations

import re
import time

from .constants import CADENCE_NAMES, CADENCE_PERIOD_MS
from .indexer import IndexerHealth
from .observability import CadenceTimeline, PredictStatusReport, TimelineSlot

# Wide boxed-dashboard renderer for a PredictStatusReport. ANSI color is opt-in via
# the `color` flag (the CLI enables it only for an interactive TTY); with color off
# the same layout renders as plain text, so it stays readable when piped or logged.
# Wall-clock times are shown in the local timezone (banner names it); money is shown
# to 2 decimals (full precision lives in --json).

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

_RESET = "\033[0m"
_BOLD = "\033[1m"
_DIM = "\033[2m"
_GREEN = "\033[32m"
_RED = "\033[31m"
_YELLOW = "\033[33m"
_CYAN = "\033[36m"

_BANNER_W = 105      # inner width of the banner box
_BOX_W = 18          # inner width of one market box
_BOX_INDENT = "   "  # leading margin for cadence timeline rows
_N_PAST, _N_NEXT = 2, 2

# state -> (border color, top-border label)
_STATE_STYLE = {
    "live": (_GREEN, "● LIVE"),
    "unfunded": (_YELLOW, "⚠ UNFUNDED"),
    "scheduled": (_CYAN, "next"),
    "pending": (_DIM, "next"),
    "awaiting_settle": (_YELLOW, "expired"),
    "settled": (_DIM, "settled"),
    "expired_gone": (_DIM, "expired"),
    "missing_live": (_RED, "LIVE?"),
}


class _Paint:
    def __init__(self, enabled: bool):
        self.enabled = enabled

    def __call__(self, text: str, *codes: str) -> str:
        if not self.enabled or not codes:
            return text
        return "".join(codes) + text + _RESET


def render_dashboard(
    report: PredictStatusReport,
    now_ms: int,
    *,
    color: bool = True,
    indexer: IndexerHealth | None = None,
) -> str:
    paint = _Paint(color)
    out: list[str] = []
    out.extend(_banner(report, now_ms, paint))
    out.append("")
    out.extend(_blockers(report, paint))
    out.extend(_panels(report, now_ms, paint))
    if indexer is not None:
        out.append(_indexer_line(indexer, paint))
    out.append("")
    for cadence in report.cadences:
        out.extend(_cadence_section(cadence, now_ms, paint))
        out.append("")
    if not report.cadences:
        out.append(f"  {paint('— no enabled cadences', _DIM)}")
    return "\n".join(out).rstrip("\n")


# === banner ===

def _banner(report: PredictStatusReport, now_ms: int, paint: _Paint) -> list[str]:
    verdict, vcolor = _verdict(report)
    title = f"{paint('PREDICT', _BOLD)} · {report.network}"
    top = _rule_between(
        "╭─ ", title, paint(verdict, vcolor, _BOLD), " ─╮", _BANNER_W + 2, paint
    )
    tz = time.strftime("%Z", time.localtime(now_ms / 1000)) or "local"
    facts = (
        f"  {report.asset}   {paint('·', _DIM)}   chain {report.chain_id}"
        f"   {paint('·', _DIM)}   pool {_short_id(report.pool_vault_id)}"
        f"   {paint('·', _DIM)}   as of {_clock(now_ms, now_ms)} {tz}"
    )
    mid = "│" + _pad(facts, _BANNER_W) + "│"
    bot = "╰" + "─" * _BANNER_W + "╯"
    return [top, mid, bot]


def _verdict(report: PredictStatusReport) -> tuple[str, str]:
    oracle_blockers = set(report.oracle.blockers)
    if any(b not in oracle_blockers for b in report.blockers):
        return "✗ BLOCKED", _RED
    if not report.has_live_market:
        return "✗ NO LIVE MARKETS", _RED
    if not report.oracle.fresh:
        return "⚠ ORACLE STALE", _YELLOW
    if report.is_mintable:
        return "● LIVE", _GREEN
    if any(slot.state == "unfunded" for cadence in report.cadences for slot in cadence.slots):
        return "⚠ LIVE · UNFUNDED", _YELLOW
    return "⚠ DEGRADED", _YELLOW


# === blockers (non-oracle only; oracle health lives in the ORACLE panel) ===

def _blockers(report: PredictStatusReport, paint: _Paint) -> list[str]:
    oracle_blockers = set(report.oracle.blockers)
    blockers = [b for b in dict.fromkeys(report.blockers) if b not in oracle_blockers]
    if not blockers:
        return []
    lines = [f"  {paint('✗ BLOCKERS', _RED, _BOLD)}"]
    lines.extend(f"  {paint('•', _RED)} {b}" for b in blockers)
    lines.append("")
    return lines


# === ORACLE | POOL side-by-side ===

def _panels(report: PredictStatusReport, now_ms: int, paint: _Paint) -> list[str]:
    left = _oracle_lines(report, now_ms, paint)
    right = _pool_lines(report, paint)
    width = max((_visible_len(line) for line in left), default=0) + 3
    rows = max(len(left), len(right))
    left += [""] * (rows - len(left))
    right += [""] * (rows - len(right))
    return [_pad(l, width) + r for l, r in zip(left, right)]


def _oracle_lines(report: PredictStatusReport, now_ms: int, paint: _Paint) -> list[str]:
    lines = [f"  {paint('ORACLE', _BOLD)}"]
    for feed in report.oracle.feeds:
        ts = feed.latest_source_timestamp_ms
        if ts is None:
            # no per-expiry data: the freshness limit is irrelevant, so omit it
            if not report.has_live_market:
                dot, age = paint("○", _DIM), paint("no live expiry", _DIM)
            else:
                dot, age = paint("●", _RED), paint("no data", _RED)
            limit = ""
        else:
            dot = paint("●", _GREEN if feed.fresh else _RED)
            text = _format_age(now_ms - ts)
            age = text if feed.fresh else paint(text, _RED)
            limit = (
                paint(f"/ {_format_duration(feed.freshness_ms)}", _DIM)
                if feed.freshness_ms is not None
                else ""
            )
        lines.append(f"  {dot} {_pad(feed.name, 22)}{_pad(age, 12)} {limit}")
    note = _clock_skew_note(report, now_ms)
    if note:
        lines.append(f"  {paint('ⓘ ' + note, _DIM)}")
    return lines


def _pool_lines(report: PredictStatusReport, paint: _Paint) -> list[str]:
    pool = report.pool
    allocated = sum(m.cash_balance or 0 for m in report.markets)
    rows = [
        ("idle", _money(pool.idle_balance)),
        ("allocated", _money(allocated)),
        ("PLP supply", _money(pool.plp_total_supply)),
        ("reserve", _money(pool.protocol_reserve_balance)),
        (
            "queues",
            f"supply {_count(pool.supply_requests_pending)} "
            f"{paint('·', _DIM)} wd {_count(pool.withdraw_requests_pending)}",
        ),
    ]
    lines = [paint("POOL", _BOLD)]
    lines.extend(f"{paint(_pad(label, 11), _DIM)} {value}" for label, value in rows)
    return lines


def _indexer_line(health: IndexerHealth, paint: _Paint) -> str:
    if not health.reachable:
        return f"  {paint('⚠ indexer unreachable', _YELLOW)}"
    if not health.ok:
        return f"  {paint('⚠ indexer status not OK', _YELLOW)}"
    lag = health.max_time_lag_seconds
    if lag is not None and lag > 30:
        return f"  {paint(f'⚠ indexer lag {lag}s ({health.max_lag_pipeline})', _YELLOW)}"
    return f"  {paint('ⓘ indexer ok · lag ' + (f'{lag}s' if lag is not None else '—'), _DIM)}"


# === markets table (predict-sdk markets, from the indexer /markets endpoint) ===

def render_markets_table(markets: list[dict], now_ms: int, *, color: bool = True) -> str:
    paint = _Paint(color)
    out = [f"  {paint('PREDICT markets', _BOLD)}  {paint(f'· {len(markets)} shown (newest first)', _DIM)}", ""]
    header = (
        f"  {_pad('expiry', 17)}{_pad('market', 18)}{_pad('cad', 5)}"
        f"{_pad('init cash', 14)}{_pad('lev', 7)}created"
    )
    out.append(paint(header, _DIM))
    for market in markets:
        expiry = _as_int(market.get("expiry"))
        created = _as_int(market.get("checkpoint_timestamp_ms"))
        lev = _as_int(market.get("max_admission_leverage"))
        out.append(
            f"  {_pad(_clock_full(expiry), 17)}"
            f"{_pad(_short_id(str(market.get('expiry_market_id', '—'))), 18)}"
            f"{_pad(_cadence_label(expiry), 5)}"
            f"{_pad(_money(_as_int(market.get('initial_expiry_cash'))), 14)}"
            f"{_pad(_leverage(lev), 7)}"
            f"{_clock_full(created)}"
        )
    if not markets:
        out.append(f"  {paint('— no markets returned', _DIM)}")
    return "\n".join(out)


def _cadence_label(expiry: int | None) -> str:
    if expiry is None:
        return "?"
    for cadence_id in sorted(CADENCE_PERIOD_MS, key=lambda i: CADENCE_PERIOD_MS[i], reverse=True):
        if expiry % CADENCE_PERIOD_MS[cadence_id] == 0:
            return CADENCE_NAMES[cadence_id]
    return "?"


def _leverage(raw_1e9: int | None) -> str:
    return "—" if raw_1e9 is None else f"{raw_1e9 / 1e9:g}x"


# === per-cadence timeline ===

def _cadence_section(cadence: CadenceTimeline, now_ms: int, paint: _Paint) -> list[str]:
    live = sum(1 for s in cadence.slots if s.state == "live")
    owned = sum(1 for s in cadence.slots if s.market is not None) + cadence.backlog_count
    summary = f"{owned} mkts · {live} live"
    if cadence.backlog_count:
        summary += f" · {cadence.backlog_count} backlog"
    detail = (
        f"period {_format_duration(cadence.period_ms)} "
        f"· window {cadence.window_size} · tick {cadence.tick_size / 1e9:g}"
    )
    header = _rule_between(
        f"  ── {paint(cadence.name, _BOLD)} ── ",
        paint(detail, _DIM),
        paint(summary, _DIM),
        " ──",
        _BANNER_W,
        paint,
    )
    boxes = [_market_box(slot, cadence.period_ms, now_ms, paint) for slot in cadence.slots]
    return [header, *_join_boxes(boxes)]


def _market_box(slot: TimelineSlot, period_ms: int, now_ms: int, paint: _Paint) -> list[str]:
    color, label = _STATE_STYLE[slot.state]
    market = slot.market
    interior = [
        _clock(slot.expiry_ms, now_ms),
        _box_status(slot, period_ms, now_ms),
        f"cash {_money(market.cash_balance) if market else '—'}",
        f"liab {_money(market.payout_liability) if market and market.payout_liability is not None else '—'}",
    ]
    lines = [_box_top(label, color, paint)]
    lines.extend(_box_side(text, color, paint) for text in interior)
    lines.append(paint("└" + "─" * _BOX_W + "┘", color))
    return lines


def _box_status(slot: TimelineSlot, period_ms: int, now_ms: int) -> str:
    if slot.state == "live":
        ttl = slot.expiry_ms - now_ms
        frac = (period_ms - ttl) / period_ms if period_ms else 0.0
        return f"{_progress_bar(frac)} {_format_duration(ttl)}"
    if slot.state == "unfunded":
        return "⚠ unfunded"
    if slot.state == "scheduled":
        return f"opens {_format_duration(slot.expiry_ms - now_ms)}"
    if slot.state == "awaiting_settle":
        return "⚠ awaiting settle"
    if slot.state == "settled":
        price = slot.market.settlement_price if slot.market else None
        return f"✓ @ {_price(price)}" if price is not None else "✓ settled"
    if slot.state in ("missing_live", "pending"):
        return "✗ not created"
    return "—"


def _progress_bar(frac: float, width: int = 6) -> str:
    frac = 0.0 if frac < 0 else 1.0 if frac > 1 else frac
    filled = int(round(frac * width))
    return "▓" * filled + "░" * (width - filled)


# === box / rule primitives ===

def _box_top(label: str, color: str, paint: _Paint) -> str:
    left = f"┌ {label} "
    fill = "─" * max(0, _BOX_W + 2 - _visible_len(left) - 1)
    return paint(left + fill + "┐", color)


def _box_side(content: str, color: str, paint: _Paint) -> str:
    inner = _pad(" " + content, _BOX_W)
    return paint("│", color) + inner + paint("│", color)


def _join_boxes(boxes: list[list[str]]) -> list[str]:
    height = max(len(b) for b in boxes)
    blank = " " * (_BOX_W + 2)
    padded = [b + [blank] * (height - len(b)) for b in boxes]
    return [_BOX_INDENT + " ".join(row) for row in zip(*padded)]


def _rule_between(
    prefix: str, left: str, right: str, suffix: str, width: int, paint: _Paint
) -> str:
    head = prefix + left + " "
    tail = " " + right + suffix
    fill = "─" * max(1, width - _visible_len(head) - _visible_len(tail))
    return head + fill + tail


# === formatting helpers ===

def _visible_len(text: str) -> int:
    return len(_ANSI_RE.sub("", text))


def _pad(text: str, width: int, align: str = "left") -> str:
    gap = width - _visible_len(text)
    if gap <= 0:
        return text
    return " " * gap + text if align == "right" else text + " " * gap


def _money(raw: int | None, decimals: int = 2) -> str:
    if raw is None:
        return "—"
    negative = raw < 0
    raw = -raw if negative else raw
    whole, frac = divmod(raw, 10**6)
    frac_str = f"{frac:06d}"[:decimals]
    formatted = f"{whole:,}.{frac_str}" if decimals else f"{whole:,}"
    return f"-{formatted}" if negative else formatted


def _price(raw_1e9: int | None) -> str:
    # settlement price is FLOAT_SCALING (1e9); show as a whole quote-price figure
    return "—" if raw_1e9 is None else f"{raw_1e9 / 1e9:,.0f}"


def _count(value: int | None) -> str:
    return "—" if value is None else str(value)


def _as_int(value) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _short_id(object_id: str) -> str:
    if not isinstance(object_id, str) or len(object_id) <= 15:
        return object_id
    return f"{object_id[:8]}…{object_id[-5:]}"


def _format_duration(ms: int | None) -> str:
    if ms is None:
        return "n/a"
    if ms < 0:
        return "expired"
    total = ms // 1000
    if total < 60:
        return f"{total}s"
    if total < 3600:
        minutes, seconds = divmod(total, 60)
        return f"{minutes}m {seconds:02d}s"
    if total < 86400:
        hours, remainder = divmod(total, 3600)
        return f"{hours}h {remainder // 60:02d}m"
    days, remainder = divmod(total, 86400)
    return f"{days}d {remainder // 3600:02d}h"


def _format_age(ms: int) -> str:
    if ms < 1000:  # sub-second, or oracle slightly ahead of a skewed local clock
        return "just now"
    return f"{_format_duration(ms)} ago"


def _clock(ms: int, now_ms: int) -> str:
    moment = time.localtime(ms / 1000)
    if time.strftime("%Y%m%d", moment) != time.strftime("%Y%m%d", time.localtime(now_ms / 1000)):
        return time.strftime("%m/%d %H:%M", moment)
    return time.strftime("%H:%M:%S", moment)


def _clock_full(ms: int | None) -> str:
    return "—" if ms is None else time.strftime("%m/%d %H:%M:%S", time.localtime(ms / 1000))


def _clock_skew_note(report: PredictStatusReport, now_ms: int) -> str | None:
    ahead = [
        feed.latest_source_timestamp_ms - now_ms
        for feed in report.oracle.feeds
        if feed.latest_source_timestamp_ms is not None
        and feed.latest_source_timestamp_ms > now_ms
    ]
    if not ahead:
        return None
    return f"local clock ~{max(ahead) / 1000:.1f}s behind oracle"
