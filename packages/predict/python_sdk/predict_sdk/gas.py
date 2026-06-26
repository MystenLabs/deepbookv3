from __future__ import annotations

import threading
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Callable

from . import bcs
from .bcs import Ptb

# Parallel-execution gas manager.
#
# Why this exists: on Sui, two transactions submitted concurrently that share the
# SAME owned object "equivocate" — validators lock the object and at least one tx
# fails (the object can stay locked until epoch end). Shared objects (the Predict
# PoolVault, AccountWrapper, ProtocolConfig, ...) are fine to touch concurrently
# because consensus orders them; the only owned object every transaction needs is
# its GAS coin. So to run N transactions in parallel safely, each must pay with a
# DISTINCT owned SUI coin.
#
# "Gas smashing" is the runtime merging several payment coins into one. We use the
# inverse: pre-split one big coin into N independent coins (split()), then hand one
# distinct coin to each in-flight task (acquire()/parallel()). When done, smash()
# merges them back into one.
#
# Reference: this mirrors the "gas lane" pattern in the TypeScript oracle-feed
# service (scripts/services/oracle-feed on branch predict-testnet-4-16) —
# bootstrap.ts `refreshGasLanesIfNeeded` splits one coin into per-lane coins via
# splitCoins(tx.gas, ...) + transferObjects(..., self), and executor.ts
# (`nextAvailableLane` / `executeLaneTx` / `waitForAllLanesIdle`) hands one
# distinct gas coin to each concurrent tx and refreshes its ref from
# effects.mutated afterward. GasPool ports that lane bookkeeping to Python threads.

SUI_COIN_TYPE = "0x2::sui::SUI"


class GasPool:
    """Owns a set of distinct SUI coins and hands them out one-per-in-flight-tx.

    The non-equivocation guarantee: a coin handed to a caller via `acquire()` (or
    to a task in `parallel()`) is removed from the available set until `release()`,
    so no two concurrent callers ever pay gas with the same owned object.

    Coin dicts use the SDK's shape: {"coinObjectId", "version", "digest", "balance"}.
    """

    def __init__(self, client: Any, *, coin_type: str = SUI_COIN_TYPE) -> None:
        self.client = client
        self.coin_type = coin_type
        self._address: str = client.signer.address
        # `_available` holds free coins; `_in_use` maps coinObjectId -> coin for
        # the ones currently held by a caller. A Condition lets acquire() block
        # until release() frees a coin, and guards both structures.
        self._available: list[dict] = []
        self._in_use: dict[str, dict] = {}
        self._cond = threading.Condition()

    # === pool sizing helpers ===

    def size(self) -> int:
        """Total coins owned by the pool (available + in use)."""
        with self._cond:
            return len(self._available) + len(self._in_use)

    def available_count(self) -> int:
        with self._cond:
            return len(self._available)

    def in_use_count(self) -> int:
        with self._cond:
            return len(self._in_use)

    # === population ===

    def split(self, n: int, amount_each_mist: int) -> list[dict]:
        """Split the gas coin into `n` new SUI coins of `amount_each_mist` each.

        Builds ONE PTB that SplitCoins the gas coin into `n` pieces and
        TransferObjects them back to the signer, executes it, then discovers the
        created coin refs from `TxResult.object_changes` and (re)populates the
        pool with them. The gas coin being split must hold at least
        `n * amount_each_mist` plus gas headroom; that is the caller's concern.
        """
        if n <= 0:
            raise ValueError("n must be >= 1")
        if amount_each_mist <= 0:
            raise ValueError("amount_each_mist must be >= 1")
        with self._cond:
            if self._in_use:
                raise RuntimeError("cannot split while coins are in use")

        ptb = Ptb()
        amounts = [ptb.pure_u64(amount_each_mist) for _ in range(n)]
        split_cmd = ptb.split_coins(bcs.arg_gas_coin(), amounts)
        new_coins = [bcs.arg_nested_result(split_cmd, j) for j in range(n)]
        ptb.transfer_objects(new_coins, ptb.pure_address(self._address))

        result = self.client.run(ptb, execute=True)
        if not result.success:
            raise RuntimeError(f"gas split failed: {getattr(result, 'error', None)}")

        # object_changes carries no balance; each created coin holds exactly the
        # amount we asked SplitCoins for.
        created = [
            {
                "coinObjectId": ch["objectId"],
                "version": ch["version"],
                "digest": ch["digest"],
                "balance": amount_each_mist,
            }
            for ch in result.object_changes
            if ch.get("type") == "created" and self.coin_type in ch.get("objectType", "")
        ]
        if len(created) != n:
            raise RuntimeError(
                f"gas split expected {n} created {self.coin_type} coins, found {len(created)}"
            )

        with self._cond:
            self._available = created
            self._in_use = {}
            self._cond.notify_all()
        return list(created)

    def refresh(self) -> list[dict]:
        """Repopulate the available set from the signer's on-chain SUI coins.

        Refuses to run while any coin is in use (mirrors the reference service,
        which will not re-lay gas lanes while a lane is active) so we never strand
        a ref a caller is still paying with.
        """
        with self._cond:
            if self._in_use:
                raise RuntimeError("cannot refresh while coins are in use")
        coins = self.client.coins(self.coin_type)
        with self._cond:
            self._available = list(coins)
            self._cond.notify_all()
        return list(coins)

    # === checkout / checkin ===

    def acquire(self, *, block: bool = True, timeout: float | None = None) -> dict:
        """Hand out a distinct coin, removing it from the available set.

        Blocks until a coin frees up when `block` is True; raises immediately when
        the pool is exhausted and `block` is False. The returned dict is the live
        pool entry — mutate it in place (e.g. via `update_coin_from_result`) to
        persist the post-tx version/digest before/at `release`.
        """
        with self._cond:
            if not block and not self._available:
                raise RuntimeError("no gas coin available")
            if not self._cond.wait_for(lambda: bool(self._available), timeout=timeout):
                raise TimeoutError("timed out waiting for a gas coin")
            coin = self._available.pop()
            self._in_use[coin["coinObjectId"]] = coin
            return coin

    def release(
        self,
        coin: dict,
        new_version: int | str | None = None,
        new_digest: str | None = None,
    ) -> dict:
        """Return a coin to the pool, optionally updating its post-tx ref.

        After a tx, the coin's version/digest change; pass the new values (read
        from the tx effects / object_changes) so the next acquire of this coin
        builds a valid owned-object input.
        """
        with self._cond:
            cid = coin["coinObjectId"]
            self._in_use.pop(cid, None)
            if new_version is not None:
                coin["version"] = new_version
            if new_digest is not None:
                coin["digest"] = new_digest
            self._available.append(coin)
            self._cond.notify()
            return coin

    @staticmethod
    def update_coin_from_result(coin: dict, result: Any) -> dict:
        """Refresh a coin's version/digest in place from a TxResult's effects.

        Scans `object_changes` for the entry matching the coin and copies its new
        version/digest (mirrors the reference service reading effects.mutated for
        the lane's gas coin). Returns the same dict for chaining.
        """
        cid = coin["coinObjectId"]
        for ch in getattr(result, "object_changes", []):
            if ch.get("objectId") == cid and ch.get("type") in ("mutated", "created"):
                coin["version"] = ch["version"]
                coin["digest"] = ch["digest"]
                break
        return coin

    # === parallel execution ===

    def parallel(self, tasks: list[Callable[[dict], Any]]) -> list[Any]:
        """Run `tasks` concurrently, each with its own distinct gas coin.

        Each task is called as `task(coin)` on a worker thread and must use that
        coin (and only that coin) as the owned object / gas payment for its tx —
        that is what keeps the transactions non-equivocating. Results are returned
        in task order; the coin is released even if the task raises. RPC is
        IO-bound, so threads (not processes) are the right tool.

        The coin dict passed to a task is the live pool entry; mutate it in place
        (e.g. `pool.update_coin_from_result(coin, result)`) to persist the post-tx
        ref across the implicit release.
        """
        if not tasks:
            return []
        pool_size = self.size()
        if pool_size == 0:
            raise RuntimeError("gas pool is empty; call split()/refresh() first")
        workers = max(1, min(len(tasks), pool_size))

        def _run(task: Callable[[dict], Any]) -> Any:
            coin = self.acquire()
            try:
                return task(coin)
            finally:
                self.release(coin)

        with ThreadPoolExecutor(max_workers=workers) as executor:
            futures = [executor.submit(_run, task) for task in tasks]
            return [future.result() for future in futures]

    # === teardown ===

    def smash(self) -> dict | None:
        """Merge all pool coins back into one and repopulate the pool.

        Builds ONE PTB that MergeCoins every other coin into the largest (used as
        the gas coin), executes it, then refreshes the surviving coin's ref.
        Returns the surviving coin, or None if the pool had fewer than two coins.
        Refuses to run while coins are in use.
        """
        with self._cond:
            if self._in_use:
                raise RuntimeError("cannot smash while coins are in use")
            coins = list(self._available)
        if len(coins) < 2:
            return coins[0] if coins else None

        primary = max(coins, key=lambda c: int(c["balance"]))
        others = [c for c in coins if c["coinObjectId"] != primary["coinObjectId"]]

        ptb = Ptb()
        sources = [
            ptb.owned_object(c["coinObjectId"], int(c["version"]), c["digest"]) for c in others
        ]
        ptb.merge_coins(bcs.arg_gas_coin(), sources)

        result = self.client.run(ptb, execute=True, gas_coin=primary)
        if not result.success:
            raise RuntimeError(f"gas smash failed: {getattr(result, 'error', None)}")

        self.update_coin_from_result(primary, result)
        with self._cond:
            self._available = [primary]
            self._in_use = {}
            self._cond.notify_all()
        return primary
