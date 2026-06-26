from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from ._http import get_json

# Thin HTTP client for the public Predict indexer/server (deepbook-services).
# Complements SuiRpcObjectReader: the RPC reader gives current object state, the
# indexer gives history/aggregates from indexed events. Every call is best-effort
# and degrades gracefully (health.reachable=False / markets() -> []) so the CLI
# never fails just because the indexer is down.

# (url, timeout) -> parsed JSON
Transport = Callable[[str, float], Any]


@dataclass(frozen=True)
class IndexerHealth:
    reachable: bool
    ok: bool
    max_checkpoint_lag: int | None
    max_time_lag_seconds: int | None
    max_lag_pipeline: str | None
    latest_onchain_checkpoint: int | None


class PredictIndexerClient:
    def __init__(self, base_url: str, *, transport: Transport | None = None, timeout: float = 10):
        self.base_url = base_url.rstrip("/")
        self.transport = transport or get_json
        self.timeout = timeout

    def health(self) -> IndexerHealth:
        # Fail open: a transport error OR a reachable-but-malformed response
        # (non-object body, junk pipelines) degrades to "unreachable" instead of
        # raising, so a misbehaving indexer never crashes the CLI.
        try:
            payload = self.transport(f"{self.base_url}/status", self.timeout)
            pipelines = payload.get("pipelines") or []
            checkpoint_lags = [p["checkpoint_lag"] for p in pipelines if "checkpoint_lag" in p]
            time_lags = [p["time_lag_seconds"] for p in pipelines if "time_lag_seconds" in p]
            return IndexerHealth(
                reachable=True,
                ok=payload.get("status") == "OK",
                max_checkpoint_lag=max(checkpoint_lags) if checkpoint_lags else None,
                max_time_lag_seconds=max(time_lags) if time_lags else None,
                max_lag_pipeline=payload.get("max_lag_pipeline"),
                latest_onchain_checkpoint=payload.get("latest_onchain_checkpoint"),
            )
        except Exception:
            return IndexerHealth(False, False, None, None, None, None)

    def markets(self, *, limit: int = 50, expiry_market_id: str | None = None) -> list[dict[str, Any]]:
        query = f"?limit={int(limit)}"
        if expiry_market_id is not None:
            query += f"&expiry_market_id={expiry_market_id}"
        try:
            payload = self.transport(f"{self.base_url}/markets{query}", self.timeout)
        except Exception:
            return []
        return payload if isinstance(payload, list) else []
