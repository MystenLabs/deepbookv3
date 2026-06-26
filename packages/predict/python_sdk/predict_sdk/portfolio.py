from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal

from .indexer import PredictIndexerClient, Transport

# Account portfolio + PnL reconstruction from the Predict indexer's per-manager order
# feed (`GET /managers/{manager}/orders`). The feed is already scoped to one
# AccountWrapper (manager) and interleaves the four order events, discriminated by
# `kind`, so no owner filtering is needed. Positions are keyed by `position_root_id`
# (stable across partial-close replacements). Amounts are raw 6-dp DUSDC base units.

_MINT = "order_minted"
_LIVE = "live_order_redeemed"
_SETTLED = "settled_order_redeemed"
_LIQUIDATED = "liquidated_order_redeemed"


def _to_int(value) -> int:
    # Indexer monetary fields are NUMERIC/BigDecimal and serialize as JSON strings or
    # numbers; the values are integer base units, so parse via Decimal then truncate.
    return int(Decimal(str(value)))


@dataclass
class Position:
    position_root_id: str
    order_id: str
    market_id: str
    lower_tick: int
    higher_tick: int
    leverage: int
    quantity: int
    open_quantity: int
    entry_probability: int
    net_premium: int
    mint_fees: int
    opened_ms: int


@dataclass
class Portfolio:
    manager_id: str
    positions: list[Position] = field(default_factory=list)
    realized_pnl: int = 0
    premium_paid: int = 0
    proceeds: int = 0
    fees_paid: int = 0
    closed_count: int = 0

    @property
    def open_count(self) -> int:
        return len(self.positions)

    @property
    def open_premium(self) -> int:
        return sum(p.net_premium * p.open_quantity // p.quantity for p in self.positions if p.quantity)


class PortfolioReader:
    def __init__(
        self,
        manager_id: str,
        server_url: str,
        *,
        transport: Transport | None = None,
        timeout: float = 30,
    ):
        self.manager_id = manager_id
        self.client = PredictIndexerClient(server_url, transport=transport, timeout=timeout)

    def load(self, *, page_limit: int = 500) -> Portfolio:
        minted: list[dict] = []
        live: list[dict] = []
        settled: list[dict] = []
        liquidated: list[dict] = []
        for ev in self._orders(page_limit):
            kind = ev.get("kind")
            if kind == _MINT:
                minted.append(ev)
            elif kind == _LIVE:
                live.append(ev)
            elif kind == _SETTLED:
                settled.append(ev)
            elif kind == _LIQUIDATED:
                liquidated.append(ev)

        roots: dict[str, dict] = {}
        for ev in reversed(minted):  # oldest first, to seed roots before closes
            root = ev["position_root_id"]
            roots.setdefault(root, {"closed_qty": 0, "proceeds": 0, "close_fees": 0})
            roots[root].update(
                mint=ev,
                market=ev["expiry_market_id"],
                quantity=_to_int(ev["quantity"]),
                net_premium=_to_int(ev["net_premium"]),
                mint_fees=_to_int(ev["trading_fee"]) + _to_int(ev["builder_fee"]) + _to_int(ev["penalty_fee"]),
                opened_ms=int(ev["checkpoint_timestamp_ms"]),
            )

        for ev in live:
            r = roots.get(ev["position_root_id"])
            if r is None:
                continue
            r["closed_qty"] += _to_int(ev["quantity_closed"])
            r["proceeds"] += _to_int(ev["redeem_amount"])
            r["close_fees"] += _to_int(ev["trading_fee"]) + _to_int(ev["builder_fee"]) + _to_int(ev["penalty_fee"])
        for ev in settled:
            r = roots.get(ev["position_root_id"])
            if r is None:
                continue
            r["closed_qty"] += _to_int(ev["quantity_closed"])
            r["proceeds"] += _to_int(ev["payout_amount"])
        for ev in liquidated:
            r = roots.get(ev["position_root_id"])
            if r is None:
                continue
            r["closed_qty"] += _to_int(ev["quantity_closed"])

        portfolio = Portfolio(manager_id=self.manager_id)
        for root, r in roots.items():
            if "mint" not in r:
                continue
            qty, closed = r["quantity"], r["closed_qty"]
            open_qty = max(0, qty - closed)
            portfolio.premium_paid += r["net_premium"]
            portfolio.fees_paid += r["mint_fees"] + r["close_fees"]
            portfolio.proceeds += r["proceeds"]
            if closed > 0:
                cost = (r["net_premium"] + r["mint_fees"]) * closed // qty
                portfolio.realized_pnl += r["proceeds"] - r["close_fees"] - cost
                portfolio.closed_count += 1
            if open_qty > 0:
                j = r["mint"]
                portfolio.positions.append(Position(
                    position_root_id=root, order_id=j["order_id"], market_id=r["market"],
                    lower_tick=int(j["lower_tick"]), higher_tick=int(j["higher_tick"]),
                    leverage=int(j["leverage"]), quantity=qty, open_quantity=open_qty,
                    entry_probability=int(j["entry_probability"]), net_premium=r["net_premium"],
                    mint_fees=r["mint_fees"], opened_ms=r["opened_ms"],
                ))
        portfolio.positions.sort(key=lambda p: p.opened_ms, reverse=True)
        return portfolio

    def _orders(self, page_limit: int) -> list[dict]:
        """Walk the manager order feed newest→oldest, deduping by event_digest.

        The feed pages by an `end_time` upper bound (seconds), so the boundary second
        is re-fetched; the digest set drops those repeats. Stops when a page is short
        or yields nothing new (the latter guards the >page_limit-events-in-one-second
        edge from looping)."""
        out: list[dict] = []
        seen: set[str] = set()
        end_time_s: int | None = None
        while True:
            page = self.client.manager_orders(self.manager_id, limit=page_limit, end_time_s=end_time_s)
            fresh = [e for e in page if e.get("event_digest") not in seen]
            seen.update(e["event_digest"] for e in fresh)
            out.extend(fresh)
            if len(page) < page_limit or not fresh:
                break
            end_time_s = min(int(e["checkpoint_timestamp_ms"]) for e in page) // 1000
        return out
