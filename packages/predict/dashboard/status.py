from __future__ import annotations

import time
from dataclasses import dataclass, field
from decimal import Decimal

import fmt
from config import CadenceConfig, DeploymentConfig
from constants import ORACLE_STALENESS_MS
from indexer import IndexerHealth, PredictIndexerClient
from sui import (
    ChainHealth,
    OnchainSnapshot,
    OnchainSnapshotReader,
    OnchainSnapshotRequest,
    OracleReadSnapshot,
)

_MARKETS_LIMIT = 500


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
    settled: bool
    tick_size: int | None
    blockers: list[str]
    settlement_price: int | None = None

    @property
    def mintable(self) -> bool:
        return len(self.blockers) == 0


@dataclass(frozen=True)
class TimelineSlot:
    expiry_ms: int
    position: int
    # live | scheduled | awaiting_settle | settled | expired_gone | missing_live
    # pending | skipped
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
    def has_live_market(self) -> bool:
        return any(cadence.has_live_market for cadence in self.cadences)


@dataclass(frozen=True)
class AttentionItem:
    severity: str
    text: str


@dataclass(frozen=True)
class OperationalStatus:
    report: PredictStatusReport
    snapshot: OnchainSnapshot
    chain: ChainHealth
    indexer: IndexerHealth
    attention: list[AttentionItem] = field(default_factory=list)


class StatusLoader:
    def __init__(
        self,
        config: DeploymentConfig,
        *,
        asset: str = "BTC_USD",
        indexer_url: str | None = None,
        snapshot_reader: OnchainSnapshotReader | None = None,
        timeout: float = 10,
    ) -> None:
        self.config = config
        self.asset = asset
        self.indexer = PredictIndexerClient(indexer_url or config.predict_indexer_url, timeout=timeout)
        self.snapshot_reader = snapshot_reader or OnchainSnapshotReader(config)

    def load(self, now_ms: int | None = None) -> OperationalStatus:
        now_ms = _now_ms() if now_ms is None else now_ms
        report, snapshot = self.status_with_snapshot(now_ms)
        chain = self.snapshot_reader.client.latest_checkpoint()
        indexer = self.indexer.health()
        attention = derive_attention(report, snapshot, indexer, now_ms)
        return OperationalStatus(report, snapshot, chain, indexer, attention)

    def status_with_snapshot(self, now_ms: int) -> tuple[PredictStatusReport, OnchainSnapshot]:
        asset_config = self.config.asset(self.asset)
        protocol_config_id = self.config.shared_object_id("predict", "protocol_config::ProtocolConfig")
        pool_vault_id = self.config.shared_object_id("predict", "plp::PoolVault")

        blockers: list[str] = []
        cadences = _resolve_cadences(self.config)
        slot_expiries = _all_slot_expiries(cadences, now_ms)
        horizon_ms = max((c.period_ms * (c.window_size + 2) for c in cadences), default=0)
        start_time_s = max(0, (now_ms - horizon_ms) // 1000)

        created = self.indexer.markets(start_time_s=start_time_s, limit=_MARKETS_LIMIT)
        if len(created) >= _MARKETS_LIMIT:
            blockers.append("markets feed hit timeline row cap")

        created_by_expiry = {
            int(row["expiry"]): row
            for row in created
            if row.get("expiry") is not None
        }
        market_rows = [
            row
            for expiry, row in sorted(created_by_expiry.items())
            if expiry in slot_expiries
        ]
        market_ids = tuple(
            row["expiry_market_id"]
            for row in market_rows
            if row.get("expiry_market_id")
        )
        market_expiries = {
            row["expiry_market_id"]: int(row["expiry"])
            for row in market_rows
            if row.get("expiry_market_id") and row.get("expiry") is not None
        }

        try:
            snapshot = self.snapshot_reader.snapshot(
                OnchainSnapshotRequest(
                    asset=self.asset,
                    market_ids=market_ids,
                    market_expiries=market_expiries,
                )
            )
        except Exception as exc:
            snapshot = OnchainSnapshot(None, {}, {}, (f"on-chain snapshot unavailable: {exc}",))
        blockers.extend(snapshot.errors)

        oracle = self._oracle_status_from_snapshot(
            asset_config.propbook_underlying_id,
            snapshot,
            market_ids,
            now_ms,
        )
        blockers.extend(oracle.blockers)

        markets = [
            self._market_status(
                row,
                asset_config.propbook_underlying_id,
                oracle.blockers,
                now_ms,
                snapshot,
            )
            for row in market_rows
        ]

        pool_snapshot = snapshot.pool
        pool = PoolStatus(
            pool_vault_id=pool_vault_id,
            idle_balance=None if pool_snapshot is None else pool_snapshot.idle_balance,
            protocol_reserve_balance=(
                None if pool_snapshot is None else pool_snapshot.protocol_reserve_balance
            ),
            plp_total_supply=None if pool_snapshot is None else pool_snapshot.plp_total_supply,
            active_market_ids=(
                market_ids
                if pool_snapshot is None or not pool_snapshot.active_market_ids
                else pool_snapshot.active_market_ids
            ),
        )

        cadence_timelines = _build_cadence_timelines(cadences, markets, set(created_by_expiry), now_ms)
        is_mintable = any(market.mintable for market in markets) and not blockers
        is_live = not blockers
        return (
            PredictStatusReport(
                network=self.config.network,
                chain_id=self.config.chain_id,
                asset=self.asset,
                protocol_config_id=protocol_config_id,
                pool_vault_id=pool_vault_id,
                is_live=is_live,
                is_mintable=is_mintable,
                blockers=blockers,
                oracle=oracle,
                pool=pool,
                markets=markets,
                cadences=cadence_timelines,
            ),
            snapshot,
        )

    def _oracle_status_from_snapshot(
        self,
        underlying_id: int,
        snapshot: OnchainSnapshot,
        market_ids: tuple[str, ...],
        now_ms: int,
    ) -> OracleStatus:
        if not market_ids:
            return OracleStatus(
                asset=self.asset,
                propbook_underlying_id=underlying_id,
                feeds=(
                    OracleFeedStatus("pyth", None, ORACLE_STALENESS_MS, True, None),
                    OracleFeedStatus("block_scholes", None, ORACLE_STALENESS_MS, True, None),
                ),
            )

        market_oracles = [
            snapshot.oracles[market_id]
            for market_id in market_ids
            if market_id in snapshot.oracles
        ]
        pyth_reads = [oracle.pyth for oracle in market_oracles]
        bs_spot_reads = [oracle.bs_spot for oracle in market_oracles]
        return OracleStatus(
            asset=self.asset,
            propbook_underlying_id=underlying_id,
            feeds=(
                _snapshot_feed_status("pyth", pyth_reads, now_ms),
                _snapshot_feed_status("block_scholes", bs_spot_reads, now_ms),
            ),
        )

    def _market_status(
        self,
        row: dict,
        expected_underlying_id: int,
        oracle_blockers: list[str],
        now_ms: int,
        snapshot: OnchainSnapshot,
    ) -> MarketStatus:
        market_id = row["expiry_market_id"]
        live = snapshot.markets.get(market_id)
        expiry_ms = live.expiry_ms if live and live.expiry_ms else _num(row.get("expiry"))
        underlying_id = (
            live.propbook_underlying_id
            if live and live.propbook_underlying_id
            else _num(row.get("propbook_underlying_id"))
        )
        tick_size = live.tick_size if live and live.tick_size else _num(row.get("tick_size"))
        state = self.indexer.market_state(market_id)
        settlement = state.get("settlement") if state else None
        settled = settlement is not None
        settlement_price = _num(settlement.get("settlement_price")) if settled else None
        time_to_expiry_ms = None if expiry_ms is None else expiry_ms - now_ms

        blockers: list[str] = []
        if underlying_id != expected_underlying_id:
            blockers.append("market underlying does not match asset")
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
            settled=settled,
            tick_size=tick_size,
            blockers=blockers,
            settlement_price=settlement_price,
        )


def derive_attention(
    report: PredictStatusReport,
    snapshot: OnchainSnapshot,
    indexer: IndexerHealth,
    now_ms: int,
) -> list[AttentionItem]:
    items: list[AttentionItem] = []
    oracle_blockers = set(report.oracle.blockers)
    for blocker in dict.fromkeys(report.blockers):
        if blocker not in oracle_blockers:
            items.append(AttentionItem("block", blocker))
    if not report.oracle.fresh:
        items.append(AttentionItem("block", "oracle stale"))
    if not indexer.reachable:
        items.append(AttentionItem("warn", "indexer unreachable"))
    elif not indexer.ok:
        items.append(AttentionItem("warn", "indexer status not OK"))

    live_ids = {
        slot.market.market_id
        for cadence in report.cadences
        for slot in cadence.slots
        if slot.market is not None and slot.state in ("live", "missing_live")
    }
    unfunded = [
        mid
        for mid, market in snapshot.markets.items()
        if mid in live_ids and market.cash_balance == 0
    ]
    if unfunded:
        items.append(AttentionItem("warn", f"{len(unfunded)} unfunded live market(s)"))

    underbacked = [
        mid
        for mid, market in snapshot.markets.items()
        if market.payout_liability > market.cash_balance
    ]
    if underbacked:
        items.append(AttentionItem("warn", f"{len(underbacked)} under-backed market(s)"))

    awaiting = [
        slot
        for cadence in report.cadences
        for slot in cadence.slots
        if slot.state == "awaiting_settle"
    ]
    if awaiting:
        oldest = min(slot.expiry_ms for slot in awaiting)
        items.append(
            AttentionItem(
                "warn",
                f"settlement backlog {len(awaiting)} / oldest {fmt.age(oldest, now_ms)}",
            )
        )

    items.sort(key=lambda item: 0 if item.severity == "block" else 1)
    return items


def _resolve_cadences(config: DeploymentConfig) -> list[CadenceConfig]:
    return [cadence for cadence in config.cadences.values() if cadence.window_size > 0]


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
    cadences = sorted(cadences, key=lambda c: c.period_ms)
    coarse_first = sorted(cadences, key=lambda c: c.period_ms, reverse=True)
    markets_by_expiry = {m.expiry_ms: m for m in markets if m.expiry_ms is not None}

    def owner_id(expiry: int) -> int | None:
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
            _slot(
                live_expiry + pos * period,
                pos,
                markets_by_expiry,
                owner_id,
                cadence.id,
                now_ms,
            )
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
    if owner_id(expiry) != cadence_id:
        return TimelineSlot(expiry, position, "skipped", None)
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


def _snapshot_feed_status(name: str, reads: list[OracleReadSnapshot], now_ms: int) -> OracleFeedStatus:
    present = [
        read
        for read in reads
        if read.present and read.source_timestamp_ms is not None
    ]
    if not reads or len(present) != len(reads):
        return OracleFeedStatus(name, None, ORACLE_STALENESS_MS, False, f"{name} oracle has no latest update")
    latest_ms = min(read.source_timestamp_ms for read in present)
    stale = now_ms - latest_ms > ORACLE_STALENESS_MS
    blocker = f"{name} oracle stale" if stale else None
    return OracleFeedStatus(name, latest_ms, ORACLE_STALENESS_MS, not stale, blocker)


def _num(value) -> int | None:
    if value is None:
        return None
    return int(Decimal(str(value)))


def _now_ms() -> int:
    return int(time.time() * 1000)
