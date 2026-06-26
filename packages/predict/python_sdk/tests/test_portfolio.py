import unittest

from predict_sdk.portfolio import PortfolioReader

ME = "0xme"
OTHER = "0xother"
MARKET = "0xmarket"


def _ev(parsed, ts=1000):
    return {"parsedJson": parsed, "timestampMs": str(ts)}


def _minted(root, owner=ME, qty=100_000_000, premium=40_000_000, fee=1_000_000):
    return _ev({
        "owner": owner, "position_root_id": root, "order_id": root,
        "expiry_market_id": MARKET, "lower_tick": "100", "higher_tick": "200",
        "leverage": "1000000000", "entry_probability": "400000000",
        "quantity": str(qty), "net_premium": str(premium),
        "trading_fee": str(fee), "builder_fee": "0", "penalty_fee": "0",
    })


def _redeemed_live(root, owner=ME, closed=100_000_000, amount=45_000_000, fee=1_000_000):
    return _ev({
        "owner": owner, "position_root_id": root, "order_id": root,
        "quantity_closed": str(closed), "remaining_quantity": "0",
        "redeem_amount": str(amount), "trading_fee": str(fee),
        "builder_fee": "0", "penalty_fee": "0",
    })


class PortfolioReconstructionTests(unittest.TestCase):
    def _reader_with(self, events_by_type):
        reader = PortfolioReader(ME, "0xpkg")
        reader._events = lambda name, limit: events_by_type.get(name, [])  # type: ignore
        return reader

    def test_open_and_realized_pnl(self) -> None:
        reader = self._reader_with({
            "OrderMinted": [
                _minted("A", qty=100_000_000, premium=40_000_000, fee=1_000_000),
                _minted("B", qty=50_000_000, premium=30_000_000, fee=0),
                _minted("C", owner=OTHER),  # someone else — must be ignored
            ],
            "LiveOrderRedeemed": [
                _redeemed_live("A", closed=100_000_000, amount=45_000_000, fee=1_000_000),
            ],
        })
        pf = reader.load()

        # A fully closed: proceeds 45 - close_fee 1 - cost (40+1) = +3 DUSDC
        self.assertEqual(pf.realized_pnl, 3_000_000)
        self.assertEqual(pf.closed_count, 1)
        # B still open; C (other owner) excluded
        self.assertEqual(pf.open_count, 1)
        self.assertEqual(pf.positions[0].position_root_id, "B")
        self.assertEqual(pf.positions[0].open_quantity, 50_000_000)
        self.assertEqual(pf.premium_paid, 70_000_000)
        self.assertEqual(pf.proceeds, 45_000_000)

    def test_partial_close_keeps_remainder_open(self) -> None:
        reader = self._reader_with({
            "OrderMinted": [_minted("A", qty=100_000_000, premium=40_000_000, fee=0)],
            "LiveOrderRedeemed": [_redeemed_live("A", closed=40_000_000, amount=18_000_000, fee=0)],
        })
        pf = reader.load()
        self.assertEqual(pf.open_count, 1)
        self.assertEqual(pf.positions[0].open_quantity, 60_000_000)
        # cost for the closed 40%: 40 * 40/100 = 16; realized = 18 - 16 = +2
        self.assertEqual(pf.realized_pnl, 2_000_000)


if __name__ == "__main__":
    unittest.main()
