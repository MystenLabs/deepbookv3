import asyncio
import unittest

from predict_sdk import dashboard
from predict_sdk.constants import POS_INF_TICK
from predict_sdk.observability import (
    CadenceTimeline,
    MarketStatus,
    OracleFeedStatus,
    OracleStatus,
    PoolStatus,
    PredictStatusReport,
    TimelineSlot,
)
from predict_sdk.portfolio import Portfolio, Position

NOW_MS = 1_800_000_000_000
PERIOD = 300_000
ADDR = "0x" + "ab" * 32  # 66-char account id
MARKET_ID = "0x" + "cd" * 32


def _position(*, quantity, open_quantity, net_premium, lower=64_000, higher=64_500,
              entry=985_009_513, opened_offset_ms=3_600_000):
    return Position(
        position_root_id="0xroot",
        order_id="0x1",
        market_id=MARKET_ID,
        lower_tick=lower,
        higher_tick=higher,
        leverage=1_000_000_000,
        quantity=quantity,
        open_quantity=open_quantity,
        entry_probability=entry,
        net_premium=net_premium,
        mint_fees=0,
        opened_ms=NOW_MS - opened_offset_ms,
    )


def _portfolio(positions, *, realized_pnl=12_340_000, premium_paid=200_000_000,
               proceeds=150_000_000, closed_count=2):
    return Portfolio(
        manager_id=ADDR,
        positions=list(positions),
        realized_pnl=realized_pnl,
        premium_paid=premium_paid,
        proceeds=proceeds,
        fees_paid=0,
        closed_count=closed_count,
    )


def _report(*, is_live=True, is_mintable=True, oracle_fresh=True, live_slots=1):
    feeds = (
        OracleFeedStatus("pyth", NOW_MS + 500, 2_000, oracle_fresh,
                         None if oracle_fresh else "pyth stale"),
    )
    oracle = OracleStatus("BTC_USD", 1, feeds)
    market = MarketStatus(
        market_id=MARKET_ID, propbook_underlying_id=1, expiry_ms=NOW_MS + PERIOD,
        time_to_expiry_ms=PERIOD, mint_paused=False, settled=False,
        tick_size=1_000_000_000, blockers=[],
    )
    pool = PoolStatus("0xpool", 0, 0, 0, (MARKET_ID,))
    slots = tuple(
        TimelineSlot(NOW_MS + PERIOD, 0, "live" if i < live_slots else "pending", market)
        for i in range(1)
    )
    cadence = CadenceTimeline(1, "5m", PERIOD, 3, 1_000_000_000, slots, backlog_count=0)
    return PredictStatusReport(
        network="testnet", chain_id="4c78adac", asset="BTC_USD",
        protocol_config_id="0xcfg", pool_vault_id="0xpool",
        is_live=is_live, is_mintable=is_mintable, blockers=[],
        oracle=oracle, pool=pool, markets=[market], cadences=[cadence],
    )


class FormattingTests(unittest.TestCase):
    def test_money_truncates_to_two_decimals(self):
        self.assertEqual(dashboard.fmt_money(98_500_000), "98.50")

    def test_money_groups_thousands(self):
        self.assertEqual(dashboard.fmt_money(1_234_567_890), "1,234.56")

    def test_money_negative(self):
        self.assertEqual(dashboard.fmt_money(-5_000_000), "-5.00")

    def test_money_none_is_em_dash(self):
        self.assertEqual(dashboard.fmt_money(None), "—")

    def test_sui_uses_nine_decimals(self):
        self.assertEqual(dashboard.fmt_sui(1_500_000_000), "1.5000")

    def test_signed_money_positive_gets_plus(self):
        self.assertEqual(dashboard.fmt_signed_money(12_340_000), "+12.34")

    def test_signed_money_negative_keeps_minus(self):
        self.assertEqual(dashboard.fmt_signed_money(-12_340_000), "-12.34")

    def test_signed_money_zero_has_no_sign(self):
        self.assertEqual(dashboard.fmt_signed_money(0), "0.00")

    def test_prob_one_decimal_percent(self):
        self.assertEqual(dashboard.fmt_prob(985_009_513), "98.5%")

    def test_prob_half(self):
        self.assertEqual(dashboard.fmt_prob(500_000_000), "50.0%")

    def test_prob_none(self):
        self.assertEqual(dashboard.fmt_prob(None), "—")

    def test_ticks_bounded_range(self):
        self.assertEqual(dashboard.fmt_ticks(64_000, 64_500), "64000 → 64500")

    def test_ticks_open_upper_bound(self):
        self.assertEqual(dashboard.fmt_ticks(64_000, POS_INF_TICK), "64000 → ∞")

    def test_age_seconds_minutes_hours_days(self):
        self.assertEqual(dashboard.fmt_age(NOW_MS - 5_000, NOW_MS), "5s")
        self.assertEqual(dashboard.fmt_age(NOW_MS - 120_000, NOW_MS), "2m")
        self.assertEqual(dashboard.fmt_age(NOW_MS - 3_660_000, NOW_MS), "1h 01m")
        self.assertEqual(dashboard.fmt_age(NOW_MS - 90_000_000, NOW_MS), "1d 01h")

    def test_age_future_clamps_to_zero(self):
        self.assertEqual(dashboard.fmt_age(NOW_MS + 5_000, NOW_MS), "0s")

    def test_short_id_abbreviates(self):
        out = dashboard.short_id(ADDR)
        self.assertIn("…", out)
        self.assertTrue(out.startswith("0xababab"))
        self.assertTrue(out.endswith("ababab"[-5:]))

    def test_short_id_passthrough_when_short(self):
        self.assertEqual(dashboard.short_id("0xabcd"), "0xabcd")


class PnlColorTests(unittest.TestCase):
    def test_gain_is_green(self):
        self.assertEqual(dashboard.pnl_color(1), "green")

    def test_loss_is_red(self):
        self.assertEqual(dashboard.pnl_color(-1), "red")

    def test_flat_is_dim(self):
        self.assertEqual(dashboard.pnl_color(0), "dim")

    def test_none_is_dim(self):
        self.assertEqual(dashboard.pnl_color(None), "dim")


class PositionRowTests(unittest.TestCase):
    def test_full_open_position_row(self):
        portfolio = _portfolio([
            _position(quantity=100_000_000, open_quantity=100_000_000, net_premium=80_000_000)
        ])
        rows = dashboard.build_position_rows(portfolio, NOW_MS)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertIn("…", row.market)
        self.assertEqual(row.strike, "64000 → 64500")
        self.assertEqual(row.quantity, "100.00")
        self.assertEqual(row.entry, "98.5%")
        self.assertEqual(row.premium, "80.00")   # full premium for a fully-open position
        self.assertEqual(row.age, "1h 00m")

    def test_partial_close_prorates_premium_and_quantity(self):
        # half closed: open premium = 80.00 * 50/100 = 40.00; open qty = 50.00
        portfolio = _portfolio([
            _position(quantity=100_000_000, open_quantity=50_000_000, net_premium=80_000_000)
        ])
        row = dashboard.build_position_rows(portfolio, NOW_MS)[0]
        self.assertEqual(row.quantity, "50.00")
        self.assertEqual(row.premium, "40.00")

    def test_no_positions_yields_no_rows(self):
        self.assertEqual(dashboard.build_position_rows(_portfolio([]), NOW_MS), [])


class StatusLineTests(unittest.TestCase):
    def test_live_fresh_summary(self):
        status = dashboard.build_status_line(_report())
        self.assertTrue(status.live)
        self.assertTrue(status.mintable)
        self.assertTrue(status.oracle_fresh)
        self.assertEqual(status.summary, "1 markets · 1 live · 1 cadences")

    def test_degraded_stale(self):
        status = dashboard.build_status_line(
            _report(is_live=False, is_mintable=False, oracle_fresh=False, live_slots=0)
        )
        self.assertFalse(status.live)
        self.assertFalse(status.oracle_fresh)
        self.assertEqual(status.summary, "1 markets · 0 live · 1 cadences")


class DashboardDataTests(unittest.TestCase):
    def _data(self):
        portfolio = _portfolio([
            _position(quantity=100_000_000, open_quantity=100_000_000, net_premium=80_000_000),
            _position(quantity=100_000_000, open_quantity=50_000_000, net_premium=80_000_000),
        ])
        return dashboard.build_dashboard_data(
            ADDR, "testnet", 98_500_000, 1_500_000_000, portfolio, _report(), NOW_MS
        )

    def test_assembles_header_and_summary_fields(self):
        data = self._data()
        self.assertEqual(data.network, "testnet")
        self.assertEqual(data.dusdc, "98.50")
        self.assertEqual(data.sui, "1.5000")
        self.assertEqual(data.realized_pnl, "+12.34")
        self.assertEqual(data.realized_color, "green")
        # premium at risk = 80.00 (full) + 40.00 (half of 80.00) = 120.00
        self.assertEqual(data.premium_at_risk, "120.00")
        self.assertEqual(data.open_count, 2)
        self.assertEqual(data.closed_count, 2)
        self.assertEqual(data.premium_paid, "200.00")
        self.assertEqual(data.proceeds, "150.00")
        self.assertIn("…", data.address_short)
        self.assertEqual(len(data.positions), 2)

    def test_loss_colors_red(self):
        portfolio = _portfolio([], realized_pnl=-5_000_000, closed_count=1)
        data = dashboard.build_dashboard_data(
            ADDR, "testnet", 0, 0, portfolio, _report(), NOW_MS
        )
        self.assertEqual(data.realized_pnl, "-5.00")
        self.assertEqual(data.realized_color, "red")


class FriendlyErrorTests(unittest.TestCase):
    def test_run_dashboard_without_textual_raises_friendly_error(self):
        original = dashboard._TEXTUAL_AVAILABLE
        dashboard._TEXTUAL_AVAILABLE = False
        try:
            with self.assertRaises(RuntimeError) as ctx:
                dashboard.run_dashboard(address=ADDR)
            self.assertIn("textual", str(ctx.exception))
        finally:
            dashboard._TEXTUAL_AVAILABLE = original


@unittest.skipUnless(dashboard._TEXTUAL_AVAILABLE, "textual not installed")
class AppConstructionTests(unittest.TestCase):
    def test_app_renders_fixture_data(self):
        portfolio = _portfolio([
            _position(quantity=100_000_000, open_quantity=100_000_000, net_premium=80_000_000),
            _position(quantity=100_000_000, open_quantity=50_000_000, net_premium=80_000_000),
        ])
        data = dashboard.build_dashboard_data(
            ADDR, "testnet", 98_500_000, 1_500_000_000, portfolio, _report(), NOW_MS
        )

        async def scenario():
            app = dashboard.PredictDashboardApp(lambda: data, refresh_s=100)
            async with app.run_test() as pilot:
                for _ in range(100):
                    await pilot.pause()
                    if app.query_one("#positions").row_count:
                        break
                table = app.query_one("#positions")
                self.assertEqual(table.row_count, len(data.positions))

        asyncio.run(scenario())


if __name__ == "__main__":
    unittest.main()
