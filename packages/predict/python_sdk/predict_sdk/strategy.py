from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Protocol

from .constants import DUSDC_DECIMALS, FLOAT_SCALING, U64_MAX
from .observability import ObservabilityClient

if TYPE_CHECKING:  # type-only: keep this module import-light (no nacl/tx/actions at runtime)
    from .actions import PredictActions
    from .observability import MarketStatus, PredictStatusReport
    from .portfolio import Portfolio
    from .tx import TxResult

# Trading-strategy engine for the Predict SDK.
#
# There is no off-chain pricer for Predict. The only way to learn what the chain
# would charge for a candidate range is to DRY-RUN a mint (`execute=False`) and
# read the `OrderMinted` event off the resulting `TxResult`. This module builds on
# that: a `Strategy` turns market context into `TradeIntent`s, and an `Engine`
# gathers context (observability status + portfolio), validates/prices every intent
# with a dry-run, applies risk caps, and optionally submits the survivors.
#
# Money units: probabilities are 1e9-scaled (ONE == 100%); cash amounts (premium,
# max_cost, quantity) are raw 6-dp DUSDC base units.

ONE = FLOAT_SCALING  # 1e9 == probability of 1.0 (matches OrderMinted.entry_probability scale)
MIN_NET_PREMIUM = 10**DUSDC_DECIMALS  # 1 DUSDC: the chain's minimum priced premium for a mint
ORDER_MINTED_SUFFIX = "::order_events::OrderMinted"


# === value types ===


@dataclass(frozen=True)
class TradeIntent:
    """A fully-specified, ready-to-submit mint. The engine prices + caps it before use."""

    market_id: str
    lower_tick: int
    higher_tick: int
    quantity: int  # 6-dp DUSDC base units
    leverage: int
    max_cost: int  # slippage cap on premium paid (6-dp DUSDC)
    max_probability: int  # slippage cap on entry probability (1e9-scaled)


@dataclass(frozen=True)
class Quote:
    """The exact price the chain returned for a candidate, read from a dry-run OrderMinted."""

    market_id: str
    lower_tick: int
    higher_tick: int
    quantity: int
    leverage: int
    entry_probability: int  # 1e9-scaled
    net_premium: int  # 6-dp DUSDC


class PriceFn(Protocol):
    """Prices a candidate range by dry-running a mint and reading its OrderMinted event."""

    def __call__(
        self,
        market_id: str,
        *,
        lower_tick: int,
        higher_tick: int,
        quantity: int,
        leverage: int,
    ) -> Quote | None: ...


@dataclass
class StrategyContext:
    """Everything a strategy needs to decide: market state, holdings, and a pricer."""

    report: "PredictStatusReport"
    portfolio: "Portfolio"
    price: PriceFn
    now_ms: int


class Strategy(Protocol):
    """A strategy maps the current context to zero or more trade intents."""

    def decide(self, context: StrategyContext) -> list[TradeIntent]: ...


# === pricing (dry-run) ===


def _find_order_minted(events: list) -> dict | None:
    for event in events:
        if str(event.get("type", "")).endswith(ORDER_MINTED_SUFFIX):
            return event
    return None


def make_price_fn(actions: "PredictActions") -> PriceFn:
    """Build a PriceFn over `actions`: dry-run a mint with permissive caps, read the price.

    The dry run uses `max_cost=U64_MAX` / `max_probability=ONE` so the chain never
    rejects it for slippage — the goal is pure price discovery. Returns None if the
    dry run fails (e.g. paused market, premium below the minimum) or emits no event.
    """

    def price(
        market_id: str,
        *,
        lower_tick: int,
        higher_tick: int,
        quantity: int,
        leverage: int,
    ) -> Quote | None:
        result = actions.mint(
            market_id,
            lower_tick=lower_tick,
            higher_tick=higher_tick,
            quantity=quantity,
            leverage=leverage,
            max_cost=U64_MAX,
            max_probability=ONE,
            execute=False,
        )
        if not result.success:
            return None
        event = _find_order_minted(result.events)
        if event is None:
            return None
        parsed = event["parsedJson"]
        return Quote(
            market_id=market_id,
            lower_tick=lower_tick,
            higher_tick=higher_tick,
            quantity=quantity,
            leverage=leverage,
            entry_probability=int(parsed["entry_probability"]),
            net_premium=int(parsed["net_premium"]),
        )

    return price


# === sizing / grid helpers ===


def snap_to_grid(tick: int, grid: int) -> int:
    """Round a (non-negative) tick to the nearest multiple of the admission grid step."""
    if grid <= 1:
        return tick
    return ((tick + grid // 2) // grid) * grid


def min_quantity_for_premium(
    prob_scaled: int, leverage: int, min_net_premium: int = MIN_NET_PREMIUM
) -> int:
    """Smallest quantity whose premium clears the chain minimum at a given probability.

    The chain charges roughly `net_premium = prob_scaled/ONE * quantity / leverage`.
    Solving `net_premium >= min_net_premium` for quantity and rounding up:
        quantity >= ceil(min_net_premium * leverage * ONE / prob_scaled)
    Sizing against the band's *lower* probability bound makes this a safe floor: a
    higher realized probability only raises the premium further above the minimum.
    """
    if prob_scaled <= 0:
        raise ValueError("prob_scaled must be positive")
    return (min_net_premium * leverage * ONE + prob_scaled - 1) // prob_scaled


def _apply_slippage(amount: int, slippage_bps: int) -> int:
    """amount * (1 + slippage_bps/1e4), rounded up so the cap never lands below `amount`."""
    return (amount * (10_000 + slippage_bps) + 9_999) // 10_000


# === a concrete demo strategy ===


@dataclass
class RangeAroundSpotStrategy:
    """Propose a symmetric grid-aligned range around spot on the longest-runway market.

    Picks the live, mintable market with the most time to expiry, centers a range of
    `half_width_ticks` (snapped to the admission grid) on the market's `reference_tick`,
    sizes it to `notional` (bumped up if needed to clear the minimum premium), and only
    emits an intent if the dry-run entry probability lands inside `probability_band` —
    skipping near-certain and near-impossible bets where there is no edge to capture.
    """

    half_width_ticks: int = 50
    grid_ticks: int = 10  # admission_tick_size / tick_size; valid finite ticks are multiples of this
    notional: int = 100_000_000  # 100 DUSDC (6-dp base units)
    leverage: int = 1
    probability_band: tuple[float, float] = (0.15, 0.85)
    slippage_bps: int = 100  # 1% slippage allowance on the execution caps

    def decide(self, context: StrategyContext) -> list[TradeIntent]:
        market = self._select_market(context.report)
        if market is None:
            return []

        center = snap_to_grid(market.reference_tick, self.grid_ticks)
        half = max(self.grid_ticks, snap_to_grid(self.half_width_ticks, self.grid_ticks))
        lower, higher = center - half, center + half
        if lower < 0:
            return []  # range would run off the bottom of the tick space

        low_scaled = int(self.probability_band[0] * ONE)
        high_scaled = int(self.probability_band[1] * ONE)
        quantity = max(self.notional, min_quantity_for_premium(low_scaled, self.leverage))

        quote = context.price(
            market.market_id,
            lower_tick=lower,
            higher_tick=higher,
            quantity=quantity,
            leverage=self.leverage,
        )
        if quote is None:
            return []
        if not (low_scaled <= quote.entry_probability <= high_scaled):
            return []  # outside the band: too certain or too unlikely to be worth it

        return [
            TradeIntent(
                market_id=market.market_id,
                lower_tick=lower,
                higher_tick=higher,
                quantity=quantity,
                leverage=self.leverage,
                max_cost=_apply_slippage(quote.net_premium, self.slippage_bps),
                max_probability=min(ONE, _apply_slippage(quote.entry_probability, self.slippage_bps)),
            )
        ]

    def _select_market(self, report: "PredictStatusReport") -> "MarketStatus | None":
        candidates = [
            m
            for m in report.markets
            if m.mintable and m.reference_tick is not None and m.time_to_expiry_ms is not None
        ]
        if not candidates:
            return None
        return max(candidates, key=lambda m: m.time_to_expiry_ms)


# === engine ===


@dataclass
class RiskLimits:
    """Caps applied across a run (and over existing holdings) before any submit."""

    max_open_positions: int = 5
    max_total_premium: int = 1_000 * 10**DUSDC_DECIMALS  # 1,000 DUSDC (6-dp base units)


@dataclass
class PlannedTrade:
    """An intent that cleared pricing + risk caps (and possibly executed)."""

    intent: TradeIntent
    quote: Quote
    executed: bool = False
    result: "TxResult | None" = None


@dataclass
class EngineRun:
    """The outcome of one `run_once`: what the strategy proposed, accepted, and skipped."""

    report: "PredictStatusReport"
    proposed: list[TradeIntent] = field(default_factory=list)
    planned: list[PlannedTrade] = field(default_factory=list)
    skipped: list[tuple[TradeIntent, str]] = field(default_factory=list)


class Engine:
    """Ties a strategy to live context, dry-run pricing, risk caps, and submission."""

    def __init__(
        self,
        actions: "PredictActions",
        observability: ObservabilityClient,
        strategy: Strategy,
        *,
        asset: str = "BTC_USD",
        limits: RiskLimits | None = None,
    ):
        self.actions = actions
        self.observability = observability
        self.strategy = strategy
        self.asset = asset
        self.limits = limits or RiskLimits()
        self.price = make_price_fn(actions)

    @classmethod
    def from_actions(
        cls,
        actions: "PredictActions",
        reader,
        strategy: Strategy,
        **kwargs,
    ) -> "Engine":
        """Convenience constructor: wire an ObservabilityClient from `actions.config`."""
        return cls(actions, ObservabilityClient(actions.config, reader), strategy, **kwargs)

    def run_once(self, *, execute: bool = False, now_ms: int | None = None) -> EngineRun:
        """Gather context, ask the strategy, then price + cap (+ optionally submit) each intent."""
        now_ms = _now_ms() if now_ms is None else now_ms
        report = self.observability.status(self.asset, now_ms=now_ms)
        portfolio = self.actions.portfolio()
        context = StrategyContext(
            report=report, portfolio=portfolio, price=self.price, now_ms=now_ms
        )
        proposed = self.strategy.decide(context)

        run = EngineRun(report=report, proposed=proposed)
        open_count = portfolio.open_count
        committed_premium = portfolio.open_premium
        for intent in proposed:
            if open_count >= self.limits.max_open_positions:
                run.skipped.append((intent, "max open positions reached"))
                continue
            # Authoritative price + validation: re-run the exact intent on-chain (dry).
            quote = self.price(
                intent.market_id,
                lower_tick=intent.lower_tick,
                higher_tick=intent.higher_tick,
                quantity=intent.quantity,
                leverage=intent.leverage,
            )
            if quote is None:
                run.skipped.append((intent, "dry-run validation failed"))
                continue
            if committed_premium + quote.net_premium > self.limits.max_total_premium:
                run.skipped.append((intent, "max total premium reached"))
                continue

            result = None
            executed = False
            if execute:
                result = self.actions.mint(
                    intent.market_id,
                    lower_tick=intent.lower_tick,
                    higher_tick=intent.higher_tick,
                    quantity=intent.quantity,
                    leverage=intent.leverage,
                    max_cost=intent.max_cost,
                    max_probability=intent.max_probability,
                    execute=True,
                )
                executed = result.success
            run.planned.append(
                PlannedTrade(intent=intent, quote=quote, executed=executed, result=result)
            )
            open_count += 1
            committed_premium += quote.net_premium
        return run

    def run_forever(
        self,
        interval_s: float,
        *,
        execute: bool = False,
        max_iterations: int | None = None,
    ) -> None:
        """Thin loop over `run_once`. `max_iterations=None` runs until interrupted."""
        iterations = 0
        while max_iterations is None or iterations < max_iterations:
            self.run_once(execute=execute)
            iterations += 1
            if max_iterations is None or iterations < max_iterations:
                time.sleep(interval_s)


def _now_ms() -> int:
    return int(time.time() * 1000)
