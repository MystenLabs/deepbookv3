from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from net import get_json


@dataclass(frozen=True)
class IndexerHealth:
    reachable: bool
    ok: bool
    max_checkpoint_lag: int | None
    max_time_lag_seconds: int | None
    max_lag_pipeline: str | None
    latest_onchain_checkpoint: int | None


class PredictIndexerClient:
    def __init__(self, base_url: str, *, timeout: float = 10):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def health(self) -> IndexerHealth:
        try:
            payload = get_json(f"{self.base_url}/status", self.timeout)
            pipelines = payload.get("pipelines") or []
            checkpoint_lags = [
                p["checkpoint_lag"] for p in pipelines if "checkpoint_lag" in p
            ]
            time_lags = [
                p["time_lag_seconds"] for p in pipelines if "time_lag_seconds" in p
            ]
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

    def markets(
        self,
        *,
        limit: int = 50,
        expiry_market_id: str | None = None,
        start_time_s: int | None = None,
    ) -> list[dict[str, Any]]:
        query = f"?limit={int(limit)}"
        if start_time_s is not None:
            query += f"&start_time={int(start_time_s)}"
        if expiry_market_id is not None:
            query += f"&expiry_market_id={expiry_market_id}"
        try:
            payload = get_json(f"{self.base_url}/markets{query}", self.timeout)
        except Exception:
            return []
        return payload if isinstance(payload, list) else []

    def market_state(self, expiry_market_id: str) -> dict[str, Any]:
        try:
            payload = get_json(
                f"{self.base_url}/markets/{expiry_market_id}/state",
                self.timeout,
            )
        except Exception:
            return {}
        return payload if isinstance(payload, dict) else {}
