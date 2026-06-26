from __future__ import annotations

import json
import os
from dataclasses import dataclass

from .bcs import Ptb, arg_nested_result, arg_result
from .config import DeploymentConfig, load_testnet_config
from .constants import ACCUMULATOR_ROOT_ID, CLOCK_ID
from .signer import Signer, load_signer
from .tx import TransactionClient, TxResult

# High-level Predict trader actions. Abstracts away every protocol nuance the user
# should not have to know: the owner `Auth` hot-potato, the shared AccountWrapper
# (custody) lifecycle and discovery, DUSDC coin splitting, the AccumulatorRoot +
# Clock plumbing, and the load_live_pricer -> mint two-step for trading.


@dataclass(frozen=True)
class Markets:
    """Resolved object ids / type tags for one asset, pulled from the deployment config."""
    pool_vault: str
    protocol_config: str
    oracle_registry: str
    account_registry: str
    pyth: str
    bs_spot: str
    bs_forward: str
    bs_svi: str
    predict_pkg: str
    account_pkg: str
    dusdc_type: str
    plp_type: str

    @classmethod
    def from_config(cls, config: DeploymentConfig, asset: str = "BTC_USD") -> "Markets":
        a = config.asset(asset)
        return cls(
            pool_vault=config.shared_object_id("predict", "plp::PoolVault"),
            protocol_config=config.shared_object_id("predict", "protocol_config::ProtocolConfig"),
            oracle_registry=config.shared_object_id("propbook", "registry::OracleRegistry"),
            account_registry=config.shared_object_id("account", "account_registry::AccountRegistry"),
            pyth=a.feed_ids.pyth, bs_spot=a.feed_ids.bs_spot,
            bs_forward=a.feed_ids.bs_forward, bs_svi=a.feed_ids.bs_svi,
            predict_pkg=config.package_id("predict"),
            account_pkg=config.package_id("account"),
            dusdc_type=config.linked_package_id("dusdc") + "::dusdc::DUSDC",
            plp_type=config.package_id("predict") + "::plp::PLP",
        )


class PredictActions:
    def __init__(
        self,
        signer: Signer,
        config: DeploymentConfig | None = None,
        *,
        rpc_url: str | None = None,
        asset: str = "BTC_USD",
        state_path: str | None = None,
    ):
        self.config = config or load_testnet_config()
        self.signer = signer
        self.client = (
            TransactionClient(signer, rpc_url) if rpc_url else TransactionClient(signer)
        )
        self.m = Markets.from_config(self.config, asset)
        self._state_path = state_path or os.path.join(
            os.path.dirname(os.path.dirname(__file__)), ".predict_state.json"
        )

    @classmethod
    def from_env(cls, **kwargs) -> "PredictActions":
        return cls(load_signer(), **kwargs)

    # === account lifecycle ===

    def account_wrapper_id(self) -> str | None:
        return self._state().get(self.signer.address)

    def ensure_account(self, *, execute: bool = True) -> str:
        """Return the signer's AccountWrapper id, creating + sharing it if needed."""
        existing = self.account_wrapper_id()
        if existing:
            return existing
        ptb = Ptb()
        registry = self._shared(ptb, self.m.account_registry, mutable=True)
        wrapper = ptb.move_call(self.m.account_pkg, "account_registry", "new", [], [registry])
        ptb.move_call(self.m.account_pkg, "account", "share", [], [arg_result(wrapper)])
        result = self.client.run(ptb, execute=execute)
        if execute and result.success:
            wrapper_id = _created_object(result, "::account::AccountWrapper")
            if wrapper_id:
                self._save_account(wrapper_id)
                return wrapper_id
        if not result.success:
            raise RuntimeError(f"account creation failed: {result.error}")
        return "<dry-run: not created>"

    def custody_balance(self, coin_type: str | None = None) -> int:
        """Return the raw balance held in the signer's AccountWrapper custody bag."""
        wrapper = self._require_account()
        coin_type = coin_type or self.m.dusdc_type
        obj = self.client._rpc(
            "sui_getObject",
            [wrapper, {"showContent": True, "showType": True}],
        )
        fields = _object_fields(obj)
        balances_id = _object_id(
            _fields(_fields(fields.get("account")).get("balances")).get("id")
        )
        if balances_id is None:
            return 0

        cursor = None
        while True:
            page = self.client._rpc("suix_getDynamicFields", [balances_id, cursor, 50])
            for item in page.get("data", []):
                if not _is_balance_field(item, coin_type):
                    continue
                entry = self.client._rpc(
                    "suix_getDynamicFieldObject",
                    [balances_id, item["name"]],
                )
                return _optional_int(_object_fields(entry).get("value")) or 0
            if not page.get("hasNextPage") or not page.get("nextCursor"):
                return 0
            cursor = page["nextCursor"]

    # === custody ===

    def deposit(self, amount: int, *, execute: bool = False, gas_coin: dict | None = None) -> TxResult:
        """Deposit `amount` (raw 6-dp DUSDC) from a wallet coin into account custody."""
        wrapper = self._require_account()
        coin = self._largest_coin(self.m.dusdc_type)
        ptb = Ptb()
        coin_input = ptb.owned_object(coin["coinObjectId"], int(coin["version"]), coin["digest"])
        split = ptb.split_coins(coin_input, [ptb.pure_u64(amount)])
        auth = ptb.move_call(self.m.account_pkg, "account", "generate_auth", [], [])
        ptb.move_call(
            self.m.account_pkg, "account", "deposit_funds", [self.m.dusdc_type],
            [self._shared(ptb, wrapper, True), arg_result(auth), arg_nested_result(split, 0),
             self._root(ptb), self._clock(ptb)],
        )
        return self.client.run(ptb, execute=execute, gas_coin=gas_coin)

    def withdraw(
        self, amount: int, *, coin_type: str | None = None,
        execute: bool = False, gas_coin: dict | None = None,
    ) -> TxResult:
        wrapper = self._require_account()
        coin_type = coin_type or self.m.dusdc_type
        ptb = Ptb()
        auth = ptb.move_call(self.m.account_pkg, "account", "generate_auth", [], [])
        withdrawn = ptb.move_call(
            self.m.account_pkg, "account", "withdraw_funds", [coin_type],
            [self._shared(ptb, wrapper, True), arg_result(auth), ptb.pure_u64(amount),
             self._root(ptb), self._clock(ptb)],
        )
        ptb.transfer_objects([arg_result(withdrawn)], ptb.pure_address(self.signer.address))
        return self.client.run(ptb, execute=execute, gas_coin=gas_coin)

    # === trading ===

    def mint(
        self,
        market_id: str,
        *,
        lower_tick: int,
        higher_tick: int,
        quantity: int,
        leverage: int,
        max_cost: int,
        max_probability: int,
        execute: bool = False,
        gas_coin: dict | None = None,
    ) -> TxResult:
        """Mint a live range position (mint_exact_quantity), pricing it in the same PTB."""
        wrapper = self._require_account()
        ptb = Ptb()
        pricer = ptb.move_call(
            self.m.predict_pkg, "expiry_market", "load_live_pricer", [],
            [self._shared(ptb, market_id, True), self._shared(ptb, self.m.protocol_config, False),
             self._shared(ptb, self.m.oracle_registry, False), self._shared(ptb, self.m.pyth, False),
             self._shared(ptb, self.m.bs_spot, False), self._shared(ptb, self.m.bs_forward, False),
             self._shared(ptb, self.m.bs_svi, False), self._clock(ptb)],
        )
        auth = ptb.move_call(self.m.account_pkg, "account", "generate_auth", [], [])
        ptb.move_call(
            self.m.predict_pkg, "expiry_market", "mint_exact_quantity", [],
            [self._shared(ptb, market_id, True), self._shared(ptb, wrapper, True), arg_result(auth),
             self._shared(ptb, self.m.protocol_config, False), arg_result(pricer),
             ptb.pure_u64(lower_tick), ptb.pure_u64(higher_tick), ptb.pure_u64(quantity),
             ptb.pure_u64(leverage), ptb.pure_u64(max_cost), ptb.pure_u64(max_probability),
             self._root(ptb), self._clock(ptb)],
        )
        return self.client.run(ptb, execute=execute, gas_coin=gas_coin)

    def redeem_live(
        self, market_id: str, order_id: int, close_quantity: int, *, execute: bool = False, gas_coin: dict | None = None
    ) -> TxResult:
        """Close (fully or partially) a live position at its current live value."""
        wrapper = self._require_account()
        ptb = Ptb()
        pricer = ptb.move_call(
            self.m.predict_pkg, "expiry_market", "load_live_pricer", [],
            [self._shared(ptb, market_id, True), self._shared(ptb, self.m.protocol_config, False),
             self._shared(ptb, self.m.oracle_registry, False), self._shared(ptb, self.m.pyth, False),
             self._shared(ptb, self.m.bs_spot, False), self._shared(ptb, self.m.bs_forward, False),
             self._shared(ptb, self.m.bs_svi, False), self._clock(ptb)],
        )
        auth = ptb.move_call(self.m.account_pkg, "account", "generate_auth", [], [])
        ptb.move_call(
            self.m.predict_pkg, "expiry_market", "redeem_live", [],
            [self._shared(ptb, market_id, True), self._shared(ptb, wrapper, True), arg_result(auth),
             self._shared(ptb, self.m.protocol_config, False), arg_result(pricer),
             ptb.pure_u256(order_id), ptb.pure_u64(close_quantity), self._root(ptb), self._clock(ptb)],
        )
        return self.client.run(ptb, execute=execute, gas_coin=gas_coin)

    def redeem_settled(
        self, market_id: str, order_id: int, close_quantity: int, *, execute: bool = False, gas_coin: dict | None = None
    ) -> TxResult:
        """Redeem a fully-closed position from a settled market (permissionless)."""
        wrapper = self._require_account()
        ptb = Ptb()
        ptb.move_call(
            self.m.predict_pkg, "expiry_market", "redeem_settled", [],
            [self._shared(ptb, market_id, True), self._shared(ptb, self.m.account_registry, False),
             self._shared(ptb, wrapper, True), self._shared(ptb, self.m.protocol_config, False),
             self._shared(ptb, self.m.oracle_registry, False), self._shared(ptb, self.m.pyth, False),
             ptb.pure_u256(order_id), ptb.pure_u64(close_quantity), self._root(ptb), self._clock(ptb)],
        )
        return self.client.run(ptb, execute=execute, gas_coin=gas_coin)

    def portfolio(self):
        from .portfolio import PortfolioReader
        return PortfolioReader(self.signer.address, self.m.predict_pkg, self.client.rpc_url).load()

    # === helpers ===

    def _shared(self, ptb: Ptb, object_id: str, mutable: bool) -> bytes:
        return ptb.shared_object(object_id, self.client.shared_isv(object_id), mutable)

    def _root(self, ptb: Ptb) -> bytes:
        return ptb.shared_object(ACCUMULATOR_ROOT_ID, self.client.shared_isv(ACCUMULATOR_ROOT_ID), False)

    def _clock(self, ptb: Ptb) -> bytes:
        return ptb.shared_object(CLOCK_ID, 1, False)

    def _largest_coin(self, coin_type: str) -> dict:
        coins = self.client.coins(coin_type)
        if not coins:
            raise RuntimeError(f"no {coin_type} coins owned by {self.signer.address}")
        return max(coins, key=lambda c: int(c["balance"]))

    def _require_account(self) -> str:
        wrapper = self.account_wrapper_id()
        if not wrapper:
            raise RuntimeError("no account; call ensure_account() first")
        return wrapper

    def _state(self) -> dict:
        if os.path.exists(self._state_path):
            with open(self._state_path) as handle:
                return json.load(handle)
        return {}

    def _save_account(self, wrapper_id: str) -> None:
        state = self._state()
        state[self.signer.address] = wrapper_id
        with open(self._state_path, "w") as handle:
            json.dump(state, handle, indent=2)


def _created_object(result: TxResult, type_suffix: str) -> str | None:
    for change in result.object_changes:
        if change.get("type") == "created" and change.get("objectType", "").endswith(type_suffix):
            return change.get("objectId")
    return None


def _object_fields(obj: dict | None) -> dict:
    current = obj
    if isinstance(current, dict) and "data" in current:
        current = current["data"]
    if isinstance(current, dict) and "content" in current:
        current = current["content"]
    return _fields(current)


def _fields(value) -> dict:
    if isinstance(value, dict) and isinstance(value.get("fields"), dict):
        return value["fields"]
    if isinstance(value, dict):
        return value
    return {}


def _object_id(value) -> str | None:
    if isinstance(value, str):
        return value
    if isinstance(value, dict) and isinstance(value.get("id"), str):
        return value["id"]
    return None


def _optional_int(value) -> int | None:
    if value is None:
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return int(value)
    if isinstance(value, dict):
        fields = _fields(value)
        if "value" in fields:
            return _optional_int(fields["value"])
    return None


def _is_balance_field(item: dict, coin_type: str) -> bool:
    object_type = str(item.get("objectType", ""))
    name = item.get("name")
    name_type = str(name.get("type", "")) if isinstance(name, dict) else ""
    return (
        object_type.endswith(f"::balance::Balance<{coin_type}>")
        or name_type.endswith(f"::account::CoinKey<{coin_type}>")
    )
