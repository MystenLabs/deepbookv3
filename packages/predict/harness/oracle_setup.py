"""Post-publish oracle/account initialization (mirrors run.sh's setup calls).

Turns a freshly-published localnet into an oracle+account-ready one via single
`sui client call`s: generate local Pyth keys, init Wormhole + Pyth Lazer, authorize
the Predict app, and write a run.sh-format `.env.localnet` so the harness TS layer
(harness/ts/runtime.ts) can drive the trusted-signer VAA, feeds, and refresh.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any

from . import config, suicli
from .publish import _created


def _call(
    client_config: Path,
    package: str,
    module: str,
    function: str,
    args: list[Any],
    type_args: list[str] | None = None,
) -> list[dict]:
    a = ["call", "--package", package, "--module", module, "--function", function]
    for t in type_args or []:
        a += ["--type-args", t]
    a += ["--args", *[str(x) for x in args]]
    a += ["--gas-budget", str(config.GAS_BUDGET), "--json"]
    cp = suicli.client(client_config, a, check=False)
    if cp.returncode != 0:
        raise suicli.SuiError(f"{module}::{function} call failed:\n{cp.stderr.strip()[:1500]}")
    return suicli.parse_json_lenient(cp.stdout).get("objectChanges") or []


def generate_local_pyth(out_path: Path) -> dict:
    """Run the harness localPythCli (tsx) to mint local guardian/signer keys."""
    subprocess.run(
        ["npx", "tsx", "localPythCli.ts", str(out_path)],
        cwd=str(config.TS_DIR),
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(out_path.read_text())


def initialize(
    client_config: Path,
    deployment: dict,
    instance_dir: Path,
    rpc_port: int,
    active_address: str,
) -> dict:
    """Init Wormhole + Pyth Lazer + authorize the app; record states; write .env.localnet."""
    pkgs, objs = deployment["packages"], deployment["objects"]
    lp = generate_local_pyth(instance_dir / "local_pyth.json")

    wch = _call(
        client_config, pkgs["wormhole"], "setup", "complete",
        [
            objs["wormhole_deployer_cap"], objs["wormhole_upgrade_cap"],
            lp["governanceChain"], lp["governanceContract"], 0,
            f'[{lp["guardianAddress"]}]', 86400, 0,
        ],
    )
    objs["wormhole_state"] = _created(wch, "state::State")

    pch = _call(
        client_config, pkgs["pyth_lazer"], "actions", "init_lazer",
        [objs["pyth_lazer_upgrade_cap"], lp["governanceChain"], lp["governanceContract"]],
    )
    objs["pyth_lazer_state"] = _created(pch, "state::State")

    _call(
        client_config, pkgs["account"], "account_registry", "authorize_app",
        [objs["account_registry"], objs["account_admin_cap"]],
        type_args=[f'{pkgs["predict"]}::predict_account::PredictApp'],
    )

    deployment["local_pyth"] = lp
    write_env_localnet(instance_dir, deployment, rpc_port, active_address)
    return deployment


def write_env_localnet(instance_dir: Path, deployment: dict, rpc_port: int, active_address: str) -> None:
    p, o, lp = deployment["packages"], deployment["objects"], deployment["local_pyth"]
    env = {
        "PACKAGE_ID": p["predict"],
        "REGISTRY_ID": o["registry"],
        "ADMIN_CAP_ID": o["admin_cap"],
        "PROTOCOL_CONFIG_ID": o["protocol_config"],
        "POOL_VAULT_ID": o["pool_vault"],
        "ACCOUNT_PACKAGE_ID": p["account"],
        "ACCOUNT_REGISTRY_ID": o["account_registry"],
        "ACCOUNT_ADMIN_CAP_ID": o["account_admin_cap"],
        "FIXED_MATH_PACKAGE_ID": p["fixed_math"],
        "BLOCK_SCHOLES_ORACLE_PACKAGE_ID": p["block_scholes_oracle"],
        "PROPBOOK_PACKAGE_ID": p["propbook"],
        "ORACLE_REGISTRY_ID": o["oracle_registry"],
        "ORACLE_REGISTRY_ADMIN_CAP_ID": o["oracle_registry_admin_cap"],
        "DUSDC_PACKAGE_ID": p["dusdc"],
        "DUSDC_CURRENCY_ID": o["dusdc_currency"],
        "TREASURY_CAP_ID": o["treasury_cap"],
        "WORMHOLE_PACKAGE_ID": p["wormhole"],
        "WORMHOLE_STATE_ID": o["wormhole_state"],
        "PYTH_LAZER_PACKAGE_ID": p["pyth_lazer"],
        "PYTH_LAZER_STATE_ID": o["pyth_lazer_state"],
        "LOCAL_PYTH_GOVERNANCE_CHAIN": lp["governanceChain"],
        "LOCAL_PYTH_GOVERNANCE_CONTRACT": lp["governanceContract"],
        "LOCAL_PYTH_RECEIVER_CHAIN": lp["receiverChain"],
        "LOCAL_PYTH_GUARDIAN_PRIVATE_KEY": lp["guardianPrivateKey"],
        "LOCAL_PYTH_SIGNER_PRIVATE_KEY": lp["signerPrivateKey"],
        "LOCAL_PYTH_SIGNER_PUBLIC_KEY": lp["signerPublicKey"],
        "LOCAL_PYTH_SIGNER_EXPIRES_AT_SECONDS": lp["signerExpiresAtSeconds"],
        "ACTIVE_ADDRESS": active_address,
        "RPC_URL": f"http://127.0.0.1:{rpc_port}",
        "KEYSTORE_PATH": str(instance_dir / "localnet" / "sui.keystore"),
    }
    (instance_dir / ".env.localnet").write_text("".join(f"{k}={v}\n" for k, v in env.items()))
