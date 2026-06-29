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


def _rpc(rpc_port: int, method: str, params=None) -> dict:
    body = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}
    ).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{rpc_port}",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())


def wait_for_rpc(rpc_port: int, timeout: float = 90.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = _rpc(rpc_port, "sui_getLatestCheckpointSequenceNumber")
            if "result" in r:
                return
        except (urllib.error.URLError, ConnectionError, OSError, json.JSONDecodeError):
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


def balance(rpc_port: int, address: str) -> int:
    """Total SUI balance (MIST) for an address, or -1 if the query fails."""
    try:
        return int(_rpc(rpc_port, "suix_getBalance", [address])["result"]["totalBalance"])
    except (urllib.error.URLError, ConnectionError, OSError, KeyError, ValueError, json.JSONDecodeError):
        return -1


def active_address(client_config: Path) -> str:
    return suicli.client_text(client_config, ["active-address"])


def chain_id(rpc_port: int) -> str:
    return _rpc(rpc_port, "sui_getChainIdentifier")["result"]


def stop(proc: subprocess.Popen | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
