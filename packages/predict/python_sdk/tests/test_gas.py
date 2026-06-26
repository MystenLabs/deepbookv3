"""Offline tests for the parallel-execution gas manager.

No network, no real keys: a FakeTransactionClient stub stands in for
TransactionClient and returns canned TxResults / coin lists. Object IDs are valid
hex because GasPool.smash() serializes them through bcs.normalize_address.
"""

import threading
import time
import unittest
from dataclasses import dataclass, field

from predict_sdk.gas import GasPool, SUI_COIN_TYPE


# === test doubles ===

@dataclass
class FakeResult:
    """Mimics tx.TxResult: only the fields GasPool reads."""

    success: bool = True
    digest: str | None = "0xdeadbeef"
    object_changes: list = field(default_factory=list)
    error: str | None = None


class FakeSigner:
    address = "0x" + "ab" * 32


class FakeTransactionClient:
    """Records calls and returns programmable canned responses; never touches RPC."""

    def __init__(self):
        self.signer = FakeSigner()
        self.runs: list[dict] = []          # captured run() kwargs/ptbs
        self.next_results: list[FakeResult] = []
        self.coins_response: list[dict] = []

    def run(self, ptb, *, execute=False, gas_budget=None, gas_coin=None):
        self.runs.append({"ptb": ptb, "execute": execute, "gas_coin": gas_coin})
        if self.next_results:
            return self.next_results.pop(0)
        return FakeResult()

    def coins(self, coin_type, owner=None):
        assert coin_type == SUI_COIN_TYPE
        return list(self.coins_response)


def _created_coin(object_id, version="1", digest="DiGeSt", coin_type=SUI_COIN_TYPE):
    return {
        "type": "created",
        "objectType": f"0x2::coin::Coin<{coin_type}>",
        "objectId": object_id,
        "version": version,
        "digest": digest,
    }


def _coin(object_id, balance=1000, version="1", digest="DiGeSt"):
    return {
        "coinObjectId": object_id,
        "version": version,
        "digest": digest,
        "balance": balance,
    }


# === split() ===

class SplitTests(unittest.TestCase):
    def test_split_parses_created_sui_coins_into_pool(self):
        client = FakeTransactionClient()
        client.next_results = [
            FakeResult(
                object_changes=[
                    _created_coin("0xc1", version="5", digest="d1"),
                    _created_coin("0xc2", version="5", digest="d2"),
                    _created_coin("0xc3", version="5", digest="d3"),
                    # noise that must be ignored:
                    {"type": "mutated", "objectType": f"0x2::coin::Coin<{SUI_COIN_TYPE}>",
                     "objectId": "0x9a", "version": "6", "digest": "dg"},  # the split gas coin
                    _created_coin("0x70", coin_type="0x2::other::TOK"),     # non-SUI created obj
                ]
            )
        ]
        pool = GasPool(client)

        coins = pool.split(3, 2_000)

        self.assertEqual(pool.size(), 3)
        self.assertEqual(pool.available_count(), 3)
        self.assertEqual({c["coinObjectId"] for c in coins}, {"0xc1", "0xc2", "0xc3"})
        # balance comes from amount_each_mist (object_changes carries none)
        self.assertTrue(all(c["balance"] == 2_000 for c in coins))
        # version/digest copied from object_changes
        c1 = next(c for c in coins if c["coinObjectId"] == "0xc1")
        self.assertEqual((c1["version"], c1["digest"]), ("5", "d1"))
        # exactly one tx was executed
        self.assertEqual(len(client.runs), 1)
        self.assertTrue(client.runs[0]["execute"])

    def test_split_raises_when_count_mismatches(self):
        client = FakeTransactionClient()
        client.next_results = [FakeResult(object_changes=[_created_coin("0xc1")])]
        pool = GasPool(client)
        with self.assertRaises(RuntimeError):
            pool.split(3, 1_000)

    def test_split_raises_on_failed_tx(self):
        client = FakeTransactionClient()
        client.next_results = [FakeResult(success=False, error="boom")]
        pool = GasPool(client)
        with self.assertRaises(RuntimeError):
            pool.split(2, 1_000)


# === acquire() / release() ===

class AcquireReleaseTests(unittest.TestCase):
    def _pool(self, ids=("0xa1", "0xb2", "0xc3")):
        client = FakeTransactionClient()
        pool = GasPool(client)
        client.coins_response = [_coin(i) for i in ids]
        pool.refresh()
        return pool

    def test_acquire_returns_distinct_coins(self):
        pool = self._pool()
        got = [pool.acquire(), pool.acquire(), pool.acquire()]
        ids = [c["coinObjectId"] for c in got]
        self.assertEqual(len(set(ids)), 3)  # all distinct
        self.assertEqual(pool.in_use_count(), 3)
        self.assertEqual(pool.available_count(), 0)

    def test_acquire_nonblocking_raises_when_exhausted(self):
        pool = self._pool(ids=("0xa1",))
        pool.acquire()
        with self.assertRaises(RuntimeError):
            pool.acquire(block=False)

    def test_release_updates_version_and_digest(self):
        pool = self._pool(ids=("0x50",))
        coin = pool.acquire()
        self.assertEqual(coin["version"], "1")
        pool.release(coin, new_version="42", new_digest="newdig")
        # the only coin comes back with the updated ref
        again = pool.acquire()
        self.assertEqual(again["coinObjectId"], "0x50")
        self.assertEqual(again["version"], "42")
        self.assertEqual(again["digest"], "newdig")

    def test_release_without_args_keeps_inplace_mutation(self):
        pool = self._pool(ids=("0x50",))
        coin = pool.acquire()
        coin["version"] = "99"  # task mutated it in place
        pool.release(coin)
        self.assertEqual(pool.acquire()["version"], "99")

    def test_update_coin_from_result_reads_object_changes(self):
        coin = _coin("0x6e", version="1", digest="old")
        result = FakeResult(
            object_changes=[
                {"type": "mutated", "objectId": "0x6e", "version": "7", "digest": "fresh"},
                {"type": "mutated", "objectId": "0xff", "version": "9", "digest": "x"},
            ]
        )
        GasPool.update_coin_from_result(coin, result)
        self.assertEqual((coin["version"], coin["digest"]), ("7", "fresh"))

    def test_never_hands_same_coin_to_two_callers_concurrently(self):
        pool = self._pool(ids=tuple(f"0x{i:02x}" for i in range(4)))
        held = set()
        lock = threading.Lock()
        violations = []
        barrier = threading.Barrier(4)

        def worker():
            barrier.wait()  # maximize overlap
            coin = pool.acquire()
            cid = coin["coinObjectId"]
            with lock:
                if cid in held:
                    violations.append(cid)
                held.add(cid)
            time.sleep(0.02)  # hold while others race
            with lock:
                held.discard(cid)
            pool.release(coin)

        threads = [threading.Thread(target=worker) for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(violations, [])


# === parallel() ===

class ParallelTests(unittest.TestCase):
    def _pool(self, n=4):
        client = FakeTransactionClient()
        pool = GasPool(client)
        client.coins_response = [_coin(f"0x{i:02x}") for i in range(n)]
        pool.refresh()
        return pool

    def test_parallel_assigns_distinct_coin_per_task(self):
        pool = self._pool(n=4)
        seen = []
        lock = threading.Lock()
        concurrent_ids = set()
        max_concurrent = [0]

        def make_task(idx):
            def task(coin):
                with lock:
                    concurrent_ids.add(coin["coinObjectId"])
                    max_concurrent[0] = max(max_concurrent[0], len(concurrent_ids))
                    seen.append(coin["coinObjectId"])
                time.sleep(0.02)  # force overlap
                with lock:
                    concurrent_ids.discard(coin["coinObjectId"])
                return idx * 10
            return task

        results = pool.parallel([make_task(i) for i in range(4)])

        self.assertEqual(results, [0, 10, 20, 30])      # order preserved
        self.assertEqual(len(set(seen)), 4)             # 4 distinct coins used
        self.assertGreaterEqual(max_concurrent[0], 2)   # actually ran in parallel
        self.assertEqual(pool.available_count(), 4)     # all released

    def test_parallel_more_tasks_than_coins_still_distinct_concurrently(self):
        pool = self._pool(n=2)
        lock = threading.Lock()
        live = set()
        violations = []

        def task(coin):
            cid = coin["coinObjectId"]
            with lock:
                if cid in live:
                    violations.append(cid)
                live.add(cid)
            time.sleep(0.01)
            with lock:
                live.discard(cid)
            return cid

        results = pool.parallel([task] * 6)
        self.assertEqual(len(results), 6)
        self.assertEqual(violations, [])               # never double-handed
        self.assertEqual(pool.available_count(), 2)    # all returned

    def test_parallel_releases_coin_even_when_task_raises(self):
        pool = self._pool(n=2)

        def boom(coin):
            raise ValueError("task failed")

        with self.assertRaises(ValueError):
            pool.parallel([boom])
        self.assertEqual(pool.in_use_count(), 0)
        self.assertEqual(pool.available_count(), 2)

    def test_parallel_empty_returns_empty(self):
        pool = self._pool(n=2)
        self.assertEqual(pool.parallel([]), [])

    def test_parallel_on_empty_pool_raises(self):
        client = FakeTransactionClient()
        pool = GasPool(client)
        with self.assertRaises(RuntimeError):
            pool.parallel([lambda c: 1])


# === smash() ===

class SmashTests(unittest.TestCase):
    def test_smash_merges_into_one_and_repopulates(self):
        client = FakeTransactionClient()
        pool = GasPool(client)
        client.coins_response = [
            _coin("0xa1", balance=100),   # small
            _coin("0xb2", balance=900),   # big -> primary
            _coin("0xc3", balance=500),   # mid
        ]
        pool.refresh()
        client.next_results = [
            FakeResult(object_changes=[
                {"type": "mutated", "objectId": "0xb2", "version": "8", "digest": "merged"},
            ])
        ]

        survivor = pool.smash()

        self.assertEqual(survivor["coinObjectId"], "0xb2")  # largest balance kept
        self.assertEqual(survivor["version"], "8")          # ref refreshed from effects
        self.assertEqual(pool.size(), 1)
        # one merge tx executed, paid with the primary coin
        self.assertEqual(len(client.runs), 1)
        self.assertEqual(client.runs[0]["gas_coin"]["coinObjectId"], "0xb2")

    def test_smash_noop_with_single_coin(self):
        client = FakeTransactionClient()
        pool = GasPool(client)
        client.coins_response = [_coin("0xa1")]
        pool.refresh()
        survivor = pool.smash()
        self.assertEqual(survivor["coinObjectId"], "0xa1")
        self.assertEqual(len(client.runs), 0)  # nothing to merge


if __name__ == "__main__":
    unittest.main()
