import unittest
from dataclasses import dataclass, field

from predict_sdk.observability import MarketStatus
from predict_sdk.strategy import (
    ONE,
    Engine,
    RangeAroundSpotStrategy,
    RiskLimits,
    TradeIntent,
    make_price_fn,
    min_quantity_for_premium,
    snap_to_grid,
)
from predict_sdk.tx import TxResult

# Offline tests: every dependency the strategy/engine touches is stubbed. No network,
# no keys. Expected values are hand-derived (never read back from the contract code).

NOW_MS = 1_800_000_000_000
PKG = "0xpkg"
MID_A = "0x" + "a" * 64
MID_B = "0x" + "b" * 64
MIN_NET_PREMIUM = 1_000_000  # 1 DUSDC (independently restated, not imported from the impl)


# === stubs ===


@dataclass
class FakeReport:
    """Stand-in for PredictStatusReport: the strategy only reads `.markets`."""

    markets: list


@dataclass
class FakePortfolio:
    open_count: int = 0
    open_premium: int = 0


class FakeObservability:
    def __init__(self, markets):
        self.markets = markets
        self.status_calls = 0

    def status(self, asset="BTC_USD", now_ms=None):
        self.status_calls += 1
        return FakeReport(markets=self.markets)


class FakeActions:
    """Canned mint: returns an OrderMinted whose premium follows the chain's formula.

    net_premium = entry_probability/ONE * quantity / leverage  (the relation the
    sizing/band logic relies on), so tests exercise realistic numbers.
    """

    def __init__(self, *, entry_probability, portfolio=None):
        self.entry_probability = entry_probability
        self._portfolio = portfolio or FakePortfolio()
        self.dry_run_mints = []
        self.executed_mints = []

    def portfolio(self):
        return self._portfolio

    def mint(
        self,
        market_id,
        *,
        lower_tick,
        higher_tick,
        quantity,
        leverage,
        max_cost,
        max_probability,
        execute=False,
    ):
        record = {
            "market_id": market_id,
            "lower_tick": lower_tick,
            "higher_tick": higher_tick,
            "quantity": quantity,
            "leverage": leverage,
            "max_cost": max_cost,
            "max_probability": max_probability,
        }
        (self.executed_mints if execute else self.dry_run_mints).append(record)
        net_premium = self.entry_probability * quantity // (ONE * leverage)
        event = {
            "type": f"{PKG}::order_events::OrderMinted",
            "parsedJson": {
                "entry_probability": str(self.entry_probability),
                "net_premium": str(net_premium),
                "lower_tick": str(lower_tick),
                "higher_tick": str(higher_tick),
                "quantity": str(quantity),
            },
        }
        return TxResult(
            dry_run=not execute, success=True, status="success", events=[event]
        )


@dataclass
class FixedStrategy:
    """Returns a preset intent list, to exercise the engine's caps independent of pricing."""

    intents: list = field(default_factory=list)
    decide_calls: int = 0

    def decide(self, context):
        self.decide_calls += 1
        return list(self.intents)


def make_market(market_id, *, reference_tick, time_to_expiry_ms, blockers=()):
    return MarketStatus(
        market_id=market_id,
        propbook_underlying_id=1,
        expiry_ms=NOW_MS + time_to_expiry_ms,
        time_to_expiry_ms=time_to_expiry_ms,
        mint_paused=False,
        settled=False,
        cash_balance=100_000_000,
        payout_liability=0,
        rebate_reserve=0,
        tick_size=1_000_000_000,
        blockers=list(blockers),
        reference_tick=reference_tick,
    )


def make_context(markets, actions, portfolio=None):
    from predict_sdk.strategy import StrategyContext

    return StrategyContext(
        report=FakeReport(markets=markets),
        portfolio=portfolio or FakePortfolio(),
        price=make_price_fn(actions),
        now_ms=NOW_MS,
    )


def make_intent(market_id, *, quantity, leverage=1):
    return TradeIntent(
        market_id=market_id,
        lower_tick=64_220,
        higher_tick=64_280,
        quantity=quantity,
        leverage=leverage,
        max_cost=2**64 - 1,
        max_probability=ONE,
    )


# === pure helpers ===


class HelperTests(unittest.TestCase):
    def test_snap_to_grid_rounds_to_nearest_multiple(self):
        # 64253 -> 64250 (rounds down), 64256 -> 64260 (rounds up), step-1 is a no-op.
        self.assertEqual(snap_to_grid(64_253, 10), 64_250)
        self.assertEqual(snap_to_grid(64_256, 10), 64_260)
        self.assertEqual(snap_to_grid(64_255, 10), 64_260)  # half rounds up
        self.assertEqual(snap_to_grid(64_257, 1), 64_257)

    def test_min_quantity_for_premium_is_independently_correct(self):
        # ceil(1_000_000 * 1 * 1e9 / 150_000_000) = ceil(6_666_666.67) = 6_666_667
        self.assertEqual(min_quantity_for_premium(150_000_000, 1), 6_666_667)
        # ceil(1_000_000 * 2 * 1e9 / 150_000_000) = ceil(13_333_333.33) = 13_333_334
        self.assertEqual(min_quantity_for_premium(150_000_000, 2), 13_333_334)

    def test_min_quantity_actually_clears_the_minimum_premium(self):
        prob = 150_000_000  # 0.15
        qty = min_quantity_for_premium(prob, 1)
        net_premium = prob * qty // (ONE * 1)
        self.assertGreaterEqual(net_premium, MIN_NET_PREMIUM)
        # one unit smaller would fall short
        self.assertLess(prob * (qty - 1) // ONE, MIN_NET_PREMIUM)


# === RangeAroundSpotStrategy ===


class RangeStrategyTests(unittest.TestCase):
    def test_proposes_grid_aligned_range_around_reference(self):
        actions = FakeActions(entry_probability=500_000_000)  # 0.5, inside band
        market = make_market(MID_A, reference_tick=64_250, time_to_expiry_ms=300_000)
        strategy = RangeAroundSpotStrategy(half_width_ticks=30)

        intents = strategy.decide(make_context([market], actions))

        self.assertEqual(len(intents), 1)
        intent = intents[0]
        # 64250 +/- 30, both on the 10-tick grid (hand-derived).
        self.assertEqual(intent.lower_tick, 64_220)
        self.assertEqual(intent.higher_tick, 64_280)
        self.assertEqual(intent.lower_tick % 10, 0)
        self.assertEqual(intent.higher_tick % 10, 0)
        self.assertEqual(intent.market_id, MID_A)

    def test_snaps_unaligned_reference_and_halfwidth_to_grid(self):
        actions = FakeActions(entry_probability=500_000_000)
        market = make_market(MID_A, reference_tick=64_253, time_to_expiry_ms=300_000)
        strategy = RangeAroundSpotStrategy(half_width_ticks=24)

        intent = strategy.decide(make_context([market], actions))[0]

        # center = snap(64253,10) = 64250; half = snap(24,10) = 20 -> [64230, 64270]
        self.assertEqual(intent.lower_tick, 64_230)
        self.assertEqual(intent.higher_tick, 64_270)

    def test_sets_slippage_capped_execution_limits(self):
        actions = FakeActions(entry_probability=500_000_000)
        market = make_market(MID_A, reference_tick=64_250, time_to_expiry_ms=300_000)
        strategy = RangeAroundSpotStrategy(half_width_ticks=30, slippage_bps=100)

        intent = strategy.decide(make_context([market], actions))[0]

        # quantity = notional (100 DUSDC) since it exceeds the min-premium floor.
        self.assertEqual(intent.quantity, 100_000_000)
        # net_premium = 0.5 * 100_000_000 = 50_000_000; +1% slippage -> 50_500_000
        self.assertEqual(intent.max_cost, 50_500_000)
        # entry 500_000_000; +1% -> 505_000_000 (below ONE)
        self.assertEqual(intent.max_probability, 505_000_000)

    def test_skips_when_probability_above_band(self):
        actions = FakeActions(entry_probability=950_000_000)  # 0.95 > 0.85
        market = make_market(MID_A, reference_tick=64_250, time_to_expiry_ms=300_000)
        strategy = RangeAroundSpotStrategy()

        self.assertEqual(strategy.decide(make_context([market], actions)), [])

    def test_skips_when_probability_below_band(self):
        actions = FakeActions(entry_probability=50_000_000)  # 0.05 < 0.15
        market = make_market(MID_A, reference_tick=64_250, time_to_expiry_ms=300_000)
        strategy = RangeAroundSpotStrategy()

        self.assertEqual(strategy.decide(make_context([market], actions)), [])

    def test_picks_longest_runway_mintable_market(self):
        actions = FakeActions(entry_probability=500_000_000)
        markets = [
            make_market(MID_A, reference_tick=64_250, time_to_expiry_ms=60_000),
            make_market(MID_B, reference_tick=70_000, time_to_expiry_ms=600_000),
        ]
        strategy = RangeAroundSpotStrategy(half_width_ticks=30)

        intent = strategy.decide(make_context(markets, actions))[0]

        self.assertEqual(intent.market_id, MID_B)

    def test_ignores_non_mintable_market_even_with_more_runway(self):
        actions = FakeActions(entry_probability=500_000_000)
        markets = [
            make_market(MID_A, reference_tick=64_250, time_to_expiry_ms=60_000),
            make_market(
                MID_B,
                reference_tick=70_000,
                time_to_expiry_ms=600_000,
                blockers=["market minting is paused"],
            ),
        ]
        strategy = RangeAroundSpotStrategy(half_width_ticks=30)

        intent = strategy.decide(make_context(markets, actions))[0]

        self.assertEqual(intent.market_id, MID_A)

    def test_skips_market_without_reference_tick(self):
        actions = FakeActions(entry_probability=500_000_000)
        market = make_market(MID_A, reference_tick=None, time_to_expiry_ms=300_000)
        strategy = RangeAroundSpotStrategy()

        self.assertEqual(strategy.decide(make_context([market], actions)), [])

    def test_bumps_quantity_to_clear_min_net_premium(self):
        # Tiny notional must be overridden so the priced premium clears the minimum.
        actions = FakeActions(entry_probability=150_000_000)  # 0.15 == band low (inclusive)
        market = make_market(MID_A, reference_tick=64_250, time_to_expiry_ms=300_000)
        strategy = RangeAroundSpotStrategy(half_width_ticks=30, notional=1_000, leverage=1)

        intent = strategy.decide(make_context([market], actions))[0]

        self.assertEqual(intent.quantity, 6_666_667)  # not the 1_000 notional
        priced_premium = 150_000_000 * intent.quantity // (ONE * 1)
        self.assertGreaterEqual(priced_premium, MIN_NET_PREMIUM)


# === Engine ===


class EngineTests(unittest.TestCase):
    def _engine(self, *, markets, actions, strategy, limits=None):
        return Engine(
            actions, FakeObservability(markets), strategy, limits=limits
        )

    def test_run_once_prices_and_plans_when_within_caps(self):
        actions = FakeActions(entry_probability=500_000_000)
        market = make_market(MID_A, reference_tick=64_250, time_to_expiry_ms=300_000)
        strategy = RangeAroundSpotStrategy(half_width_ticks=30)
        engine = self._engine(markets=[market], actions=actions, strategy=strategy)

        run = engine.run_once(execute=False)

        self.assertEqual(len(run.proposed), 1)
        self.assertEqual(len(run.planned), 1)
        self.assertEqual(run.skipped, [])
        self.assertEqual(run.planned[0].quote.net_premium, 50_000_000)
        self.assertFalse(run.planned[0].executed)
        self.assertEqual(actions.executed_mints, [])  # nothing submitted on a dry run

    def test_max_open_positions_blocks_new_trades(self):
        actions = FakeActions(entry_probability=500_000_000)
        market = make_market(MID_A, reference_tick=64_250, time_to_expiry_ms=300_000)
        strategy = RangeAroundSpotStrategy(half_width_ticks=30)
        limits = RiskLimits(max_open_positions=3, max_total_premium=10**18)
        # Portfolio already at the cap -> the proposed intent must be skipped.
        actions._portfolio = FakePortfolio(open_count=3, open_premium=0)
        engine = self._engine(
            markets=[market], actions=actions, strategy=strategy, limits=limits
        )

        run = engine.run_once(execute=False)

        self.assertEqual(run.planned, [])
        self.assertEqual(len(run.skipped), 1)
        self.assertEqual(run.skipped[0][1], "max open positions reached")

    def test_max_open_positions_accepts_up_to_cap_then_skips(self):
        actions = FakeActions(entry_probability=500_000_000)
        market = make_market(MID_A, reference_tick=64_250, time_to_expiry_ms=300_000)
        intents = [make_intent(MID_A, quantity=100_000_000) for _ in range(3)]
        strategy = FixedStrategy(intents=intents)
        limits = RiskLimits(max_open_positions=2, max_total_premium=10**18)
        engine = self._engine(
            markets=[market], actions=actions, strategy=strategy, limits=limits
        )

        run = engine.run_once(execute=False)

        self.assertEqual(len(run.planned), 2)
        self.assertEqual(len(run.skipped), 1)
        self.assertEqual(run.skipped[0][1], "max open positions reached")

    def test_max_total_premium_blocks_over_budget_trades(self):
        actions = FakeActions(entry_probability=500_000_000)
        market = make_market(MID_A, reference_tick=64_250, time_to_expiry_ms=300_000)
        # Each intent prices to 0.5 * 100_000_000 = 50_000_000 premium.
        intents = [make_intent(MID_A, quantity=100_000_000) for _ in range(3)]
        strategy = FixedStrategy(intents=intents)
        # Budget admits two (100_000_000) but not the third (would reach 150_000_000).
        limits = RiskLimits(max_open_positions=10, max_total_premium=120_000_000)
        engine = self._engine(
            markets=[market], actions=actions, strategy=strategy, limits=limits
        )

        run = engine.run_once(execute=False)

        self.assertEqual(len(run.planned), 2)
        self.assertEqual(len(run.skipped), 1)
        self.assertEqual(run.skipped[0][1], "max total premium reached")

    def test_existing_open_premium_counts_against_budget(self):
        actions = FakeActions(entry_probability=500_000_000)
        market = make_market(MID_A, reference_tick=64_250, time_to_expiry_ms=300_000)
        intents = [make_intent(MID_A, quantity=100_000_000)]  # 50_000_000 premium
        strategy = FixedStrategy(intents=intents)
        actions._portfolio = FakePortfolio(open_count=0, open_premium=80_000_000)
        limits = RiskLimits(max_open_positions=10, max_total_premium=120_000_000)
        engine = self._engine(
            markets=[market], actions=actions, strategy=strategy, limits=limits
        )

        run = engine.run_once(execute=False)

        # 80M already open + 50M new = 130M > 120M cap -> skip.
        self.assertEqual(run.planned, [])
        self.assertEqual(run.skipped[0][1], "max total premium reached")

    def test_execute_submits_with_intent_slippage_caps(self):
        actions = FakeActions(entry_probability=500_000_000)
        market = make_market(MID_A, reference_tick=64_250, time_to_expiry_ms=300_000)
        strategy = RangeAroundSpotStrategy(half_width_ticks=30, slippage_bps=100)
        engine = self._engine(markets=[market], actions=actions, strategy=strategy)

        run = engine.run_once(execute=True)

        self.assertEqual(len(run.planned), 1)
        self.assertTrue(run.planned[0].executed)
        self.assertEqual(len(actions.executed_mints), 1)
        submitted = actions.executed_mints[0]
        self.assertEqual(submitted["max_cost"], 50_500_000)
        self.assertEqual(submitted["max_probability"], 505_000_000)
        self.assertEqual(submitted["lower_tick"], 64_220)
        self.assertEqual(submitted["higher_tick"], 64_280)

    def test_run_forever_is_a_thin_bounded_loop(self):
        actions = FakeActions(entry_probability=500_000_000)
        market = make_market(MID_A, reference_tick=64_250, time_to_expiry_ms=300_000)
        observability = FakeObservability([market])
        strategy = FixedStrategy(intents=[])
        engine = Engine(actions, observability, strategy)

        engine.run_forever(interval_s=0, max_iterations=3)

        self.assertEqual(observability.status_calls, 3)
        self.assertEqual(strategy.decide_calls, 3)


if __name__ == "__main__":
    unittest.main()
