"""Publish a disposable copy of the Predict package closure.

The canonical checkout is never a publication target. Localnet compiles exact
package sources in the Testnet environment and records ephemeral addresses in
one Pub.sim.toml.
"""

from __future__ import annotations

import contextlib
import re
import threading
import tomllib
from pathlib import Path
from typing import Any, Iterator, Mapping

from . import config, staging, suicli

PUBLISH_GRAPH: dict[str, tuple[str, ...]] = {
    "token": (),
    "dusdc": (),
    "fixed_math": (),
    "account": (),
    "wormhole": (),
    "pyth_lazer": ("wormhole",),
    "bs_oracle": (),
    "bs_sid": (),
    "propbook": ("fixed_math", "wormhole", "pyth_lazer", "bs_oracle", "bs_sid"),
    "predict": (
        "token",
        "dusdc",
        "fixed_math",
        "account",
        "wormhole",
        "pyth_lazer",
        "bs_oracle",
        "propbook",
    ),
}


def publication_order(graph: Mapping[str, tuple[str, ...]] = PUBLISH_GRAPH) -> tuple[str, ...]:
    """Return a deterministic topological order, rejecting missing nodes and cycles."""
    order: list[str] = []
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(name: str) -> None:
        if name in visited:
            return
        if name in visiting:
            raise ValueError(f"publication dependency cycle contains {name}")
        if name not in graph:
            raise ValueError(f"publication graph references missing package {name}")
        visiting.add(name)
        for dependency in graph[name]:
            visit(dependency)
        visiting.remove(name)
        visited.add(name)
        order.append(name)

    for package in graph:
        visit(package)
    return tuple(order)


def _replace_first(pattern: str, replacement: str, text: str, label: str) -> str:
    rewritten, count = re.subn(pattern, replacement, text, count=1)
    if count != 1:
        raise ValueError(f"could not find {label} declaration")
    return rewritten


def rewrite_pyth_lazer(
    toml_path: Path,
    wormhole_local: Path,
    wormhole_id: str,
    build_env: str = config.BUILD_ENV,
) -> None:
    """Point staged Pyth Lazer at the staged Wormhole publication."""
    text = toml_path.read_text()
    text = _replace_first(
        r"\[dependencies\.wormhole\][^\[]*",
        f'[dependencies.wormhole]\nlocal = "{wormhole_local}"\n\n',
        text,
        "pyth_lazer.wormhole dependency",
    )
    text = re.sub(r"\[dep-replacements\.[^\]]+\][^\[]*", "", text)
    text = text.rstrip() + (
        f"\n\n[dep-replacements.{build_env}]\n"
        f'wormhole = {{ local = "{wormhole_local}", '
        f'published-at = "{wormhole_id}", original-id = "{wormhole_id}" }}\n'
    )
    toml_path.write_text(text)


def rewrite_block_scholes_package(toml_path: Path) -> None:
    """Use the localnet's implicit Sui framework in a staged Block Scholes package."""
    text = toml_path.read_text()
    manifest = tomllib.loads(text)
    package_name = manifest.get("package", {}).get("name")
    if package_name not in {"bs_oracle", "bs_sid"}:
        raise ValueError(f"unexpected Block Scholes package: {package_name}")
    dependencies = manifest.get("dependencies", {})
    expected = {
        "Sui": "crates/sui-framework/packages/sui-framework",
        "MoveStdlib": "crates/sui-framework/packages/move-stdlib",
    }
    for name, subdir in expected.items():
        source = dependencies.get(name)
        if (
            not isinstance(source, dict)
            or source.get("git") != "https://github.com/MystenLabs/sui.git"
            or source.get("subdir") != subdir
        ):
            raise ValueError(f"unexpected {package_name} {name} dependency: {source}")
        text, count = re.subn(
            rf"(?m)^{name}\s*=\s*\{{[^\n]*\}}\n",
            "",
            text,
            count=1,
        )
        if count != 1:
            raise ValueError(f"could not remove {package_name} {name} dependency")

    lines = text.splitlines()
    dependencies_index = lines.index("[dependencies]")
    comment_start = dependencies_index
    while comment_start > 0 and (
        not lines[comment_start - 1] or lines[comment_start - 1].startswith("#")
    ):
        comment_start -= 1
    lines[comment_start:dependencies_index] = [""]
    toml_path.write_text("\n".join(lines) + "\n")


def reset_staged_lock(package_path: Path) -> None:
    """Force an external staged root to resolve against the localnet framework."""
    lock_path = package_path / "Move.lock"
    if not lock_path.is_file():
        raise FileNotFoundError(f"staged external package has no Move.lock: {lock_path}")
    lock_path.unlink()


def rewrite_consumer(
    toml_path: Path,
    pyth_lazer_local: Path,
    pyth_lazer_id: str,
    wormhole_local: Path,
    wormhole_id: str,
    bs_oracle_local: Path,
    bs_oracle_id: str,
    bs_sid_local: Path,
    bs_sid_id: str,
    build_env: str = config.BUILD_ENV,
) -> None:
    """Point a staged Propbook/Predict manifest at staged oracle packages."""
    text = toml_path.read_text()
    text = _replace_first(
        r"pyth_lazer = \{ git[^}]*\}",
        f'pyth_lazer = {{ local = "{pyth_lazer_local}" }}',
        text,
        "pyth_lazer dependency",
    )
    text = _replace_first(
        r"bs_oracle = \{ git[^}]*\}",
        f'bs_oracle = {{ local = "{bs_oracle_local}" }}',
        text,
        "bs_oracle dependency",
    )
    has_bs_sid = bool(re.search(r"(?m)^bs_sid\s*=\s*\{\s*git", text))
    if has_bs_sid:
        text = _replace_first(
            r"bs_sid = \{ git[^}]*\}",
            f'bs_sid = {{ local = "{bs_sid_local}" }}',
            text,
            "bs_sid dependency",
        )
    text, count = re.subn(r"\[dep-replacements\.testnet\][^\[]*", "", text)
    if count != 1:
        raise ValueError(f"expected one testnet dependency-replacement section, found {count}")
    replacements = (
        f"\n\n[dep-replacements.{build_env}]\n"
        f'pyth_lazer = {{ local = "{pyth_lazer_local}", '
        f'published-at = "{pyth_lazer_id}", original-id = "{pyth_lazer_id}" }}\n'
        f'wormhole = {{ local = "{wormhole_local}", '
        f'published-at = "{wormhole_id}", original-id = "{wormhole_id}" }}\n'
        f'bs_oracle = {{ local = "{bs_oracle_local}", '
        f'published-at = "{bs_oracle_id}", original-id = "{bs_oracle_id}" }}\n'
    )
    if has_bs_sid:
        replacements += (
            f'bs_sid = {{ local = "{bs_sid_local}", '
            f'published-at = "{bs_sid_id}", original-id = "{bs_sid_id}" }}\n'
        )
    text = text.rstrip() + replacements
    toml_path.write_text(text)


def _published_id(changes: list[dict]) -> str:
    published = [change for change in changes if change.get("type") == "published"]
    if not published:
        raise suicli.SuiError("no published package in objectChanges")
    return published[-1]["packageId"]


def _created(changes: list[dict], *needles: str) -> str | None:
    for change in changes:
        if change.get("type") != "created":
            continue
        object_type = change.get("objectType", "")
        if all(needle in object_type for needle in needles):
            return change["objectId"]
    return None


def _test_publish(
    client_config: Path,
    workspace: Path,
    staged_path: Path,
    pubfile: Path,
    gas_budget: int,
    cancel_event: threading.Event | None = None,
) -> list[dict]:
    package_path = staging.require_staged_path(workspace, staged_path)
    args = [
        "client",
        "--client.config",
        str(client_config),
        "test-publish",
        "--build-env",
        config.BUILD_ENV,
        "--gas-budget",
        str(gas_budget),
        "--force",
        "--json",
        "--pubfile-path",
        str(pubfile),
        str(package_path),
    ]
    result = suicli.run(
        args,
        check=False,
        cancel_event=cancel_event,
    )
    try:
        data = suicli.parse_json_lenient(result.stdout)
    except suicli.SuiError as exc:
        raise suicli.SuiError(
            f"publish {package_path.name} produced no JSON "
            f"(exit {result.returncode}):\n{result.stderr.strip()[:2000]}\n{exc}"
        )
    changes = data.get("objectChanges") or []
    if result.returncode != 0 or not changes:
        raise suicli.SuiError(
            f"publish {package_path.name} failed "
            f"(exit {result.returncode}, no objectChanges={not changes}):\n"
            f"{result.stderr.strip()[:1500]}"
        )
    return changes


def _capture_objects(name: str, changes: list[dict], objects: dict[str, str | None]) -> None:
    if name == "dusdc":
        objects["dusdc_currency"] = _created(
            changes, "coin_registry::Currency", "dusdc::DUSDC"
        )
        objects["treasury_cap"] = _created(changes, "TreasuryCap")
    elif name == "account":
        objects["account_registry"] = _created(
            changes, "account_registry::AccountRegistry"
        )
        objects["account_admin_cap"] = _created(
            changes, "account_registry::AccountAdminCap"
        )
    elif name == "wormhole":
        objects["wormhole_deployer_cap"] = _created(changes, "setup::DeployerCap")
        objects["wormhole_upgrade_cap"] = _created(changes, "UpgradeCap")
    elif name == "pyth_lazer":
        objects["pyth_lazer_upgrade_cap"] = _created(changes, "UpgradeCap")
    elif name == "bs_oracle":
        objects["bs_signer_registry"] = _created(changes, "registry::SignerRegistry")
        objects["bs_admin_cap"] = _created(changes, "registry::AdminCap")
    elif name == "propbook":
        objects["oracle_registry"] = _created(changes, "registry::OracleRegistry")
        objects["oracle_registry_admin_cap"] = _created(
            changes, "registry::RegistryAdminCap"
        )
    elif name == "predict":
        objects["registry"] = _created(changes, "registry::Registry")
        objects["admin_cap"] = _created(changes, "admin::AdminCap")
        objects["protocol_config"] = _created(changes, "protocol_config::ProtocolConfig")
        objects["pool_vault"] = _created(changes, "plp::PoolVault")


def publish_closure(
    client_config: Path,
    workspace: Path,
    pubfile: Path,
    gas_budget: int,
    cancel_event: threading.Event | None = None,
) -> dict[str, Any]:
    """Validate and publish each staged package exactly once in dependency order."""
    paths = staging.validate_workspace(workspace)
    order = publication_order()
    packages: dict[str, str] = {}
    objects: dict[str, str | None] = {}
    published_nodes: set[str] = set()

    for name in order:
        missing = set(PUBLISH_GRAPH[name]) - published_nodes
        if missing:
            raise RuntimeError(
                f"cannot publish {name}; unpublished dependencies: {sorted(missing)}"
            )

        if name in config.GIT_DEP_NAMES:
            reset_staged_lock(paths[name])
        if name == "pyth_lazer":
            rewrite_pyth_lazer(
                paths[name] / "Move.toml",
                paths["wormhole"],
                packages["wormhole"],
            )
            staging.validate_workspace(workspace)
        elif name in {"bs_oracle", "bs_sid"}:
            rewrite_block_scholes_package(paths[name] / "Move.toml")
            staging.validate_workspace(workspace)
        elif name in {"propbook", "predict"}:
            rewrite_consumer(
                paths[name] / "Move.toml",
                paths["pyth_lazer"],
                packages["pyth_lazer"],
                paths["wormhole"],
                packages["wormhole"],
                paths["bs_oracle"],
                packages["block_scholes_oracle"],
                paths["bs_sid"],
                packages["bs_sid"],
            )
            staging.validate_workspace(workspace)

        changes = _test_publish(
            client_config,
            workspace,
            paths[name],
            pubfile,
            gas_budget,
            cancel_event,
        )
        package_key = "block_scholes_oracle" if name == "bs_oracle" else name
        packages[package_key] = _published_id(changes)
        _capture_objects(name, changes, objects)
        published_nodes.add(name)

    missing_objects = sorted(name for name, object_id in objects.items() if not object_id)
    if missing_objects:
        raise suicli.SuiError(f"publication did not create required objects: {missing_objects}")
    return {"packages": packages, "objects": objects}


@contextlib.contextmanager
def staged_closure(
    workspace: Path,
    cancel_event: threading.Event | None = None,
) -> Iterator[dict[str, Path]]:
    """Stage the closure while proving canonical package files stay unchanged."""
    fingerprint = staging.checkout_fingerprint()
    try:
        if cancel_event is None:
            yield staging.stage_closure(workspace)
        else:
            yield staging.stage_closure(workspace, cancel_event)
    finally:
        if staging.checkout_fingerprint() != fingerprint:
            raise RuntimeError("ephemeral publication mutated canonical package-management files")
