from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .constants import CADENCE_PERIOD_MS


@dataclass(frozen=True)
class FeedIds:
    pyth: str
    bs_spot: str
    bs_forward: str
    bs_svi: str


@dataclass(frozen=True)
class AssetConfig:
    name: str
    propbook_underlying_id: int
    pyth_lazer_feed_id: int
    block_scholes_source_id: int
    feed_ids: FeedIds

    @property
    def pyth_feed_id(self) -> str:
        return self.feed_ids.pyth


@dataclass(frozen=True)
class CadenceConfig:
    id: int
    name: str
    tick_size: int
    admission_tick_size: int
    max_expiry_allocation: int
    initial_expiry_cash: int
    window_size: int

    @property
    def period_ms(self) -> int:
        return CADENCE_PERIOD_MS[self.id]

    @property
    def admission_grid_ticks(self) -> int:
        """Valid finite ticks are multiples of this (admission_tick_size / tick_size)."""
        return self.admission_tick_size // self.tick_size if self.tick_size else 0


@dataclass(frozen=True)
class DeploymentConfig:
    network: str
    chain_id: str
    packages: dict[str, str]
    linked: dict[str, str]
    shared_objects: dict[str, dict[str, str]]
    # The manifest currently wires a single asset (BTC_USD). The dict + `asset(name)`
    # API is kept multi-asset-shaped so adding assets later needs no API change.
    assets: dict[str, AssetConfig]
    # Keyed by cadence id; `cadence()` also accepts the short name (e.g. "5m").
    cadences: dict[int, CadenceConfig]
    # Public indexer/server base URLs keyed by service ("predict", "propbook").
    servers: dict[str, str] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "DeploymentConfig":
        wiring = data.get("wiring", {})
        asset_data = wiring.get("asset", {})
        assets = {
            asset_data["name"]: AssetConfig(
                name=asset_data["name"],
                propbook_underlying_id=int(asset_data["propbookUnderlyingId"]),
                pyth_lazer_feed_id=int(asset_data["pythLazerFeedId"]),
                block_scholes_source_id=int(asset_data["blockScholesSourceId"]),
                feed_ids=FeedIds(
                    pyth=asset_data["pythFeedId"],
                    bs_spot=asset_data["blockScholesSpotFeedId"],
                    bs_forward=asset_data["blockScholesForwardFeedId"],
                    bs_svi=asset_data["blockScholesSviFeedId"],
                ),
            )
        }

        cadences: dict[int, CadenceConfig] = {}
        for cadence_data in wiring.get("cadences", []):
            cadence = CadenceConfig(
                id=int(cadence_data["id"]),
                name=cadence_data["name"],
                tick_size=int(cadence_data["tickSize"]),
                admission_tick_size=int(cadence_data["admissionTickSize"]),
                max_expiry_allocation=int(cadence_data["maxExpiryAllocation"]),
                initial_expiry_cash=int(cadence_data["initialExpiryCash"]),
                window_size=int(cadence_data["windowSize"]),
            )
            cadences[cadence.id] = cadence

        return cls(
            network=data["network"],
            chain_id=data["chainId"],
            packages=dict(data["packages"]),
            linked=dict(data["linked"]),
            shared_objects={
                package: dict(objects)
                for package, objects in data["sharedObjects"].items()
            },
            assets=assets,
            cadences=cadences,
            servers=dict(data.get("servers", {})),
        )

    def package_id(self, name: str) -> str:
        return self.packages[name]

    def linked_package_id(self, name: str) -> str:
        return self.linked[name]

    def shared_object_id(self, package: str, object_type: str) -> str:
        return self.shared_objects[package][object_type]

    def asset(self, name: str) -> AssetConfig:
        return self.assets[name]

    def cadence(self, key: int | str) -> CadenceConfig:
        if isinstance(key, str):
            return next(c for c in self.cadences.values() if c.name == key)
        return self.cadences[key]

    def server_url(self, name: str) -> str | None:
        return self.servers.get(name)


# The SDK reads the canonical deployment manifest as its single source of wiring.
# Wheels bundle a copy at predict_sdk/deployments/testnet.json (pyproject
# force-include); editable/in-repo installs fall back to the canonical artifact.
_PACKAGED_DEPLOYMENT = Path(__file__).parent / "deployments" / "testnet.json"
_CANONICAL_DEPLOYMENT = (
    Path(__file__).resolve().parents[2] / "deployment" / "deployment.testnet.json"
)
# Public service endpoints are an SDK-side overlay; the deployment manifest does
# not carry them.
_TESTNET_SERVERS = {
    "predict": "https://predict-server-beta.testnet.mystenlabs.com",
    "propbook": "https://propbook.api.testnet.mystenlabs.com",
}


def load_testnet_config() -> DeploymentConfig:
    path = _PACKAGED_DEPLOYMENT if _PACKAGED_DEPLOYMENT.exists() else _CANONICAL_DEPLOYMENT
    data = json.loads(path.read_text())
    data.setdefault("servers", _TESTNET_SERVERS)
    return DeploymentConfig.from_dict(data)
