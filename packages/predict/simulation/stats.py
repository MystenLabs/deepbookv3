"""
Instrumentation for treap without modifying treap.py.

Provides node access counting, tree shape analysis,
and per-operation stats tracking.
"""

from dataclasses import dataclass, field


class InstrumentedDict(dict):
    """Drop-in dict replacement that counts reads, writes, and deletes."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.reads = 0
        self.writes = 0
        self.deletes = 0

    def __getitem__(self, key):
        self.reads += 1
        return super().__getitem__(key)

    def __setitem__(self, key, value):
        self.writes += 1
        super().__setitem__(key, value)

    def __delitem__(self, key):
        self.deletes += 1
        super().__delitem__(key)

    def reset_counters(self):
        self.reads = 0
        self.writes = 0
        self.deletes = 0

    def snapshot(self) -> dict:
        return {
            "reads": self.reads,
            "writes": self.writes,
            "deletes": self.deletes,
        }


def instrument(treap) -> InstrumentedDict:
    """Swap treap.nodes with an InstrumentedDict. Returns the instrumented dict."""
    instrumented = InstrumentedDict(treap.nodes)
    treap.nodes = instrumented
    return instrumented


# === Tree Shape Analysis ===


def tree_depth(treap) -> int:
    """Compute max depth of the treap."""
    if treap.root is None:
        return 0
    return _depth(treap.nodes, treap.root)


def _depth(nodes: dict, strike: int) -> int:
    node = nodes[strike] if isinstance(nodes, dict) else nodes[strike]
    left_d = _depth(nodes, node.left) if node.left is not None else 0
    right_d = _depth(nodes, node.right) if node.right is not None else 0
    return 1 + max(left_d, right_d)


def tree_width_by_level(treap) -> list[int]:
    """Returns a list where index i = number of nodes at depth i."""
    if treap.root is None:
        return []
    widths: list[int] = []
    _collect_widths(treap.nodes, treap.root, 0, widths)
    return widths


def _collect_widths(nodes: dict, strike: int, depth: int, widths: list[int]):
    while len(widths) <= depth:
        widths.append(0)
    widths[depth] += 1
    node = nodes[strike]
    if node.left is not None:
        _collect_widths(nodes, node.left, depth + 1, widths)
    if node.right is not None:
        _collect_widths(nodes, node.right, depth + 1, widths)


def tree_balance_ratio(treap) -> float:
    """Ratio of actual depth to optimal depth (log2(n)).
    1.0 = perfectly balanced, higher = more skewed."""
    if treap.size <= 1:
        return 1.0
    import math

    actual = tree_depth(treap)
    optimal = math.ceil(math.log2(treap.size + 1))
    return actual / optimal


# === Per-Operation Stats ===


@dataclass
class OpStats:
    action: str  # "insert" or "remove"
    strike: int
    qty: int
    is_up: bool
    reads: int
    writes: int
    deletes: int


@dataclass
class SimulationStats:
    op_stats: list[OpStats] = field(default_factory=list)

    def record(self, action: str, strike: int, qty: int, is_up: bool, counters: dict):
        self.op_stats.append(
            OpStats(
                action=action,
                strike=strike,
                qty=qty,
                is_up=is_up,
                reads=counters["reads"],
                writes=counters["writes"],
                deletes=counters["deletes"],
            )
        )

    def print_summary(self):
        if not self.op_stats:
            print("No operations recorded.")
            return

        inserts = [o for o in self.op_stats if o.action == "insert"]
        removes = [o for o in self.op_stats if o.action == "remove"]

        print(f"=== Treap Operation Stats ===")
        print(f"Total operations: {len(self.op_stats)}")
        print()

        for label, ops in [("Insert", inserts), ("Remove", removes)]:
            if not ops:
                continue
            reads = [o.reads for o in ops]
            writes = [o.writes for o in ops]
            print(f"  {label} ({len(ops)} ops):")
            print(
                f"    Reads:  min={min(reads)} avg={sum(reads)//len(reads)} "
                f"max={max(reads)}"
            )
            print(
                f"    Writes: min={min(writes)} avg={sum(writes)//len(writes)} "
                f"max={max(writes)}"
            )


def print_tree_shape(treap):
    """Print tree shape summary."""
    if treap.root is None:
        print("Tree is empty.")
        return

    depth = tree_depth(treap)
    widths = tree_width_by_level(treap)
    ratio = tree_balance_ratio(treap)

    print(f"=== Tree Shape ===")
    print(f"  Nodes: {treap.size}")
    print(f"  Depth: {depth}")
    print(f"  Balance ratio: {ratio:.2f} (1.0 = perfect)")
    print(f"  Width by level: {widths[:10]}{'...' if len(widths) > 10 else ''}")
    print(f"  Max width: {max(widths)} at level {widths.index(max(widths))}")
