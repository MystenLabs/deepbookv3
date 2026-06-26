import unittest
from urllib.parse import parse_qs, urlparse

from predict_sdk.portfolio import PortfolioReader

# Offline: a fake transport models the predict-server's per-manager order feed —
# newest-first, optional `end_time` (unix seconds) upper bound, `limit` cap. The feed
# is already scoped to one manager, so there is no owner filtering to test. Monetary
# fields are passed as strings (BigDecimal-style) to exercise Decimal parsing.

MGR = "0xmgr"
MARKET = "0xmarket"


def _minted(root, *, digest, ts=1000, qty="100000000", premium="40000000", fee="1000000"):
    return {
        "kind": "order_minted", "event_digest": digest, "checkpoint_timestamp_ms": ts,
        "expiry_market_id": MARKET, "order_id": root, "position_root_id": root,
        "owner": "0xowner", "lower_tick": 100, "higher_tick": 200,
        "leverage": 1_000_000_000, "entry_probability": 400_000_000,
        "quantity": qty, "net_premium": premium,
        "trading_fee": fee, "builder_fee": "0", "penalty_fee": "0",
    }


def _live(root, *, digest, ts=2000, closed="100000000", amount="45000000", fee="1000000"):
    return {
        "kind": "live_order_redeemed", "event_digest": digest, "checkpoint_timestamp_ms": ts,
        "expiry_market_id": MARKET, "order_id": root, "position_root_id": root,
        "owner": "0xowner", "quantity_closed": closed, "remaining_quantity": "0",
        "redeem_amount": amount, "trading_fee": fee, "builder_fee": "0", "penalty_fee": "0",
    }


def _feed(events):
    """A transport that serves `events` like the server: newest-first, end_time + limit."""
    def transport(url, timeout):
        query = parse_qs(urlparse(url).query)
        limit = int(query.get("limit", ["500"])[0])
        ordered = sorted(events, key=lambda e: e["checkpoint_timestamp_ms"], reverse=True)
        if "end_time" in query:
            cutoff = int(query["end_time"][0]) * 1000
            ordered = [e for e in ordered if e["checkpoint_timestamp_ms"] <= cutoff]
        return ordered[:limit]
    return transport


def _reader(events):
    return PortfolioReader(MGR, "https://x", transport=_feed(events))


class PortfolioReconstructionTests(unittest.TestCase):
    def test_open_and_realized_pnl(self) -> None:
        pf = _reader([
            _minted("A", digest="a", qty="100000000", premium="40000000", fee="1000000"),
            _minted("B", digest="b", qty="50000000", premium="30000000", fee="0"),
            _live("A", digest="ra", closed="100000000", amount="45000000", fee="1000000"),
        ]).load()

        # A fully closed: proceeds 45 - close_fee 1 - cost (40+1) = +3 DUSDC
        self.assertEqual(pf.realized_pnl, 3_000_000)
        self.assertEqual(pf.closed_count, 1)
        # B still open
        self.assertEqual(pf.open_count, 1)
        self.assertEqual(pf.positions[0].position_root_id, "B")
        self.assertEqual(pf.positions[0].open_quantity, 50_000_000)
        self.assertEqual(pf.premium_paid, 70_000_000)
        self.assertEqual(pf.proceeds, 45_000_000)

    def test_partial_close_keeps_remainder_open(self) -> None:
        pf = _reader([
            _minted("A", digest="a", qty="100000000", premium="40000000", fee="0"),
            _live("A", digest="ra", closed="40000000", amount="18000000", fee="0"),
        ]).load()
        self.assertEqual(pf.open_count, 1)
        self.assertEqual(pf.positions[0].open_quantity, 60_000_000)
        # cost for the closed 40%: 40 * 40/100 = 16; realized = 18 - 16 = +2
        self.assertEqual(pf.realized_pnl, 2_000_000)

    def test_walks_pages_and_dedupes_boundary(self) -> None:
        # Three open mints across separate seconds; page_limit=2 forces 3 windowed
        # pages whose end_time boundaries re-serve an already-seen event (deduped).
        events = [
            _minted("X", digest="x", ts=3000, premium="10000000", fee="0"),
            _minted("Y", digest="y", ts=2000, premium="10000000", fee="0"),
            _minted("Z", digest="z", ts=1000, premium="10000000", fee="0"),
        ]
        pf = _reader(events).load(page_limit=2)
        self.assertEqual(pf.open_count, 3)
        self.assertEqual({p.position_root_id for p in pf.positions}, {"X", "Y", "Z"})


if __name__ == "__main__":
    unittest.main()
