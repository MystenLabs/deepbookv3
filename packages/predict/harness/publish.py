"""Publish the staged package closure into a fresh localnet.

All Move.toml edits happen on staged copies (workspace/...), never the checkout.
The env-injection and dep-replacement rewrites are faithful ports of run.sh,
parameterised by package IDs discovered as we publish in dependency order.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from . import config, suicli


# --- staged Move.toml rewrites --------------------------------------------
def inject_env(toml_path: Path, chain_id: str, build_env: str = config.BUILD_ENV) -> None:
    """Add `[environments] <build_env> = <chain_id>`, dropping any prior sim/localnet env."""
    lines = [
        ln
        for ln in toml_path.read_text().splitlines()
        if not (ln.startswith("sim = ") or ln.startswith("localnet = "))
    ]
    text = "\n".join(lines)
    new_line = f'{build_env} = "{chain_id}"'
    if re.search(r"^\[environments\]", text, flags=re.M):
        text = re.sub(
            r"^\[environments\][^\n]*\n",
            lambda m: m.group(0) + new_line + "\n",
            text,
            count=1,
            flags=re.M,
        )
    else:
        text = text.rstrip("\n") + f"\n\n[environments]\n{new_line}\n"
    if not text.endswith("\n"):
        text += "\n"
    toml_path.write_text(text)


def rewrite_pyth_lazer(
    toml_path: Path, wormhole_local: Path, wormhole_id: str, build_env: str = config.BUILD_ENV
) -> None:
    """pyth_lazer's own manifest: point its wormhole dep at the staged copy + replace addr."""
    text = toml_path.read_text()
    text = re.sub(
        r"\[dependencies\.wormhole\][^\[]*",
        f'[dependencies.wormhole]\nlocal = "{wormhole_local}"\n\n',
        text,
    )
    text = re.sub(r"\[dep-replacements\.[^\]]+\][^\[]*", "", text)
    text = text.rstrip() + (
        f"\n\n[dep-replacements.{build_env}]\n"
        f'wormhole = {{ local = "{wormhole_local}", '
        f'published-at = "{wormhole_id}", original-id = "{wormhole_id}" }}\n'
    )
    toml_path.write_text(text)


def rewrite_consumer(
    toml_path: Path,
    pyth_lazer_local: Path,
    pyth_lazer_id: str,
    wormhole_local: Path,
    wormhole_id: str,
    build_env: str = config.BUILD_ENV,
) -> None:
    """propbook + predict: git pyth_lazer -> staged local, dep-replacements for both."""
    text = toml_path.read_text()
    text = re.sub(
        r"pyth_lazer = \{ git[^}]*\}",
        f'pyth_lazer = {{ local = "{pyth_lazer_local}" }}',
        text,
    )
    text = re.sub(r"\[dep-replacements\.testnet\][^\[]*", "", text)
    text = text.rstrip() + (
        f"\n\n[dep-replacements.{build_env}]\n"
        f'pyth_lazer = {{ local = "{pyth_lazer_local}", '
        f'published-at = "{pyth_lazer_id}", original-id = "{pyth_lazer_id}" }}\n'
        f'wormhole = {{ local = "{wormhole_local}", '
        f'published-at = "{wormhole_id}", original-id = "{wormhole_id}" }}\n'
    )
    toml_path.write_text(text)


# --- objectChanges extraction ---------------------------------------------
def _published_id(changes: list[dict]) -> str:
    pub = [c for c in changes if c.get("type") == "published"]
    if not pub:
        raise suicli.SuiError("no published package in objectChanges")
    return pub[-1]["packageId"]


def _published_by_module(changes: list[dict], module: str) -> str | None:
    for c in changes:
        if c.get("type") == "published" and module in c.get("modules", []):
            return c["packageId"]
    return None


def _created(changes: list[dict], *needles: str) -> str | None:
    for c in changes:
        if c.get("type") == "created":
            ot = c.get("objectType", "")
            if all(n in ot for n in needles):
                return c["objectId"]
    return None


# --- publish a single staged package --------------------------------------
def _test_publish(
    client_config: Path, staged_path: Path, pubfile: Path, *, linked: bool, gas_budget: int
) -> list[dict]:
    args = [
        "client",
        "--client.config",
        str(client_config),
        "test-publish",
        "--build-env",
        config.BUILD_ENV,
    ]
    if not linked:
        args.append("--with-unpublished-dependencies")
    args += [
        "--gas-budget",
        str(gas_budget),
        "--skip-dependency-verification",
        "--allow-dirty",
        "--force",
        "--json",
        "--pubfile-path",
        str(pubfile),
        str(staged_path),
    ]
    cp = suicli.run(args, check=False)
    try:
        data = suicli.parse_json_lenient(cp.stdout)
    except suicli.SuiError as exc:
        raise suicli.SuiError(
            f"publish {staged_path.name} produced no JSON "
            f"(exit {cp.returncode}):\n{cp.stderr.strip()[:2000]}\n{exc}"
        )
    changes = data.get("objectChanges") or []
    if not changes:
        raise suicli.SuiError(
            f"publish {staged_path.name} failed (no objectChanges, exit {cp.returncode}):\n"
            f"{cp.stderr.strip()[:1500]}"
        )
    return changes


# --- closure orchestration -------------------------------------------------
def publish_closure(
    client_config: Path, workspace: Path, pubfile: Path, chain_id: str, gas_budget: int
) -> dict[str, Any]:
    pkg = workspace / "packages"
    deps = workspace / "deps"
    wormhole_dir = deps / "wormhole"
    pyth_dir = deps / "pyth_lazer"

    packages: dict[str, str] = {}
    objects: dict[str, str | None] = {}

    def publish(path: Path, *, linked: bool = False) -> list[dict]:
        inject_env(path / "Move.toml", chain_id)
        return _test_publish(client_config, path, pubfile, linked=linked, gas_budget=gas_budget)

    # token (no-dep leaf) -- predict links it by name through the shared pubfile.
    packages["token"] = _published_id(publish(pkg / "token"))

    # dusdc
    ch = publish(pkg / "dusdc")
    packages["dusdc"] = _published_id(ch)
    objects["dusdc_currency"] = _created(ch, "coin_registry::Currency", "dusdc::DUSDC")
    objects["treasury_cap"] = _created(ch, "TreasuryCap")

    # fixed_math, block_scholes_oracle (leaves)
    packages["fixed_math"] = _published_id(publish(pkg / "fixed_math"))
    packages["block_scholes_oracle"] = _published_id(publish(pkg / "block_scholes_oracle"))

    # wormhole (git dep): env only. Capture the caps setup::complete consumes.
    wch = publish(wormhole_dir)
    packages["wormhole"] = _published_id(wch)
    objects["wormhole_deployer_cap"] = _created(wch, "setup::DeployerCap")
    objects["wormhole_upgrade_cap"] = _created(wch, "UpgradeCap")

    # pyth_lazer (git dep): link to staged wormhole; linked publish (no unpublished deps).
    # Capture its UpgradeCap for actions::init_lazer.
    inject_env(pyth_dir / "Move.toml", chain_id)
    rewrite_pyth_lazer(pyth_dir / "Move.toml", wormhole_dir, packages["wormhole"])
    pch = _test_publish(client_config, pyth_dir, pubfile, linked=True, gas_budget=gas_budget)
    packages["pyth_lazer"] = _published_id(pch)
    objects["pyth_lazer_upgrade_cap"] = _created(pch, "UpgradeCap")

    # propbook: rewrite git pyth_lazer -> staged + dep-replacements, then publish
    inject_env(pkg / "propbook" / "Move.toml", chain_id)
    rewrite_consumer(
        pkg / "propbook" / "Move.toml",
        pyth_dir,
        packages["pyth_lazer"],
        wormhole_dir,
        packages["wormhole"],
    )
    ch = _test_publish(client_config, pkg / "propbook", pubfile, linked=False, gas_budget=gas_budget)
    packages["propbook"] = _published_id(ch)
    objects["oracle_registry"] = _created(ch, "registry::OracleRegistry")
    objects["oracle_registry_admin_cap"] = _created(ch, "registry::RegistryAdminCap")

    # predict (+ account via --with-unpublished-dependencies)
    inject_env(pkg / "predict" / "Move.toml", chain_id)
    rewrite_consumer(
        pkg / "predict" / "Move.toml",
        pyth_dir,
        packages["pyth_lazer"],
        wormhole_dir,
        packages["wormhole"],
    )
    ch = _test_publish(client_config, pkg / "predict", pubfile, linked=False, gas_budget=gas_budget)
    packages["predict"] = _published_id(ch)
    packages["account"] = _published_by_module(ch, "account_registry")
    objects["registry"] = _created(ch, "registry::Registry")
    objects["admin_cap"] = _created(ch, "admin::AdminCap")
    objects["protocol_config"] = _created(ch, "protocol_config::ProtocolConfig")
    objects["pool_vault"] = _created(ch, "plp::PoolVault")
    objects["account_registry"] = _created(ch, "account_registry::AccountRegistry")
    objects["account_admin_cap"] = _created(ch, "account_registry::AccountAdminCap")

    return {"packages": packages, "objects": objects}
