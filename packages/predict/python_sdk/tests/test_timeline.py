import unittest

from predict_sdk import load_testnet_config
from predict_sdk.observability import MarketStatus, _build_cadence_timelines


def _market(expiry, *, settled=False):
    return MarketStatus(
        market_id=f"0x{expiry:064x}",
        propbook_underlying_id=1,
        expiry_ms=expiry,
        time_to_expiry_ms=None,
        mint_paused=False,
        settled=settled,
        cash_balance=10_000_000_000,
        payout_liability=0,
        rebate_reserve=0,
        tick_size=1_000_000_000,
        blockers=[],
    )


class TimelineTests(unittest.TestCase):
    def test_slot_expiries_and_live_mapping(self) -> None:
        config = load_testnet_config()
        now = 1_800_000_000_123  # 123 ms past a 5m boundary
        # live 5m expiry = next 300_000 ms multiple strictly after now
        live = _market(1_800_000_300_000)
        timelines = _build_cadence_timelines(config, [live], now)

        # rows are ordered fine->coarse: 1m, 5m, 1h
        self.assertEqual([t.name for t in timelines], ["1m", "5m", "1h"])
        five_min = next(t for t in timelines if t.name == "5m")
        self.assertEqual(
            [slot.expiry_ms for slot in five_min.slots],
            [
                1_799_999_700_000,
                1_800_000_000_000,
                1_800_000_300_000,
                1_800_000_600_000,
                1_800_000_900_000,
            ],
        )
        live_slot = five_min.slots[2]
        self.assertEqual(live_slot.position, 0)
        self.assertEqual(live_slot.state, "live")
        self.assertIs(live_slot.market, live)
        # future slots with no market are pending; the immediate past slot is gone
        self.assertEqual(five_min.slots[3].state, "pending")
        self.assertEqual(five_min.slots[0].state, "expired_gone")

    def test_top_of_hour_market_belongs_to_hourly_cadence(self) -> None:
        config = load_testnet_config()
        now = 1_800_000_060_000  # 1 minute past a top-of-hour (also a 5m boundary)
        top_of_hour = 1_800_000_000_000  # divisible by both 5m and 1h
        market = _market(top_of_hour)
        timelines = _build_cadence_timelines(config, [market], now)
        five_min = next(t for t in timelines if t.name == "5m")
        one_hour = next(t for t in timelines if t.name == "1h")

        # 5m row's -1 slot sits on the boundary but must NOT claim the hourly market
        five_min_prev = five_min.slots[1]
        self.assertEqual(five_min_prev.expiry_ms, top_of_hour)
        self.assertIsNone(five_min_prev.market)
        self.assertEqual(five_min_prev.state, "expired_gone")

        # the 1h row owns it (expired, awaiting settle)
        hour_prev = next(slot for slot in one_hour.slots if slot.expiry_ms == top_of_hour)
        self.assertIs(hour_prev.market, market)
        self.assertEqual(hour_prev.state, "awaiting_settle")


if __name__ == "__main__":
    unittest.main()
