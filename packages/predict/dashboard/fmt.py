from __future__ import annotations

from constants import DUSDC_DECIMALS, FLOAT_SCALING


def money(raw: int | None, decimals: int = 2) -> str:
    if raw is None:
        return "-"
    negative = raw < 0
    raw = -raw if negative else raw
    whole, frac = divmod(raw, 10**DUSDC_DECIMALS)
    frac_str = f"{frac:0{DUSDC_DECIMALS}d}"[:decimals]
    formatted = f"{whole:,}.{frac_str}" if decimals else f"{whole:,}"
    return f"-{formatted}" if negative else formatted


def price(raw_1e9: int | None) -> str:
    return "-" if raw_1e9 is None else f"{raw_1e9 / FLOAT_SCALING:,.0f}"


def short_id(value: str) -> str:
    if not isinstance(value, str) or len(value) <= 15:
        return value
    return f"{value[:8]}…{value[-5:]}"


def duration(ms: int | None) -> str:
    if ms is None:
        return "-"
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


def age(ts_ms: int | None, now_ms: int) -> str:
    if ts_ms is None:
        return "-"
    delta = now_ms - ts_ms
    return "just now" if delta < 1000 else f"{duration(delta)} ago"


# Semantic palette — softer tones cohesive with the dashboard's #6ba6ff dark chrome,
# rather than raw saturated ANSI names.
GREEN = "#6fcf97"
AMBER = "#e3b341"
RED = "#e5707a"
CYAN = "#56c5e8"
BLUE = "#6ba6ff"
DIM = "#6b7a89"

STATE_STYLE: dict[str, tuple[str, str]] = {
    "live": (GREEN, "LIVE"),
    "scheduled": (CYAN, "next"),
    "pending": (DIM, "next"),
    "awaiting_settle": (AMBER, "awaiting"),
    "settled": (DIM, "settled"),
    "expired_gone": (DIM, "expired"),
    "missing_live": (RED, "LIVE?"),
    "skipped": (DIM, "skipped"),
}

# Single-cell status glyphs for quick scanning of the cadence grid.
STATE_GLYPH: dict[str, str] = {
    "live": "●",
    "scheduled": "○",
    "pending": "◌",
    "awaiting_settle": "◔",
    "settled": "✓",
    "expired_gone": "·",
    "missing_live": "✗",
    "skipped": "·",
}
