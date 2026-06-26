from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from ._http import get_json

# HTTP clients for the public Predict indexer/server and oracle service — the SDK's
# read/data plane (markets, market/vault/config state, positions, oracle freshness).
# The chain is used only for execution (dry-run, submit, refs). Every call is
# best-effort and degrades gracefully (health.reachable=False / markets() -> []) so
# observe commands surface "unavailable" rather than crashing on an indexer outage.

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
            payload = self.transport(f"{self.base_url}/markets{query}", self.timeout)
        except Exception:
            return []
        return payload if isinstance(payload, list) else []

    def managers(self, *, owner: str | None = None, limit: int = 50) -> list[dict[str, Any]]:
        """Created managers (AccountWrappers), optionally filtered by owner address."""
        query = f"?limit={int(limit)}"
        if owner is not None:
            query += f"&owner={owner}"
        try:
            payload = self.transport(f"{self.base_url}/managers{query}", self.timeout)
        except Exception:
            return []
        return payload if isinstance(payload, list) else []

    def manager_orders(
        self, manager_id: str, *, limit: int = 500, end_time_s: int | None = None
    ) -> list[dict[str, Any]]:
        """One page of a manager's interleaved order feed (newest first).

        `end_time_s` is an upper-bound unix timestamp in SECONDS (the server multiplies
        by 1000); pass it to walk older pages. Fails open to [] like the other calls.
        """
        query = f"?limit={int(limit)}"
        if end_time_s is not None:
            query += f"&end_time={int(end_time_s)}"
        try:
            payload = self.transport(
                f"{self.base_url}/managers/{manager_id}/orders{query}", self.timeout
            )
        except Exception:
            return []
        return payload if isinstance(payload, list) else []

    def market_state(self, expiry_market_id: str) -> dict[str, Any]:
        """Current per-market snapshot (market/config/mint_paused/settlement)."""
        return self._object(f"/markets/{expiry_market_id}/state")

    def vault_state(self, pool_vault_id: str) -> dict[str, Any]:
        """Current pool-vault snapshot (idle/reserve/total-supply under `current`)."""
        return self._object(f"/vaults/{pool_vault_id}/state")

    def protocol_config(self) -> dict[str, Any]:
        """Latest protocol config snapshot (gates + oracle freshness thresholds)."""
        return self._object("/config")

    def _object(self, path: str) -> dict[str, Any]:
        try:
            payload = self.transport(f"{self.base_url}{path}", self.timeout)
        except Exception:
            return {}
        return payload if isinstance(payload, dict) else {}


class OracleClient:
    """Thin client for the public oracle service (block-scholes-oracle), keyed by
    `propbook_oracle_id`. Resolve the oracle id from the underlying binding, then read
    the latest pyth + block-scholes observations for freshness. Fails open like
    PredictIndexerClient so the status path never crashes on an oracle outage.
    """

    def __init__(self, base_url: str, *, transport: Transport | None = None, timeout: float = 10):
        self.base_url = base_url.rstrip("/")
        self.transport = transport or get_json
        self.timeout = timeout

    def underlying_binding(self, propbook_underlying_id: int) -> dict[str, Any]:
        """The oracle bound to an underlying; carries `propbook_oracle_id`."""
        try:
            payload = self.transport(
                f"{self.base_url}/underlyings/{int(propbook_underlying_id)}/binding", self.timeout
            )
        except Exception:
            return {}
        return payload if isinstance(payload, dict) else {}

    def pyth_latest(self, propbook_oracle_id: str) -> dict[str, Any]:
        try:
            payload = self.transport(
                f"{self.base_url}/oracles/{propbook_oracle_id}/pyth/latest", self.timeout
            )
        except Exception:
            return {}
        return payload if isinstance(payload, dict) else {}

    def block_scholes_latest(self, propbook_oracle_id: str) -> dict[str, Any]:
        """Newest block-scholes observation (the surface has no /latest endpoint)."""
        try:
            payload = self.transport(
                f"{self.base_url}/oracles/{propbook_oracle_id}/block-scholes?limit=1", self.timeout
            )
        except Exception:
            return {}
        rows = payload if isinstance(payload, list) else []
        return rows[0] if rows else {}
