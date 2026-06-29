"""Static configuration: paths, ports, the Predict package closure.

Paths are anchored to this file (not the cwd), so `.localnets/` always lives
under the harness directory regardless of where the CLI is invoked.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

# --- Repo layout -----------------------------------------------------------
HARNESS_DIR = Path(__file__).resolve().parent
PREDICT_DIR = HARNESS_DIR.parent
PACKAGES_DIR = PREDICT_DIR.parent
REPO_DIR = PACKAGES_DIR.parent

TS_DIR = HARNESS_DIR / "ts"
LOCALNETS_DIR = HARNESS_DIR / ".localnets"
INSTANCES_DIR = LOCALNETS_DIR / "instances"
STATE_FILE = LOCALNETS_DIR / "state.json"
LOCK_FILE = LOCALNETS_DIR / "state.lock"

# --- Build / publish -------------------------------------------------------
BUILD_ENV = "sim"
GAS_BUDGET = 5_000_000_000

# --- Ports -----------------------------------------------------------------
# Only the fullnode JSON-RPC (9000) and faucet (9123) are fixed; swarm /
# validator / consensus / metrics ports are genesis-randomized and disjoint
# between instances, so offsetting just these two isolates a localnet.
RPC_BASE = 9000
FAUCET_BASE = 9123
SLOT_COUNT = 32  # generous slot/port ceiling; real parallelism = --concurrency

# --- Package closure -------------------------------------------------------
# Local packages (under packages/) staged by mirroring the subtree, so their
# relative `local = "../foo"` deps resolve inside the workspace unchanged.
# Verified against predict/Move.lock: predict's closure is these locals plus the
# git deps below. deepbook is intentionally NOT here (run.sh only published it to
# drag `token` in transitively; `token` is a no-dep leaf we publish directly).
LOCAL_CLOSURE = [
    "fixed_math",
    "dusdc",
    "account",
    "block_scholes_oracle",
    "propbook",
    "token",
    "predict",
]

# Upstream git deps that get dep-replaced to locally-published addresses. Staged
# from the ~/.move branch-clone cache (immutable-rev guarantee intentionally
# dropped for now), falling back to a shallow clone of the branch.
_MOVE_CACHE = Path.home() / ".move"
GIT_DEPS = {
    "wormhole": {
        "repo": "https://github.com/pyth-network/wormhole.git",
        "branch": "sui-testnet",
        "subdir": "sui/wormhole",
        "cache": _MOVE_CACHE
        / "https___github_com_pyth-network_wormhole_git_sui-testnet"
        / "sui"
        / "wormhole",
    },
    "pyth_lazer": {
        "repo": "https://github.com/pyth-network/pyth-crosschain.git",
        "branch": "sui-testnet",
        "subdir": "lazer/contracts/sui",
        "cache": _MOVE_CACHE
        / "https___github_com_pyth-network_pyth-crosschain_git_sui-testnet"
        / "lazer"
        / "contracts"
        / "sui",
    },
}

# Directory names never worth copying into the scratch workspace.
STAGE_IGNORE = (
    "build",
    "node_modules",
    ".git",
    ".localnets",
    "__pycache__",
    "runs",
    "simulations",
    "harness",
    ".worktrees",
)


def sui_binary() -> str:
    """Resolve the sui binary the same way run.sh does."""
    env = os.environ.get("SUI_BINARY")
    if env:
        return env
    local = Path.home() / ".local" / "bin" / "sui"
    if local.is_file() and os.access(local, os.X_OK):
        return str(local)
    found = shutil.which("sui")
    if not found:
        raise RuntimeError("sui binary not found (set SUI_BINARY or add sui to PATH)")
    return found


def _total_ram_gb() -> float | None:
    try:
        return os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") / (1024**3)
    except (ValueError, OSError, AttributeError):
        return None


def default_concurrency() -> int:
    """Safe parallel-localnet width: min(cores-2, RAM-bound, slot cap).

    Each localnet is ~3 GB RAM and bursty-CPU, so we cap by both cores and RAM
    (leaving 4 GB for the OS) and never exceed the slot ceiling.
    """
    cpu_bound = max(1, (os.cpu_count() or 4) - 2)
    ram_gb = _total_ram_gb()
    ram_bound = max(1, int((ram_gb - 4) // 3)) if ram_gb else cpu_bound
    return max(1, min(cpu_bound, ram_bound, SLOT_COUNT))
