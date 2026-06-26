from __future__ import annotations

import base64
from dataclasses import dataclass, field
from typing import Any

from . import bcs
from ._http import post_json
from .bcs import Ptb
from .constants import DEFAULT_TESTNET_RPC_URL
from .signer import Signer

# Transaction executor: resolves object/gas refs over JSON-RPC, builds + signs the
# TransactionData (via bcs.py), and either dry-runs (default, safe) or executes.
# Gas budget is estimated from the dry run. Owned-object equivocation is avoided by
# never reusing a gas coin that's also a tx input (the gas pool in gas.py extends this).

_GAS_BUFFER = 2_000_000  # extra MIST headroom over the dry-run estimate


@dataclass
class TxResult:
    dry_run: bool
    success: bool
    status: str
    digest: str | None = None
    gas_used: int = 0
    effects: dict = field(default_factory=dict)
    events: list = field(default_factory=list)
    object_changes: list = field(default_factory=list)
    return_values: list = field(default_factory=list)
    error: str | None = None


class TransactionClient:
    def __init__(self, signer: Signer, rpc_url: str = DEFAULT_TESTNET_RPC_URL, *, timeout: float = 30):
        self.signer = signer
        self.rpc_url = rpc_url
        self.timeout = timeout
        self._isv_cache: dict[str, int] = {}

    # === ref resolution ===

    def shared_isv(self, object_id: str) -> int:
        if object_id not in self._isv_cache:
            owner = self._object(object_id, {"showOwner": True})["owner"]
            self._isv_cache[object_id] = int(owner["Shared"]["initial_shared_version"])
        return self._isv_cache[object_id]

    def owned_ref(self, object_id: str) -> tuple[int, str]:
        data = self._object(object_id, {"showOwner": True})
        return int(data["version"]), data["digest"]

    def coins(self, coin_type: str, owner: str | None = None) -> list[dict]:
        owner = owner or self.signer.address
        result = self._rpc("suix_getCoins", [owner, coin_type, None, 50])
        return result.get("data", [])

    def reference_gas_price(self) -> int:
        return int(self._rpc("suix_getReferenceGasPrice", []))

    def pick_gas_coin(self, exclude: set[str] | None = None) -> dict:
        exclude = exclude or set()
        candidates = [c for c in self.coins("0x2::sui::SUI") if c["coinObjectId"] not in exclude]
        if not candidates:
            raise RuntimeError("no SUI gas coin available")
        return max(candidates, key=lambda c: int(c["balance"]))

    # === run ===

    def run(
        self,
        ptb: Ptb,
        *,
        execute: bool = False,
        gas_budget: int | None = None,
        gas_coin: dict | None = None,
    ) -> TxResult:
        gas_price = self.reference_gas_price()
        gas_coin = gas_coin or self.pick_gas_coin()
        gas_ref = (gas_coin["coinObjectId"], int(gas_coin["version"]), gas_coin["digest"])

        # Dry run first to validate + estimate gas. The probe budget must not exceed
        # the gas coin's balance (the node rejects a budget the coin can't cover),
        # which matters for small pooled gas coins used in parallel execution.
        probe_budget = min(5_000_000_000, int(gas_coin["balance"]))
        probe = bcs.build_transaction_data(
            self.signer.address, ptb, [gas_ref], self.signer.address, gas_price, probe_budget
        )
        dry = self._dry_run(probe)
        status = dry.get("effects", {}).get("status", {})
        if status.get("status") != "success":
            return TxResult(
                dry_run=True, success=False, status=status.get("status", "failure"),
                effects=dry.get("effects", {}), error=status.get("error"),
            )
        estimated = _gas_total(dry["effects"]["gasUsed"]) + _GAS_BUFFER
        budget = gas_budget or estimated

        if not execute:
            return TxResult(
                dry_run=True, success=True, status="success",
                gas_used=_gas_total(dry["effects"]["gasUsed"]),
                effects=dry.get("effects", {}), events=dry.get("events", []),
                object_changes=dry.get("objectChanges", []),
            )

        tx_bytes = bcs.build_transaction_data(
            self.signer.address, ptb, [gas_ref], self.signer.address, gas_price, budget
        )
        signature = self.signer.sign_transaction(tx_bytes)
        result = self._rpc(
            "sui_executeTransactionBlock",
            [
                base64.b64encode(tx_bytes).decode("ascii"),
                [signature],
                {"showEffects": True, "showEvents": True, "showObjectChanges": True},
                "WaitForLocalExecution",
            ],
        )
        effects = result.get("effects", {})
        exec_status = effects.get("status", {})
        return TxResult(
            dry_run=False,
            success=exec_status.get("status") == "success",
            status=exec_status.get("status", "failure"),
            digest=result.get("digest"),
            gas_used=_gas_total(effects.get("gasUsed", {})),
            effects=effects,
            events=result.get("events", []),
            object_changes=result.get("objectChanges", []),
            error=exec_status.get("error"),
        )

    # === rpc plumbing ===

    def _object(self, object_id: str, options: dict) -> dict:
        result = self._rpc("sui_getObject", [object_id, options])
        data = result.get("data")
        if data is None:
            raise RuntimeError(f"object not found: {object_id}")
        return data

    def _dry_run(self, tx_bytes: bytes) -> dict:
        return self._rpc("sui_dryRunTransactionBlock", [base64.b64encode(tx_bytes).decode("ascii")])

    def _rpc(self, method: str, params: list) -> Any:
        body = post_json(
            self.rpc_url,
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
            self.timeout,
        )
        if body.get("error") is not None:
            raise RuntimeError(f"RPC {method} error: {body['error']}")
        return body["result"]


def _gas_total(gas_used: dict) -> int:
    return (
        int(gas_used.get("computationCost", 0))
        + int(gas_used.get("storageCost", 0))
        - int(gas_used.get("storageRebate", 0))
    )
