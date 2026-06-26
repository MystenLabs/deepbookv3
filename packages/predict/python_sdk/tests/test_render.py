import unittest

from predict_sdk.observability import (
    CadenceTimeline,
    MarketStatus,
    OracleFeedStatus,
    OracleStatus,
    PoolStatus,
    PredictStatusReport,
    TimelineSlot,
)
from predict_sdk.render import render_dashboard

NOW_MS = 1_800_000_000_000  # exactly on a 5m boundary
PERIOD = 300_000
POOL_ID = "0xfde98c636eb8a7aba59c3a238cfee6b576b7118d1e5ffa2952876c4b270a3a2a"
LIVE_ID = "0x1111111111111111111111111111111111111111111111111111111111111111"
PREV_ID = "0x2222222222222222222222222222222222222222222222222222222222222222"


def _market(market_id, expiry, *, settled=False, blockers=None, settlement_price=None):
    return MarketStatus(
        market_id=market_id,
        propbook_underlying_id=1,
        expiry_ms=expiry,
        time_to_expiry_ms=expiry - NOW_MS,
        mint_paused=False,
        settled=settled,
        tick_size=1_000_000_000,
        blockers=blockers or [],
        settlement_price=settlement_price,
    )


def _feeds(fresh=True):
    # latest slightly AHEAD of now models the real sub-second clock skew we observed
    return (
        OracleFeedStatus("pyth", NOW_MS + 500, 2_000, fresh, None if fresh else "pyth stale"),
        OracleFeedStatus("block_scholes", NOW_MS + 300, 3_000, True, None),
    )


def _report(*, cadences, blockers=None, oracle_feeds=None, is_live=True, is_mintable=True):
    oracle = OracleStatus("BTC_USD", 1, oracle_feeds or _feeds())
    live_market = _market(LIVE_ID, NOW_MS + PERIOD)
    prev_market = _market(PREV_ID, NOW_MS, blockers=["market is expired"])
    pool = PoolStatus(POOL_ID, 19_990_000_000, 0, 20_000_000_000, (LIVE_ID, PREV_ID))
    return PredictStatusReport(
        network="testnet",
        chain_id="4c78adac",
        asset="BTC_USD",
        protocol_config_id="0xcfg",
        pool_vault_id=POOL_ID,
        is_live=is_live,
        is_mintable=is_mintable,
        blockers=blockers or [],
        oracle=oracle,
        pool=pool,
        markets=[live_market, prev_market],
        cadences=cadences,
    )


def _five_minute_timeline(*, live=True):
    live_market = _market(LIVE_ID, NOW_MS + PERIOD)
    prev_market = _market(PREV_ID, NOW_MS, blockers=["market is expired"])
    slots = (
        TimelineSlot(NOW_MS - PERIOD, -2, "expired_gone", None),
        TimelineSlot(NOW_MS, -1, "awaiting_settle", prev_market),
        TimelineSlot(NOW_MS + PERIOD, 0, "live" if live else "missing_live", live_market if live else None),
        TimelineSlot(NOW_MS + 2 * PERIOD, 1, "pending", None),
        TimelineSlot(NOW_MS + 3 * PERIOD, 2, "pending", None),
    )
    return CadenceTimeline(1, "5m", PERIOD, 3, 1_000_000_000, slots, backlog_count=0)


class RenderTests(unittest.TestCase):
    def test_live_dashboard_shows_cadence_timeline(self) -> None:
        out = render_dashboard(_report(cadences=[_five_minute_timeline()]), NOW_MS, color=False)

        self.assertIn("PREDICT", out)
        self.assertIn("● LIVE", out)
        self.assertIn("5m", out)
        self.assertIn("19,990.00", out)    # pool idle balance (2 decimals)
        self.assertIn("awaiting settle", out)
        self.assertIn("not created", out)  # pending future slots
        self.assertIn("5m 00s", out)       # live countdown (ttl == one period)

    def test_settled_box_shows_price(self) -> None:
        settled_market = MarketStatus(
            PREV_ID, 1, NOW_MS - PERIOD, -PERIOD, False, True, 1_000_000_000,
            ["market is settled"], settlement_price=64_300_000_000_000,  # 64,300 in 1e9 scaling
        )
        slots = (
            TimelineSlot(NOW_MS - 2 * PERIOD, -2, "expired_gone", None),
            TimelineSlot(NOW_MS - PERIOD, -1, "settled", settled_market),
            TimelineSlot(NOW_MS + PERIOD, 0, "live", _market(LIVE_ID, NOW_MS + PERIOD)),
            TimelineSlot(NOW_MS + 2 * PERIOD, 1, "pending", None),
            TimelineSlot(NOW_MS + 3 * PERIOD, 2, "pending", None),
        )
        cadence = CadenceTimeline(1, "5m", PERIOD, 3, 1_000_000_000, slots, backlog_count=0)
        out = render_dashboard(_report(cadences=[cadence]), NOW_MS, color=False)

        self.assertIn("@ 64,300", out)

    def test_no_live_market_verdict(self) -> None:
        out = render_dashboard(
            _report(cadences=[_five_minute_timeline(live=False)], is_mintable=False),
            NOW_MS,
            color=False,
        )
        self.assertIn("NO LIVE MARKETS", out)

    def test_blockers_box_excludes_oracle_blockers(self) -> None:
        report = _report(
            cadences=[_five_minute_timeline()],
            blockers=["protocol trading is paused", "pyth stale"],
            oracle_feeds=_feeds(fresh=False),
            is_live=False,
            is_mintable=False,
        )
        out = render_dashboard(report, NOW_MS, color=False)

        self.assertIn("protocol trading is paused", out)
        # oracle staleness lives only in the ORACLE panel, not the BLOCKERS box
        self.assertNotIn("• pyth stale", out)

    def test_clock_skew_note_when_oracle_ahead(self) -> None:
        # pyth latest is 500 ms ahead of now -> behind-by note, not "in future"
        out = render_dashboard(_report(cadences=[_five_minute_timeline()]), NOW_MS, color=False)
        self.assertIn("local clock", out)
        self.assertIn("just now", out)
        self.assertNotIn("in future", out)

    def test_color_toggles_ansi(self) -> None:
        cadences = [_five_minute_timeline()]
        self.assertNotIn("\x1b[", render_dashboard(_report(cadences=cadences), NOW_MS, color=False))
        self.assertIn("\x1b[", render_dashboard(_report(cadences=cadences), NOW_MS, color=True))


if __name__ == "__main__":
    unittest.main()
