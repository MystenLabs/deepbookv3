from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Protocol

from .config import CadenceConfig, DeploymentConfig
from .constants import CADENCE_NAMES


class ObjectReader(Protocol):
    def get_object(self, object_id: str) -> dict[str, Any] | None:
        pass

    def get_dynamic_field_object(
        self,
        parent_id: str,
        name_type: str,
        name_value: str,
    ) -> dict[str, Any] | None:
        pass


@dataclass(frozen=True)
class OracleFeedStatus:
    name: str
    object_id: str
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
    supply_requests_pending: int | None
    withdraw_requests_pending: int | None
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
    cash_balance: int | None
    payout_liability: int | None
    rebate_reserve: int | None
    tick_size: int | None
    blockers: list[str]
    reference_tick: int | None = None
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
        # live by expiry, whether or not it has been funded yet
        return any(slot.state in ("live", "unfunded") for slot in self.slots)


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
    def __init__(self, config: DeploymentConfig, reader: ObjectReader):
        self.config = config
        self.reader = reader

    def status(self, asset: str = "BTC_USD", now_ms: int | None = None) -> PredictStatusReport:
        now_ms = _now_ms() if now_ms is None else now_ms
        asset_config = self.config.asset(asset)
        protocol_config_id = self.config.shared_object_id(
            "predict",
            "protocol_config::ProtocolConfig",
        )
        pool_vault_id = self.config.shared_object_id("predict", "plp::PoolVault")

        blockers: list[str] = []
        protocol_fields = _object_fields(self.reader.get_object(protocol_config_id))
        if not protocol_fields:
            blockers.append("protocol config object missing")
        elif _as_bool(protocol_fields.get("trading_paused")):
            blockers.append("protocol trading is paused")
        elif _as_bool(protocol_fields.get("valuation_in_progress")):
            blockers.append("pool valuation is in progress")

        pool_fields = _object_fields(self.reader.get_object(pool_vault_id))
        expiry_accounting_fields = _fields(pool_fields.get("expiry_accounting"))
        if not pool_fields:
            blockers.append("pool vault object missing")
            active_market_ids: tuple[str, ...] = tuple()
        else:
            active_market_ids = tuple(
                _as_id_list(pool_fields.get("active_expiry_markets"))
                or _as_id_list(expiry_accounting_fields.get("active_expiry_markets"))
            )
            if not active_market_ids:
                blockers.append("no active expiry markets")

        market_fields = {
            market_id: _object_fields(self.reader.get_object(market_id))
            for market_id in active_market_ids
        }
        live_expiries = tuple(
            sorted(
                expiry
                for fields in market_fields.values()
                if (expiry := _optional_int(fields.get("expiry"))) is not None
                and expiry > now_ms
            )
        )

        freshness = _freshness_config(protocol_fields)
        oracle = self._oracle_status(asset, now_ms, freshness, live_expiries)
        blockers.extend(oracle.blockers)

        lp_fields = _fields(pool_fields.get("lp"))
        treasury_cap_fields = _fields(lp_fields.get("treasury_cap"))
        total_supply_fields = _fields(treasury_cap_fields.get("total_supply"))
        supply_queue_fields = _fields(lp_fields.get("supply_queue"))
        withdraw_queue_fields = _fields(lp_fields.get("withdraw_queue"))

        pool = PoolStatus(
            pool_vault_id=pool_vault_id,
            idle_balance=_first_int(
                pool_fields.get("idle_balance"),
                expiry_accounting_fields.get("idle_balance"),
            ),
            protocol_reserve_balance=_first_int(pool_fields.get("protocol_reserve_balance")),
            plp_total_supply=_first_int(
                pool_fields.get("plp_total_supply"),
                total_supply_fields.get("value"),
            ),
            supply_requests_pending=_first_int(
                pool_fields.get("supply_requests_pending"),
                supply_queue_fields.get("pending"),
            ),
            withdraw_requests_pending=_first_int(
                pool_fields.get("withdraw_requests_pending"),
                withdraw_queue_fields.get("pending"),
            ),
            active_market_ids=active_market_ids,
        )

        markets = [
            self._market_status(
                market_id, fields, asset_config.propbook_underlying_id, oracle, now_ms
            )
            for market_id, fields in market_fields.items()
        ]
        cadences = _build_cadence_timelines(self._resolve_cadences(), markets, now_ms)
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
            cadences=cadences,
        )

    def _oracle_status(
        self,
        asset: str,
        now_ms: int,
        freshness: dict[str, int | None],
        expiry_ms_values: tuple[int, ...],
    ) -> OracleStatus:
        asset_config = self.config.asset(asset)
        feed_specs = (
            ("pyth", asset_config.feed_ids.pyth, freshness["pyth"]),
            ("block_scholes_spot", asset_config.feed_ids.bs_spot, freshness["bs_price"]),
            ("block_scholes_forward", asset_config.feed_ids.bs_forward, freshness["bs_price"]),
            ("block_scholes_svi", asset_config.feed_ids.bs_svi, freshness["bs_svi"]),
        )
        feeds = tuple(
            _feed_status(
                name,
                object_id,
                self.reader.get_object(object_id),
                now_ms,
                freshness_ms,
                self.reader,
                expiry_ms_values,
            )
            for name, object_id, freshness_ms in feed_specs
        )
        return OracleStatus(
            asset=asset,
            propbook_underlying_id=asset_config.propbook_underlying_id,
            feeds=feeds,
        )

    def _market_status(
        self,
        market_id: str,
        fields: dict[str, Any],
        expected_underlying_id: int,
        oracle: OracleStatus,
        now_ms: int,
    ) -> MarketStatus:
        blockers: list[str] = []
        if not fields:
            blockers.append("market object missing")
            return MarketStatus(
                market_id=market_id,
                propbook_underlying_id=None,
                expiry_ms=None,
                time_to_expiry_ms=None,
                mint_paused=None,
                settled=False,
                cash_balance=None,
                payout_liability=None,
                rebate_reserve=None,
                tick_size=None,
                blockers=blockers,
            )

        underlying_id = _optional_int(fields.get("propbook_underlying_id"))
        expiry_ms = _optional_int(fields.get("expiry"))
        mint_paused = _optional_bool(fields.get("mint_paused"))
        settled = _option_has_value(fields.get("settlement_price"))
        settlement_price = _option_int(fields.get("settlement_price"))
        cash_fields = _fields(fields.get("cash"))
        strike_exposure_fields = _fields(fields.get("strike_exposure"))
        cash_balance = _first_int(fields.get("cash_balance"), cash_fields.get("cash_balance"))
        reference_tick = _option_int(
            _first(fields.get("reference_tick"), strike_exposure_fields.get("reference_tick"))
        )
        time_to_expiry_ms = None if expiry_ms is None else expiry_ms - now_ms

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
        if cash_balance is None:
            blockers.append("market cash balance missing")
        elif cash_balance <= 0:
            blockers.append("market has no expiry cash")
        blockers.extend(oracle.blockers)

        return MarketStatus(
            market_id=market_id,
            propbook_underlying_id=underlying_id,
            expiry_ms=expiry_ms,
            time_to_expiry_ms=time_to_expiry_ms,
            mint_paused=mint_paused,
            settled=settled,
            cash_balance=cash_balance,
            payout_liability=_optional_int(fields.get("payout_liability")),
            rebate_reserve=_optional_int(fields.get("rebate_reserve")),
            tick_size=_first_int(fields.get("tick_size"), strike_exposure_fields.get("tick_size")),
            blockers=blockers,
            reference_tick=reference_tick,
            settlement_price=settlement_price,
        )

    def _resolve_cadences(self) -> list[CadenceConfig]:
        # Prefer the live on-chain cadence set so newly deployed cadences appear
        # without an SDK edit; fall back to the static deployment config.
        try:
            registry_id = self.config.shared_object_id("predict", "registry::Registry")
        except KeyError:
            registry_id = None
        if registry_id:
            chain = _cadences_from_registry(_object_fields(self.reader.get_object(registry_id)))
            if chain:
                return chain
        by_id = {c.id: c for c in self.config.cadences.values()}
        return [c for c in by_id.values() if c.window_size > 0]


def _cadences_from_registry(registry_fields: dict[str, Any]) -> list[CadenceConfig]:
    manager = _fields(registry_fields.get("market_manager"))
    raw = manager.get("cadences")
    if not isinstance(raw, list):
        return []
    cadences: list[CadenceConfig] = []
    for cadence_id, entry in enumerate(raw):
        fields = _fields(entry)
        window = _optional_int(fields.get("window_size"))
        if not window or cadence_id not in CADENCE_NAMES:
            continue  # disabled (window 0), unreadable, or unknown id
        cadences.append(
            CadenceConfig(
                id=cadence_id,
                name=CADENCE_NAMES[cadence_id],
                tick_size=_optional_int(fields.get("tick_size")) or 0,
                admission_tick_size=_optional_int(fields.get("admission_tick_size")) or 0,
                max_expiry_allocation=_optional_int(fields.get("max_expiry_allocation")) or 0,
                initial_expiry_cash=_optional_int(fields.get("initial_expiry_cash")) or 0,
                window_size=window,
            )
        )
    return cadences


def _build_cadence_timelines(
    cadences: list[CadenceConfig],
    markets: list[MarketStatus],
    now_ms: int,
) -> list[CadenceTimeline]:
    # `cadences` is the resolved, enabled set (chain-sourced where available).
    # Order fine->coarse so the display reads short-period first.
    cadences = sorted(cadences, key=lambda c: c.period_ms)
    coarse_first = sorted(cadences, key=lambda c: c.period_ms, reverse=True)
    markets_by_expiry = {m.expiry_ms: m for m in markets if m.expiry_ms is not None}

    def owner_id(expiry: int) -> int | None:
        # A shared boundary (e.g. top-of-hour) belongs to the coarsest cadence
        # whose period divides it, mirroring the contract's higher-cadence-wins rule.
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
            for m in markets
            if m.expiry_ms is not None
            and owner_id(m.expiry_ms) == cadence.id
            and m.expiry_ms not in slot_expiries
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
        # created but not yet funded by the rebalance keeper -> not mintable
        return "unfunded" if not market.cash_balance else "live"
    return "scheduled"


def _feed_status(
    name: str,
    object_id: str,
    obj: dict[str, Any] | None,
    now_ms: int,
    freshness_ms: int | None,
    reader: ObjectReader,
    expiry_ms_values: tuple[int, ...],
) -> OracleFeedStatus:
    fields = _object_fields(obj)
    if not fields:
        return OracleFeedStatus(name, object_id, None, freshness_ms, False, f"{name} feed missing")
    latest = _latest_source_timestamp_ms(fields)
    if latest is None and name in {"block_scholes_forward", "block_scholes_svi"}:
        latest = _latest_table_source_timestamp_ms(fields, reader, expiry_ms_values)
    if latest is None:
        return OracleFeedStatus(
            name,
            object_id,
            None,
            freshness_ms,
            False,
            f"{name} oracle has no latest update",
        )
    if freshness_ms is None:
        return OracleFeedStatus(
            name,
            object_id,
            latest,
            None,
            False,
            f"{name} oracle freshness config missing",
        )
    age_ms = now_ms - latest
    if age_ms > freshness_ms:
        return OracleFeedStatus(
            name,
            object_id,
            latest,
            freshness_ms,
            False,
            f"{name} oracle stale by {age_ms - freshness_ms}ms",
        )
    return OracleFeedStatus(name, object_id, latest, freshness_ms, True, None)


def _latest_table_source_timestamp_ms(
    fields: dict[str, Any],
    reader: ObjectReader,
    expiry_ms_values: tuple[int, ...],
) -> int | None:
    table_id = _table_id(fields.get("expiries"))
    if table_id is None or not expiry_ms_values:
        return None
    timestamps: list[int] = []
    for expiry_ms in expiry_ms_values:
        entry = reader.get_dynamic_field_object(table_id, "u64", str(expiry_ms))
        entry_fields = _object_fields(entry)
        value_fields = _fields(entry_fields.get("value"))
        latest = _latest_source_timestamp_ms(value_fields)
        if latest is None:
            return None
        timestamps.append(latest)
    return min(timestamps) if timestamps else None


def _freshness_config(protocol_fields: dict[str, Any]) -> dict[str, int | None]:
    pricing_config = _fields(protocol_fields.get("pricing_config"))
    return {
        "pyth": _optional_int(pricing_config.get("pyth_spot_freshness_ms")),
        "bs_price": _optional_int(pricing_config.get("block_scholes_price_freshness_ms")),
        "bs_svi": _optional_int(pricing_config.get("block_scholes_svi_freshness_ms")),
    }


def _object_fields(obj: dict[str, Any] | None) -> dict[str, Any]:
    if obj is None:
        return {}
    current: Any = obj
    if isinstance(current, dict) and "data" in current:
        current = current["data"]
    if isinstance(current, dict) and "content" in current:
        current = current["content"]
    return _fields(current)


def _fields(value: Any) -> dict[str, Any]:
    if isinstance(value, dict) and isinstance(value.get("fields"), dict):
        return value["fields"]
    if isinstance(value, dict):
        return value
    return {}


def _optional_int(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value)
    if isinstance(value, dict):
        fields = _fields(value)
        if "value" in fields:
            return _optional_int(fields["value"])
    return None


def _first_int(*values: Any) -> int | None:
    for value in values:
        parsed = _optional_int(value)
        if parsed is not None:
            return parsed
    return None


def _first(*values: Any) -> Any:
    for value in values:
        if value is not None:
            return value
    return None


def _option_int(value: Any) -> int | None:
    # Move Option<u64> renders as {"fields": {"vec": [v]}} (empty vec == none).
    if value is None:
        return None
    fields = _fields(value)
    vec = fields.get("vec")
    if isinstance(vec, list):
        return _optional_int(vec[0]) if vec else None
    return _optional_int(value)


def _as_bool(value: Any) -> bool:
    parsed = _optional_bool(value)
    return False if parsed is None else parsed


def _optional_bool(value: Any) -> bool | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.lower() == "true"
    return None


def _as_id_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item) for item in value]
    if isinstance(value, dict):
        fields = _fields(value)
        if isinstance(fields.get("contents"), list):
            return [str(item) for item in fields["contents"]]
        if isinstance(fields.get("vec"), list):
            return [str(item) for item in fields["vec"]]
    return []


def _table_id(value: Any) -> str | None:
    fields = _fields(value)
    table_id = fields.get("id")
    if isinstance(table_id, dict):
        object_id = table_id.get("id")
        if isinstance(object_id, str):
            return object_id
    return None


def _option_has_value(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, dict):
        fields = _fields(value)
        if "vec" in fields and isinstance(fields["vec"], list):
            return len(fields["vec"]) > 0
    return True


def _latest_source_timestamp_ms(fields: dict[str, Any]) -> int | None:
    direct = _optional_int(fields.get("latest_source_timestamp_ms"))
    if direct is not None:
        return direct
    latest = _fields(fields.get("latest"))
    source_timestamp = _source_timestamp_from_latest(latest)
    if source_timestamp is not None:
        return source_timestamp
    lane = _fields(fields.get("lane"))
    latest = _fields(lane.get("latest"))
    return _source_timestamp_from_latest(latest)


def _source_timestamp_from_latest(latest: dict[str, Any]) -> int | None:
    source_timestamp = _optional_int(latest.get("source_timestamp_ms"))
    if source_timestamp is not None:
        return source_timestamp
    vec = latest.get("vec")
    if isinstance(vec, list) and vec:
        return _optional_int(_fields(vec[0]).get("source_timestamp_ms"))
    return None


def _now_ms() -> int:
    return int(time.time() * 1000)
