from __future__ import annotations

import json
import urllib.request
from typing import Any, Callable


Transport = Callable[[str, dict[str, Any], float], dict[str, Any]]


class SuiRpcObjectReader:
    def __init__(
        self,
        rpc_url: str,
        *,
        transport: Transport | None = None,
        timeout: float = 10,
    ):
        self.rpc_url = rpc_url
        self.transport = transport or _post_json
        self.timeout = timeout

    def get_object(self, object_id: str) -> dict[str, Any] | None:
        payload = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "sui_getObject",
            "params": [
                object_id,
                {
                    "showContent": True,
                    "showType": True,
                    "showOwner": True,
                    "showPreviousTransaction": False,
                    "showStorageRebate": False,
                    "showDisplay": False,
                },
            ],
        }
        response = self.transport(self.rpc_url, payload, self.timeout)
        if response.get("error") is not None:
            raise RuntimeError(response["error"])
        result = response.get("result")
        if not isinstance(result, dict):
            return None
        return result if result.get("data") is not None else None

    def multi_get_objects(self, object_ids: list[str]) -> dict[str, dict[str, Any] | None]:
        """Batch many object reads into one sui_multiGetObjects call.

        Returns {requested_id: {"data": ...} | None}, keyed by the exact id passed
        (the RPC preserves request order, so no address-normalization mismatch).
        """
        if not object_ids:
            return {}
        payload = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "sui_multiGetObjects",
            "params": [
                object_ids,
                {"showContent": True, "showType": True, "showOwner": True},
            ],
        }
        response = self.transport(self.rpc_url, payload, self.timeout)
        if response.get("error") is not None:
            raise RuntimeError(response["error"])
        results = response.get("result") or []
        out: dict[str, dict[str, Any] | None] = {}
        for object_id, entry in zip(object_ids, results):
            data = entry.get("data") if isinstance(entry, dict) else None
            out[object_id] = {"data": data} if data is not None else None
        return out

    def get_dynamic_field_object(
        self,
        parent_id: str,
        name_type: str,
        name_value: str,
    ) -> dict[str, Any] | None:
        payload = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "suix_getDynamicFieldObject",
            "params": [
                parent_id,
                {
                    "type": name_type,
                    "value": name_value,
                },
            ],
        }
        response = self.transport(self.rpc_url, payload, self.timeout)
        if response.get("error") is not None:
            raise RuntimeError(response["error"])
        result = response.get("result")
        if not isinstance(result, dict):
            return None
        return result if result.get("data") is not None else None


def _post_json(url: str, payload: dict[str, Any], timeout: float) -> dict[str, Any]:
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))
