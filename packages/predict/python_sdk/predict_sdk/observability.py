from __future__ import annotations

import time
from dataclasses import dataclass
from decimal import Decimal

from .config import CadenceConfig, DeploymentConfig
from .indexer import OracleClient, PredictIndexerClient

# Status report assembled entirely from the indexer data plane: the predict-server
# (markets / market-state / vault-state / config) and the oracle service (latest
# pyth + block-scholes for freshness). No chain reads — mintability is ultimately
# enforced by the chain dry-run, so a slightly-stale read can never cause a bad write.


@dataclass(frozen=True)
class OracleFeedStatus:
    name: str
    latest_source_timestamp_ms: int | None
    freshness_ms: int | None
    fresh: bool
    blocker: str | None


@dataclass(frozen=True)
class OracleStatus:
    asset: str
    propbook_underlying_id: int
    feeds: tuple[OracleFeedStatus, ...]

    @property
    def fresh(self) -> bool:
        return all(feed.fresh for feed in self.feeds)

    @property
    def blockers(self) -> list[str]:
        return [feed.blocker for feed in self.feeds if feed.blocker is not None]


@dataclass(frozen=True)
class PoolStatus:
    pool_vault_id: str
    idle_balance: int | None
    protocol_reserve_balance: int | None
    plp_total_supply: int | None
    active_market_ids: tuple[str, ...]

    @property
    def active_market_count(self) -> int:
        return len(self.active_market_ids)


@dataclass(frozen=True)
class MarketStatus:
    market_id: str
    propbook_underlying_id: int | None
    expiry_ms: int | None
    time_to_expiry_ms: int | None
    mint_paused: bool | None
    settled: bool
    tick_size: int | None
    blockers: list[str]
    settlement_price: int | None = None

    @property
    def mintable(self) -> bool:
        return len(self.blockers) == 0


@dataclass(frozen=True)
class TimelineSlot:
    # expiry timestamp of this cadence slot, computed deterministically from now + period
    expiry_ms: int
    # slot offset relative to the live slot: -2,-1 past · 0 live · +1,+2 upcoming
    position: int
    # live | scheduled | awaiting_settle | settled | expired_gone | missing_live | pending
    state: str
    market: MarketStatus | None


@dataclass(frozen=True)
class CadenceTimeline:
    cadence_id: int
    name: str
    period_ms: int
    window_size: int
    tick_size: int
    slots: tuple[TimelineSlot, ...]
    # markets owned by this cadence that fall outside the displayed slot window
    backlog_count: int

    @property
    def has_live_market(self) -> bool:
        return any(slot.state == "live" for slot in self.slots)


@dataclass(frozen=True)
class PredictStatusReport:
    network: str
    chain_id: str
    asset: str
    protocol_config_id: str
    pool_vault_id: str
    is_live: bool
    is_mintable: bool
    blockers: list[str]
    oracle: OracleStatus
    pool: PoolStatus
    markets: list[MarketStatus]
    cadences: list[CadenceTimeline]

    @property
    def mintable_market_ids(self) -> list[str]:
        return [market.market_id for market in self.markets if market.mintable]

    @property
    def has_live_market(self) -> bool:
        return any(cadence.has_live_market for cadence in self.cadences)


class ObservabilityClient:
    def __init__(self, config: DeploymentConfig, *, transport=None):
        self.config = config
        # Same injected transport serves both clients (it dispatches by URL); in
        # production each defaults to the stdlib GET against its own base URL.
        self.predict = PredictIndexerClient(config.server_url("predict") or "", transport=transport)
        self.oracle = OracleClient(config.server_url("propbook") or "", transport=transport)

    def status(self, asset: str = "BTC_USD", now_ms: int | None = None) -> PredictStatusReport:
        now_ms = _now_ms() if now_ms is None else now_ms
        asset_config = self.config.asset(asset)
        protocol_config_id = self.config.shared_object_id("predict", "protocol_config::ProtocolConfig")
        pool_vault_id = self.config.shared_object_id("predict", "plp::PoolVault")

        blockers: list[str] = []
        config_json = self.predict.protocol_config()
        if not config_json:
            blockers.append("protocol config unavailable")
        elif _get(config_json, "trading_paused", "paused"):
            blockers.append("protocol trading is paused")
        pricing = (config_json or {}).get("pricing") or {}
        oracle = self._oracle_status(
            asset, asset_config.propbook_underlying_id, now_ms,
            _num(pricing.get("pyth_spot_freshness_ms")),
            _num(pricing.get("block_scholes_surface_freshness_ms")),
        )
        blockers.extend(oracle.blockers)

        cadences = _resolve_cadences(self.config)
        slot_expiries = _all_slot_expiries(cadences, now_ms)

        created = self.predict.markets(limit=100)
        created_by_expiry = {
            int(row["expiry"]): row for row in created if row.get("expiry") is not None
        }
        markets = [
            self._market_status(row, asset_config.propbook_underlying_id, oracle.blockers, now_ms)
            for expiry, row in sorted(created_by_expiry.items())
            if expiry in slot_expiries
        ]

        vault = self.predict.vault_state(pool_vault_id)
        current = vault.get("current") or {}
        pool = PoolStatus(
            pool_vault_id=pool_vault_id,
            idle_balance=_num(current.get("idle_balance_after")),
            protocol_reserve_balance=_num(current.get("protocol_reserve_balance_after")),
            plp_total_supply=_num(current.get("total_supply")),
            active_market_ids=tuple(m.market_id for m in markets),
        )

        cadence_timelines = _build_cadence_timelines(cadences, markets, set(created_by_expiry), now_ms)
        is_mintable = any(market.mintable for market in markets) and not blockers
        is_live = not blockers

        return PredictStatusReport(
            network=self.config.network,
            chain_id=self.config.chain_id,
            asset=asset,
            protocol_config_id=protocol_config_id,
            pool_vault_id=pool_vault_id,
            is_live=is_live,
            is_mintable=is_mintable,
            blockers=blockers,
            oracle=oracle,
            pool=pool,
            markets=markets,
            cadences=cadence_timelines,
        )

    def _oracle_status(
        self,
        asset: str,
        underlying_id: int,
        now_ms: int,
        pyth_freshness_ms: int | None,
        bs_freshness_ms: int | None,
    ) -> OracleStatus:
        binding = self.oracle.underlying_binding(underlying_id)
        oracle_id = binding.get("propbook_oracle_id") if binding else None
        if not oracle_id:
            feeds = (
                OracleFeedStatus("pyth", None, pyth_freshness_ms, False, "oracle binding unavailable"),
                OracleFeedStatus("block_scholes", None, bs_freshness_ms, False, "oracle binding unavailable"),
            )
        else:
            pyth = self.oracle.pyth_latest(oracle_id)
            bs = self.oracle.block_scholes_latest(oracle_id)
            feeds = (
                _feed_status("pyth", _num(pyth.get("source_timestamp_ms")), pyth_freshness_ms, now_ms),
                _feed_status("block_scholes", _num(bs.get("source_timestamp_ms")), bs_freshness_ms, now_ms),
            )
        return OracleStatus(asset=asset, propbook_underlying_id=underlying_id, feeds=feeds)

    def _market_status(
        self, row: dict, expected_underlying_id: int, oracle_blockers: list[str], now_ms: int
    ) -> MarketStatus:
        market_id = row["expiry_market_id"]
        expiry_ms = _num(row.get("expiry"))
        underlying_id = _num(row.get("propbook_underlying_id"))
        tick_size = _num(row.get("tick_size"))

        state = self.predict.market_state(market_id)
        mint_paused = _get(state, "mint_paused", "paused") if state else None
        settlement = state.get("settlement") if state else None
        settled = settlement is not None
        settlement_price = _num(settlement.get("settlement_price")) if settled else None
        time_to_expiry_ms = None if expiry_ms is None else expiry_ms - now_ms

        blockers: list[str] = []
        if underlying_id != expected_underlying_id:
            blockers.append("market underlying does not match asset")
        if mint_paused:
            blockers.append("market minting is paused")
        if expiry_ms is None:
            blockers.append("market expiry missing")
        elif expiry_ms <= now_ms:
            blockers.append("market is expired")
        if settled:
            blockers.append("market is settled")
        blockers.extend(oracle_blockers)

        return MarketStatus(
            market_id=market_id,
            propbook_underlying_id=underlying_id,
            expiry_ms=expiry_ms,
            time_to_expiry_ms=time_to_expiry_ms,
            mint_paused=bool(mint_paused) if mint_paused is not None else None,
            settled=settled,
            tick_size=tick_size,
            blockers=blockers,
            settlement_price=settlement_price,
        )


def _resolve_cadences(config: DeploymentConfig) -> list[CadenceConfig]:
    return [c for c in config.cadences.values() if c.window_size > 0]


def _all_slot_expiries(cadences: list[CadenceConfig], now_ms: int) -> set[int]:
    expiries: set[int] = set()
    for cadence in cadences:
        period = cadence.period_ms
        live_expiry = ((now_ms // period) + 1) * period
        expiries.update(live_expiry + pos * period for pos in (-2, -1, 0, 1, 2))
    return expiries


def _build_cadence_timelines(
    cadences: list[CadenceConfig],
    markets: list[MarketStatus],
    created_expiries: set[int],
    now_ms: int,
) -> list[CadenceTimeline]:
    # `markets` are the windowed markets (with state); `created_expiries` is every
    # created market's expiry (state-free), used only for backlog counting.
    cadences = sorted(cadences, key=lambda c: c.period_ms)
    coarse_first = sorted(cadences, key=lambda c: c.period_ms, reverse=True)
    markets_by_expiry = {m.expiry_ms: m for m in markets if m.expiry_ms is not None}

    def owner_id(expiry: int) -> int | None:
        # A shared boundary (e.g. top-of-hour) belongs to the coarsest cadence whose
        # period divides it, mirroring the contract's higher-cadence-wins rule.
        for cadence in coarse_first:
            if expiry % cadence.period_ms == 0:
                return cadence.id
        return None

    timelines: list[CadenceTimeline] = []
    for cadence in cadences:
        period = cadence.period_ms
        live_expiry = ((now_ms // period) + 1) * period
        slot_expiries = {live_expiry + pos * period for pos in (-2, -1, 0, 1, 2)}
        slots = tuple(
            _slot(live_expiry + pos * period, pos, markets_by_expiry, owner_id, cadence.id, now_ms)
            for pos in (-2, -1, 0, 1, 2)
        )
        backlog_count = sum(
            1
            for expiry in created_expiries
            if owner_id(expiry) == cadence.id and expiry not in slot_expiries
        )
        timelines.append(
            CadenceTimeline(
                cadence_id=cadence.id,
                name=cadence.name,
                period_ms=period,
                window_size=cadence.window_size,
                tick_size=cadence.tick_size,
                slots=slots,
                backlog_count=backlog_count,
            )
        )
    return timelines


def _slot(
    expiry: int,
    position: int,
    markets_by_expiry: dict[int, MarketStatus],
    owner_id,
    cadence_id: int,
    now_ms: int,
) -> TimelineSlot:
    market = markets_by_expiry.get(expiry)
    if market is not None and owner_id(expiry) != cadence_id:
        market = None  # a coarser cadence owns this shared-boundary market
    return TimelineSlot(expiry, position, _slot_state(position, expiry, market, now_ms), market)


def _slot_state(position: int, expiry: int, market: MarketStatus | None, now_ms: int) -> str:
    if market is None:
        if expiry <= now_ms:
            return "expired_gone"
        if position == 0:
            return "missing_live"
        return "pending"
    if market.settled:
        return "settled"
    if expiry <= now_ms:
        return "awaiting_settle"
    if position == 0:
        return "live"
    return "scheduled"


def _feed_status(
    name: str, latest_ms: int | None, freshness_ms: int | None, now_ms: int
) -> OracleFeedStatus:
    if latest_ms is None:
        return OracleFeedStatus(name, None, freshness_ms, False, f"{name} oracle has no latest update")
    if freshness_ms is None:
        return OracleFeedStatus(name, latest_ms, None, False, f"{name} oracle freshness config missing")
    age_ms = now_ms - latest_ms
    if age_ms > freshness_ms:
        return OracleFeedStatus(name, latest_ms, freshness_ms, False, f"{name} oracle stale by {age_ms - freshness_ms}ms")
    return OracleFeedStatus(name, latest_ms, freshness_ms, True, None)


def _num(value) -> int | None:
    # Indexer numeric fields (i64 or NUMERIC/BigDecimal) arrive as JSON numbers or
    # strings; values are whole base units, so parse via Decimal and truncate.
    if value is None:
        return None
    return int(Decimal(str(value)))


def _get(data, *keys):
    current = data
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def _now_ms() -> int:
    return int(time.time() * 1000)
