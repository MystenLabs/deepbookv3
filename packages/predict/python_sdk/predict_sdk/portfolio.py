from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ._http import post_json
from .constants import DEFAULT_TESTNET_RPC_URL

# Account portfolio + PnL reconstruction from on-chain order events. Positions are
# keyed by `position_root_id` (stable across partial-close replacements). This reads
# events directly over JSON-RPC; a dedicated indexer endpoint would scale better but
# isn't exposed yet. Amounts are raw 6-dp DUSDC base units.

_EVENT_TYPES = ["OrderMinted", "LiveOrderRedeemed", "SettledOrderRedeemed", "LiquidatedOrderRedeemed"]


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
    address: str
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
    def __init__(self, address: str, predict_pkg: str, rpc_url: str = DEFAULT_TESTNET_RPC_URL, *, timeout: float = 30):
        self.address = address
        self.predict_pkg = predict_pkg
        self.rpc_url = rpc_url
        self.timeout = timeout

    def load(self, *, page_limit: int = 400) -> Portfolio:
        events = {t: self._events(t, page_limit) for t in _EVENT_TYPES}
        roots: dict[str, dict] = {}

        for ev in reversed(events["OrderMinted"]):  # oldest first
            j = ev["parsedJson"]
            if j.get("owner") != self.address:
                continue
            root = j["position_root_id"]
            roots.setdefault(root, {"closed_qty": 0, "proceeds": 0, "close_fees": 0})
            roots[root].update(
                mint=j,
                market=j["expiry_market_id"],
                quantity=int(j["quantity"]),
                net_premium=int(j["net_premium"]),
                mint_fees=int(j["trading_fee"]) + int(j["builder_fee"]) + int(j["penalty_fee"]),
                opened_ms=int(ev["timestampMs"]),
            )

        for ev in events["LiveOrderRedeemed"]:
            j = ev["parsedJson"]
            r = roots.get(j["position_root_id"])
            if j.get("owner") != self.address or r is None:
                continue
            r["closed_qty"] += int(j["quantity_closed"])
            r["proceeds"] += int(j["redeem_amount"])
            r["close_fees"] += int(j["trading_fee"]) + int(j["builder_fee"]) + int(j["penalty_fee"])
        for ev in events["SettledOrderRedeemed"]:
            j = ev["parsedJson"]
            r = roots.get(j["position_root_id"])
            if j.get("owner") != self.address or r is None:
                continue
            r["closed_qty"] += int(j["quantity_closed"])
            r["proceeds"] += int(j["payout_amount"])
        for ev in events["LiquidatedOrderRedeemed"]:
            j = ev["parsedJson"]
            r = roots.get(j["position_root_id"])
            if j.get("owner") != self.address or r is None:
                continue
            r["closed_qty"] += int(j["quantity_closed"])

        portfolio = Portfolio(address=self.address)
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

    def _events(self, name: str, limit: int) -> list[dict]:
        event_type = f"{self.predict_pkg}::order_events::{name}"
        out: list[dict] = []
        cursor = None
        while len(out) < limit:
            result = self._rpc("suix_queryEvents", [
                {"MoveEventType": event_type}, cursor, min(50, limit - len(out)), True,
            ])
            out.extend(result.get("data", []))
            if not result.get("hasNextPage") or not result.get("nextCursor"):
                break
            cursor = result["nextCursor"]
        return out

    def _rpc(self, method: str, params: list) -> Any:
        body = post_json(
            self.rpc_url,
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
            self.timeout,
        )
        if body.get("error") is not None:
            raise RuntimeError(f"RPC {method} error: {body['error']}")
        return body["result"]
