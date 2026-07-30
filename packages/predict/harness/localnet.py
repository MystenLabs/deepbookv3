"""Localnet lifecycle: genesis, start, readiness, funding, teardown."""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

from . import config, suicli


def genesis(config_dir: Path, rpc_port: int) -> Path:
    """Generate fresh genesis; return the client.yaml path (RPC port patched)."""
    if config_dir.exists():
        shutil.rmtree(config_dir)
    config_dir.mkdir(parents=True)
    suicli.run(["genesis", "--force", "--working-dir", str(config_dir)])

    client_config = config_dir / "client.yaml"
    if rpc_port != config.RPC_BASE:
        text = client_config.read_text().replace(f":{config.RPC_BASE}", f":{rpc_port}")
        client_config.write_text(text)
    return client_config


def start(config_dir: Path, rpc_port: int, faucet_port: int, log_path: Path) -> subprocess.Popen:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log = open(log_path, "ab")
    return subprocess.Popen(
        [
            config.sui_binary(),
            "start",
            "--network.config",
            str(config_dir),
            "--fullnode-rpc-port",
            str(rpc_port),
            f"--with-faucet={faucet_port}",
        ],
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,  # own process group, so we can kill the whole tree
    )


def _client_json(client_config: Path, args: list[str]) -> object:
    """Run a read through the current Sui CLI transport and parse its JSON output."""
    cp = suicli.client(
        client_config,
        [*args, "--json"],
        check=False,
        timeout=5,
    )
    if cp.returncode != 0:
        raise suicli.SuiError(cp.stderr.strip() or cp.stdout.strip())
    return suicli.parse_json_lenient(cp.stdout)


def wait_for_rpc(client_config: Path, rpc_port: int, timeout: float = 90.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if chain_id(client_config):
                return
        except (subprocess.SubprocessError, suicli.SuiError, OSError, json.JSONDecodeError):
            pass
        time.sleep(1)
    raise TimeoutError(f"localnet RPC not ready on :{rpc_port} after {timeout}s")


def wait_for_faucet(faucet_port: int, timeout: float = 60.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{faucet_port}/", timeout=5)
            return
        except urllib.error.HTTPError:
            return  # any HTTP response means the faucet is up
        except (urllib.error.URLError, ConnectionError, OSError):
            time.sleep(1)
    raise TimeoutError(f"faucet not ready on :{faucet_port} after {timeout}s")


def fund(faucet_port: int, address: str, times: int = 2) -> None:
    body = json.dumps({"FixedAmountRequest": {"recipient": address}}).encode()
    for _ in range(times):
        try:
            req = urllib.request.Request(
                f"http://127.0.0.1:{faucet_port}/v1/gas",
                data=body,
                headers={"Content-Type": "application/json"},
            )
            urllib.request.urlopen(req, timeout=10).read()
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(1)
    time.sleep(1)


def balance(client_config: Path, address: str) -> int:
    """Total SUI balance (MIST) for an address, or -1 if the query fails."""
    try:
        data = _client_json(
            client_config,
            ["balance", address, "--coin-type", "0x2::sui::SUI"],
        )
        entries = data if isinstance(data, list) else [data]
        if not entries:
            return 0
        entry = entries[0]
        if not isinstance(entry, dict):
            raise ValueError("unexpected balance response")
        value = (
            entry.get("totalBalance")
            or entry.get("total_balance")
            or entry.get("balance")
        )
        if isinstance(value, dict):
            value = value.get("balance") or value.get("coinBalance")
        return int(value)
    except (subprocess.SubprocessError, suicli.SuiError, OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        return -1


def active_address(client_config: Path) -> str:
    return suicli.client_text(client_config, ["active-address"])


def chain_id(client_config: Path) -> str:
    data = _client_json(client_config, ["chain-identifier"])
    if isinstance(data, str):
        return data
    if isinstance(data, dict):
        value = data.get("chainIdentifier") or data.get("chain_identifier")
        if isinstance(value, str):
            return value
    raise ValueError(f"unexpected chain identifier response: {data!r}")


def request_stop(proc: subprocess.Popen | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass


def stop(proc: subprocess.Popen | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    request_stop(proc)
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
