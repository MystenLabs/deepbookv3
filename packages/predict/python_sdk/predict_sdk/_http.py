from __future__ import annotations

import json
import urllib.request
from typing import Any

# Shared low-level HTTP transport for the SDK: one JSON POST helper (every Sui
# JSON-RPC caller) and one JSON GET helper (the indexer client), so the urllib
# boilerplate lives in exactly one place. Callers layer the JSON-RPC envelope and
# error handling on top.


def post_json(url: str, payload: dict[str, Any], timeout: float) -> Any:
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url, data=body, headers={"content-type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def get_json(url: str, timeout: float) -> Any:
    request = urllib.request.Request(url, headers={"accept": "application/json"}, method="GET")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))
