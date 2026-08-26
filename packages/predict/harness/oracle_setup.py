"""Post-publish oracle/account initialization.

Turns a freshly-published localnet into an oracle+account-ready one via single
`sui client call`s: generate local Pyth keys, init Wormhole + Pyth Lazer, authorize
the Predict app, and write the private `.env.localnet` so the harness TS layer
(packages/predict/devtools/ts/runtime.ts) can drive the trusted-signer VAA, feeds, and refresh.
"""

from __future__ import annotations

import json
import os
import threading
from pathlib import Path
from typing import Any

from . import cancellation, config, suicli
from .publish import _created


def _call(
    client_config: Path,
    package: str,
    module: str,
    function: str,
    args: list[Any],
    type_args: list[str] | None = None,
    cancel_event: threading.Event | None = None,
) -> list[dict]:
    a = ["call", "--package", package, "--module", module, "--function", function]
    for t in type_args or []:
        a += ["--type-args", t]
    a += ["--args", *[str(x) for x in args]]
    a += ["--gas-budget", str(config.GAS_BUDGET), "--json"]
    cp = suicli.client(
        client_config,
        a,
        check=False,
        cancel_event=cancel_event,
    )
    if cp.returncode != 0:
        raise suicli.SuiError(f"{module}::{function} call failed:\n{cp.stderr.strip()[:1500]}")
    return suicli.parse_json_lenient(cp.stdout).get("objectChanges") or []


def generate_local_pyth(
    cancel_event: threading.Event | None = None,
) -> dict:
    """Run the harness localPythCli (tsx) to mint local guardian/signer keys."""
    completed = cancellation.run(
        ["npx", "tsx", "devtools/ts/localPythCli.ts"],
        cancel_event=cancel_event,
        check_result=True,
        cwd=str(config.PREDICT_DIR),
        capture_output=True,
        text=True,
    )
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("local signer generator emitted invalid JSON") from exc


def initialize(
    client_config: Path,
    deployment: dict,
    instance_dir: Path,
    rpc_port: int,
    active_address: str,
    cancel_event: threading.Event | None = None,
) -> dict:
    """Init Wormhole + Pyth Lazer + authorize the app; record states; write .env.localnet."""
    pkgs, objs = deployment["packages"], deployment["objects"]
    lp = generate_local_pyth(cancel_event)

    wch = _call(
        client_config, pkgs["wormhole"], "setup", "complete",
        [
            objs["wormhole_deployer_cap"], objs["wormhole_upgrade_cap"],
            lp["governanceChain"], lp["governanceContract"], 0,
            f'[{lp["guardianAddress"]}]', 86400, 0,
        ],
        cancel_event=cancel_event,
    )
    objs["wormhole_state"] = _created(wch, "state::State")

    pch = _call(
        client_config, pkgs["pyth_lazer"], "actions", "init_lazer",
        [objs["pyth_lazer_upgrade_cap"], lp["governanceChain"], lp["governanceContract"]],
        cancel_event=cancel_event,
    )
    objs["pyth_lazer_state"] = _created(pch, "state::State")

    write_env_localnet(instance_dir, deployment, lp, rpc_port, active_address)
    return deployment


def write_env_localnet(
    instance_dir: Path,
    deployment: dict,
    local_signers: dict,
    rpc_port: int,
    active_address: str,
) -> None:
    p, o, lp = deployment["packages"], deployment["objects"], local_signers
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
        "BS_SIGNER_REGISTRY_ID": o["bs_signer_registry"],
        "BS_ADMIN_CAP_ID": o["bs_admin_cap"],
        "LOCAL_BS_SIGNER_PRIVATE_KEY": lp["bsSignerPrivateKey"],
        "LOCAL_BS_SIGNER_PUBLIC_KEY": lp["bsSignerPublicKey"],
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
    env_path = instance_dir / ".env.localnet"
    descriptor = os.open(
        env_path,
        os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
        0o600,
    )
    with os.fdopen(descriptor, "w") as output:
        output.write("".join(f"{k}={v}\n" for k, v in env.items()))
    os.chmod(env_path, 0o600)
