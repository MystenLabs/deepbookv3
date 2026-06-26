from __future__ import annotations

import base64
from dataclasses import dataclass
from typing import Any

import bcs
from bcs import Ptb
from config import DeploymentConfig
from constants import DEFAULT_TESTNET_RPC_URL
from net import post_json


@dataclass(frozen=True)
class ChainHealth:
    reachable: bool
    latest_checkpoint: int | None
    error: str | None = None


@dataclass(frozen=True)
class OracleReadSnapshot:
    present: bool
    source_timestamp_ms: int | None = None
    update_timestamp_ms: int | None = None
    value: int | None = None


@dataclass(frozen=True)
class PoolSnapshot:
    pool_vault_id: str
    staked_deep: int
    idle_balance: int
    protocol_reserve_balance: int
    fee_incentive_reserve: int
    plp_total_supply: int
    supply_requests_pending: int
    withdraw_requests_pending: int
    active_market_ids: tuple[str, ...]
    profit_basis_debits: int
    profit_basis_credits: int
    pending_protocol_profit: int


@dataclass(frozen=True)
class MarketSnapshot:
    market_id: str
    propbook_underlying_id: int
    expiry_ms: int
    cash_balance: int
    rebate_reserve: int
    fee_incentive_balance: int
    trading_loss_rebate_rate: int
    liquidation_ltv: int
    max_admission_leverage: int
    backing_buffer_lambda: int
    expiry_fee_window_ms: int
    expiry_fee_max_multiplier: int
    tick_size: int
    admission_tick_size: int
    reference_tick: int | None
    reference_tick_source_timestamp_ms: int
    payout_liability: int


@dataclass(frozen=True)
class MarketOracleSnapshot:
    pyth: OracleReadSnapshot
    bs_spot: OracleReadSnapshot
    bs_forward: OracleReadSnapshot
    bs_svi: OracleReadSnapshot


@dataclass(frozen=True)
class OnchainSnapshot:
    pool: PoolSnapshot | None
    markets: dict[str, MarketSnapshot]
    oracles: dict[str, MarketOracleSnapshot]
    errors: tuple[str, ...] = ()


@dataclass(frozen=True)
class OnchainSnapshotRequest:
    asset: str = "BTC_USD"
    market_ids: tuple[str, ...] = ()
    market_expiries: dict[str, int] | None = None
    include_pool: bool = True
    include_oracles: bool = True


class ReturnDecoder:
    def __init__(self, raw: bytes | list[int]) -> None:
        self.raw = bytes(raw)
        self.offset = 0

    def u8(self) -> int:
        value = self.raw[self.offset]
        self.offset += 1
        return value

    def u32(self) -> int:
        value = int.from_bytes(self.raw[self.offset:self.offset + 4], "little")
        self.offset += 4
        return value

    def u64(self) -> int:
        value = int.from_bytes(self.raw[self.offset:self.offset + 8], "little")
        self.offset += 8
        return value

    def address(self) -> str:
        value = self.raw[self.offset:self.offset + 32]
        self.offset += 32
        return "0x" + value.hex()

    def uleb(self) -> int:
        shift = 0
        result = 0
        while True:
            byte = self.u8()
            result |= (byte & 0x7F) << shift
            if byte & 0x80 == 0:
                return result
            shift += 7

    def vector_id(self) -> tuple[str, ...]:
        return tuple(self.address() for _ in range(self.uleb()))

    def option_u64(self) -> int | None:
        if self.u8() == 0:
            return None
        return self.u64()

    def option_oracle_read_u64(self) -> OracleReadSnapshot:
        if self.u8() == 0:
            return OracleReadSnapshot(False)
        return OracleReadSnapshot(True, self.u64(), self.u64(), self.u64())

    def option_oracle_read_svi(self) -> OracleReadSnapshot:
        if self.u8() == 0:
            return OracleReadSnapshot(False)
        source_timestamp_ms = self.u64()
        update_timestamp_ms = self.u64()
        return OracleReadSnapshot(True, source_timestamp_ms, update_timestamp_ms, None)


class SuiReadClient:
    def __init__(
        self,
        rpc_url: str = DEFAULT_TESTNET_RPC_URL,
        *,
        timeout: float = 30,
    ) -> None:
        self.rpc_url = rpc_url
        self.timeout = timeout
        self._isv_cache: dict[str, int] = {}

    def latest_checkpoint(self) -> ChainHealth:
        try:
            value = int(self._rpc("sui_getLatestCheckpointSequenceNumber", []))
            return ChainHealth(True, value)
        except Exception as exc:
            return ChainHealth(False, None, str(exc))

    def preload_shared_isv(self, object_ids: list[str] | tuple[str, ...]) -> None:
        missing = [object_id for object_id in dict.fromkeys(object_ids) if object_id not in self._isv_cache]
        for start in range(0, len(missing), 50):
            chunk = missing[start:start + 50]
            if not chunk:
                continue
            responses = self._rpc("sui_multiGetObjects", [chunk, {"showOwner": True}])
            for object_id, response in zip(chunk, responses):
                data = response.get("data") if isinstance(response, dict) else None
                if data is None:
                    raise RuntimeError(f"object not found: {object_id}")
                owner = data.get("owner", {})
                shared = owner.get("Shared") if isinstance(owner, dict) else None
                if not shared:
                    raise RuntimeError(f"object is not shared: {object_id}")
                self._isv_cache[object_id] = int(shared["initial_shared_version"])

    def shared_isv(self, object_id: str) -> int:
        if object_id not in self._isv_cache:
            self.preload_shared_isv([object_id])
        return self._isv_cache[object_id]

    def dev_inspect(self, sender: str, ptb: Ptb) -> dict[str, Any]:
        tx_kind = base64.b64encode(bcs.build_transaction_kind(ptb)).decode("ascii")
        sender = "0x" + bcs.normalize_address(sender).hex()
        return self._rpc("sui_devInspectTransactionBlock", [sender, tx_kind])

    def _rpc(self, method: str, params: list[Any]) -> Any:
        body = post_json(
            self.rpc_url,
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
            self.timeout,
        )
        if body.get("error") is not None:
            raise RuntimeError(f"RPC {method} error: {body['error']}")
        return body["result"]


class OnchainSnapshotReader:
    def __init__(
        self,
        config: DeploymentConfig,
        *,
        client: SuiReadClient | None = None,
        sender: str = "0x0",
    ) -> None:
        self.config = config
        self.client = client or SuiReadClient()
        self.sender = sender

    def snapshot(self, request: OnchainSnapshotRequest) -> OnchainSnapshot:
        self._preload_shared_objects(request)
        ptb = Ptb()
        commands: list[tuple[str, str | None]] = []
        predict_pkg = self.config.package_id("predict")
        propbook_pkg = self.config.package_id("propbook")
        asset = self.config.asset(request.asset)

        if request.include_pool:
            pool_id = self.config.shared_object_id("predict", "plp::PoolVault")
            pool = _shared(ptb, self.client, pool_id)
            for function in (
                "staked_deep",
                "idle_balance",
                "protocol_reserve_balance",
                "fee_incentive_reserve",
                "plp_total_supply",
                "supply_requests_pending",
                "withdraw_requests_pending",
                "profit_basis_debits",
                "profit_basis_credits",
                "pending_protocol_profit",
            ):
                ptb.move_call(predict_pkg, "plp", function, [], [pool])
                commands.append(("pool:" + function, None))

        for market_id in request.market_ids:
            market = _shared(ptb, self.client, market_id)
            for function in (
                "propbook_underlying_id",
                "expiry",
                "cash_balance",
                "rebate_reserve",
                "fee_incentive_balance",
                "trading_loss_rebate_rate",
                "liquidation_ltv",
                "max_admission_leverage",
                "backing_buffer_lambda",
                "expiry_fee_window_ms",
                "expiry_fee_max_multiplier",
                "tick_size",
                "admission_tick_size",
                "reference_tick",
                "reference_tick_source_timestamp_ms",
                "payout_liability",
            ):
                ptb.move_call(predict_pkg, "expiry_market", function, [], [market])
                commands.append(("market:" + function, market_id))

        expiries = request.market_expiries or {}
        if request.include_oracles:
            pyth = _shared(ptb, self.client, asset.feed_ids.pyth)
            bs_spot = _shared(ptb, self.client, asset.feed_ids.bs_spot)
            ptb.move_call(propbook_pkg, "pyth_feed", "normalized_spot", [], [pyth])
            commands.append(("oracle:pyth", None))
            ptb.move_call(
                propbook_pkg,
                "block_scholes_spot_feed",
                "normalized_spot",
                [],
                [bs_spot],
            )
            commands.append(("oracle:bs_spot", None))

            for market_id in request.market_ids:
                expiry = expiries.get(market_id)
                if expiry is None:
                    continue
                bs_forward = _shared(ptb, self.client, asset.feed_ids.bs_forward)
                bs_svi = _shared(ptb, self.client, asset.feed_ids.bs_svi)
                ptb.move_call(
                    propbook_pkg,
                    "block_scholes_forward_feed",
                    "normalized_forward",
                    [],
                    [bs_forward, ptb.pure_u64(expiry)],
                )
                commands.append(("oracle:bs_forward", market_id))
                ptb.move_call(
                    propbook_pkg,
                    "block_scholes_svi_feed",
                    "normalized_svi",
                    [],
                    [bs_svi, ptb.pure_u64(expiry)],
                )
                commands.append(("oracle:bs_svi", market_id))

        result = self.client.dev_inspect(self.sender, ptb)
        return self._decode_snapshot(request, commands, result)

    def _preload_shared_objects(self, request: OnchainSnapshotRequest) -> None:
        object_ids: list[str] = []
        if request.include_pool:
            object_ids.append(self.config.shared_object_id("predict", "plp::PoolVault"))
        object_ids.extend(request.market_ids)
        if request.include_oracles:
            feed_ids = self.config.asset(request.asset).feed_ids
            object_ids.extend([feed_ids.pyth, feed_ids.bs_spot, feed_ids.bs_forward, feed_ids.bs_svi])
        self.client.preload_shared_isv(object_ids)

    def _decode_snapshot(
        self,
        request: OnchainSnapshotRequest,
        commands: list[tuple[str, str | None]],
        result: dict[str, Any],
    ) -> OnchainSnapshot:
        status = result.get("effects", {}).get("status", {})
        if status.get("status") not in (None, "success"):
            return OnchainSnapshot(None, {}, {}, (str(status.get("error") or "devInspect failed"),))

        pool_values: dict[str, Any] = {}
        market_values: dict[str, dict[str, Any]] = {}
        oracle_values: dict[str, dict[str, OracleReadSnapshot]] = {}

        results = result.get("results") or []
        for (kind, object_id), command_result in zip(commands, results):
            raw = _return_bytes(command_result)
            if not raw:
                continue
            group, name = kind.split(":", 1)
            decoder = ReturnDecoder(raw)

            if group == "pool":
                pool_values[name] = decoder.u64()
                continue

            if group == "market" and object_id is not None:
                market_values.setdefault(object_id, {})
                if name == "propbook_underlying_id":
                    market_values[object_id][name] = decoder.u32()
                elif name == "reference_tick":
                    market_values[object_id][name] = decoder.option_u64()
                else:
                    market_values[object_id][name] = decoder.u64()
                continue

            if group == "oracle":
                key = object_id or "__asset__"
                oracle_values.setdefault(key, {})
                if name == "bs_svi":
                    oracle_values[key][name] = decoder.option_oracle_read_svi()
                else:
                    oracle_values[key][name] = decoder.option_oracle_read_u64()

        pool = None
        if pool_values:
            pool = PoolSnapshot(
                pool_vault_id=self.config.shared_object_id("predict", "plp::PoolVault"),
                staked_deep=int(pool_values.get("staked_deep", 0)),
                idle_balance=int(pool_values.get("idle_balance", 0)),
                protocol_reserve_balance=int(pool_values.get("protocol_reserve_balance", 0)),
                fee_incentive_reserve=int(pool_values.get("fee_incentive_reserve", 0)),
                plp_total_supply=int(pool_values.get("plp_total_supply", 0)),
                supply_requests_pending=int(pool_values.get("supply_requests_pending", 0)),
                withdraw_requests_pending=int(pool_values.get("withdraw_requests_pending", 0)),
                active_market_ids=(),
                profit_basis_debits=int(pool_values.get("profit_basis_debits", 0)),
                profit_basis_credits=int(pool_values.get("profit_basis_credits", 0)),
                pending_protocol_profit=int(pool_values.get("pending_protocol_profit", 0)),
            )

        markets: dict[str, MarketSnapshot] = {}
        for market_id, values in market_values.items():
            markets[market_id] = MarketSnapshot(
                market_id=market_id,
                propbook_underlying_id=int(values.get("propbook_underlying_id", 0)),
                expiry_ms=int(values.get("expiry", 0)),
                cash_balance=int(values.get("cash_balance", 0)),
                rebate_reserve=int(values.get("rebate_reserve", 0)),
                fee_incentive_balance=int(values.get("fee_incentive_balance", 0)),
                trading_loss_rebate_rate=int(values.get("trading_loss_rebate_rate", 0)),
                liquidation_ltv=int(values.get("liquidation_ltv", 0)),
                max_admission_leverage=int(values.get("max_admission_leverage", 0)),
                backing_buffer_lambda=int(values.get("backing_buffer_lambda", 0)),
                expiry_fee_window_ms=int(values.get("expiry_fee_window_ms", 0)),
                expiry_fee_max_multiplier=int(values.get("expiry_fee_max_multiplier", 0)),
                tick_size=int(values.get("tick_size", 0)),
                admission_tick_size=int(values.get("admission_tick_size", 0)),
                reference_tick=values.get("reference_tick"),
                reference_tick_source_timestamp_ms=int(values.get("reference_tick_source_timestamp_ms", 0)),
                payout_liability=int(values.get("payout_liability", 0)),
            )

        asset_oracle = oracle_values.get("__asset__", {})
        oracles: dict[str, MarketOracleSnapshot] = {}
        for market_id in request.market_ids:
            market_oracle = oracle_values.get(market_id, {})
            oracles[market_id] = MarketOracleSnapshot(
                pyth=asset_oracle.get("pyth", OracleReadSnapshot(False)),
                bs_spot=asset_oracle.get("bs_spot", OracleReadSnapshot(False)),
                bs_forward=market_oracle.get("bs_forward", OracleReadSnapshot(False)),
                bs_svi=market_oracle.get("bs_svi", OracleReadSnapshot(False)),
            )

        return OnchainSnapshot(pool, markets, oracles)


def _shared(ptb: Ptb, client: SuiReadClient, object_id: str, mutable: bool = False) -> bytes:
    return ptb.shared_object(object_id, client.shared_isv(object_id), mutable)


def _return_bytes(result: dict[str, Any]) -> bytes:
    values = result.get("returnValues") or []
    if not values:
        return b""
    first = values[0]
    raw = first[0] if isinstance(first, list) and first else first
    return bytes(raw)
