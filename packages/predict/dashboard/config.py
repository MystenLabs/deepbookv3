from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from constants import CADENCE_PERIOD_MS, DEFAULT_PREDICT_INDEXER_URL


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
    feed_ids: FeedIds


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


@dataclass(frozen=True)
class DeploymentConfig:
    network: str
    chain_id: str
    packages: dict[str, str]
    shared_objects: dict[str, dict[str, str]]
    assets: dict[str, AssetConfig]
    cadences: dict[int, CadenceConfig]
    predict_indexer_url: str

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "DeploymentConfig":
        wiring = data.get("wiring", {})
        asset_data = wiring.get("asset", {})
        asset = AssetConfig(
            name=asset_data["name"],
            propbook_underlying_id=int(asset_data["propbookUnderlyingId"]),
            feed_ids=FeedIds(
                pyth=asset_data["pythFeedId"],
                bs_spot=asset_data["blockScholesSpotFeedId"],
                bs_forward=asset_data["blockScholesForwardFeedId"],
                bs_svi=asset_data["blockScholesSviFeedId"],
            ),
        )

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

        servers = dict(data.get("servers", {}))
        return cls(
            network=data["network"],
            chain_id=data["chainId"],
            packages=dict(data["packages"]),
            shared_objects={
                package: dict(objects)
                for package, objects in data["sharedObjects"].items()
            },
            assets={asset.name: asset},
            cadences=cadences,
            predict_indexer_url=servers.get("predict", DEFAULT_PREDICT_INDEXER_URL),
        )

    def package_id(self, name: str) -> str:
        return self.packages[name]

    def shared_object_id(self, package: str, object_type: str) -> str:
        return self.shared_objects[package][object_type]

    def asset(self, name: str) -> AssetConfig:
        return self.assets[name]


def deployment_path() -> Path:
    return Path(__file__).resolve().parents[1] / "deployment" / "deployment.testnet.json"


def load_testnet_config(path: str | Path | None = None) -> DeploymentConfig:
    target = Path(path) if path is not None else deployment_path()
    return DeploymentConfig.from_dict(json.loads(target.read_text()))
