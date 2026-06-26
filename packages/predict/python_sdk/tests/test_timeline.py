import unittest

from predict_sdk import load_testnet_config
from predict_sdk.observability import (
    MarketStatus,
    _build_cadence_timelines,
    _cadences_from_registry,
)


def _enabled(config):
    by_id = {c.id: c for c in config.cadences.values()}
    return [c for c in by_id.values() if c.window_size > 0]


def _market(expiry, *, settled=False, cash=10_000_000_000):
    return MarketStatus(
        market_id=f"0x{expiry:064x}",
        propbook_underlying_id=1,
        expiry_ms=expiry,
        time_to_expiry_ms=None,
        mint_paused=False,
        settled=settled,
        cash_balance=cash,
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
        timelines = _build_cadence_timelines(_enabled(config), [live], now)

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
        timelines = _build_cadence_timelines(_enabled(config), [market], now)
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

    def test_live_market_with_zero_cash_is_unfunded(self) -> None:
        config = load_testnet_config()
        now = 1_800_000_000_123
        unfunded = _market(1_800_000_300_000, cash=0)
        timelines = _build_cadence_timelines(_enabled(config), [unfunded], now)

        five_min = next(t for t in timelines if t.name == "5m")
        live_slot = five_min.slots[2]
        self.assertEqual(live_slot.state, "unfunded")
        self.assertIs(live_slot.market, unfunded)
        self.assertTrue(five_min.has_live_market)  # live by expiry, just not funded


class RegistryCadenceTests(unittest.TestCase):
    def test_enabled_cadences_parsed_from_registry_object(self) -> None:
        fields = {
            "market_manager": {
                "fields": {
                    "cadences": [
                        {"fields": {"window_size": "3", "tick_size": "1000000000",
                                    "admission_tick_size": "10000000000",
                                    "max_expiry_allocation": "50000000000",
                                    "initial_expiry_cash": "10000000000"}},   # id 0 = 1m
                        {"fields": {"window_size": "0", "tick_size": "0",
                                    "admission_tick_size": "0",
                                    "max_expiry_allocation": "0",
                                    "initial_expiry_cash": "0"}},             # id 1 = 5m, disabled
                        {"fields": {"window_size": "3", "tick_size": "1000000000",
                                    "admission_tick_size": "10000000000",
                                    "max_expiry_allocation": "250000000000",
                                    "initial_expiry_cash": "50000000000"}},   # id 2 = 1h
                    ]
                }
            }
        }
        cadences = _cadences_from_registry(fields)

        # disabled cadence (window 0) is dropped; ids map to fixed names + periods
        self.assertEqual([(c.id, c.name, c.window_size) for c in cadences], [(0, "1m", 3), (2, "1h", 3)])
        self.assertEqual(cadences[1].period_ms, 3_600_000)
        self.assertEqual(cadences[1].initial_expiry_cash, 50_000_000_000)

    def test_missing_market_manager_returns_empty(self) -> None:
        self.assertEqual(_cadences_from_registry({}), [])


if __name__ == "__main__":
    unittest.main()
