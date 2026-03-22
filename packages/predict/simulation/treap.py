"""
Treap-based aggregate tree for O(log N) position tracking.

Mirror of treap.move — same data structures, same algorithms.
Useful for off-chain simulation and testing.
"""

import hashlib
import struct
from dataclasses import dataclass, field
from typing import Optional

FLOAT_SCALING = 1_000_000_000


def mul(x: int, y: int) -> int:
    return (x * y) // FLOAT_SCALING


def div(x: int, y: int) -> int:
    return (x * FLOAT_SCALING) // y


@dataclass
class Node:
    # Treap structure
    priority: int
    left: Optional[int] = None
    right: Optional[int] = None
    # Position data at this exact strike
    q_up: int = 0
    q_dn: int = 0
    # Subtree aggregates for Barnes-Hut evaluation
    # agg_qk stores sum(q_i * strike_i / FLOAT_SCALING) to fit in u64
    agg_q_up: int = 0
    agg_qk_up: int = 0
    agg_q_dn: int = 0
    agg_qk_dn: int = 0
    # Subtree strike range for curve intersection checks
    sub_min: int = 0
    sub_max: int = 0
    # Worst-case payout for this subtree at any settlement price
    max_payout: int = 0


def _strike_priority(strike: int) -> int:
    data = struct.pack("<Q", strike)
    h = hashlib.blake2b(data, digest_size=32).digest()
    value = 0
    for i in range(8):
        value = (value << 8) | h[i]
    return value


def _new_leaf(strike: int, qty: int, is_up: bool) -> Node:
    q_up = qty if is_up else 0
    q_dn = 0 if is_up else qty
    return Node(
        priority=_strike_priority(strike),
        q_up=q_up,
        q_dn=q_dn,
        agg_q_up=q_up,
        agg_qk_up=mul(q_up, strike),
        agg_q_dn=q_dn,
        agg_qk_dn=mul(q_dn, strike),
        sub_min=strike,
        sub_max=strike,
        max_payout=max(q_up, q_dn),
    )


def _interp_at(curve: list, cursor: int, strike: int, is_up: bool) -> int:
    """O(1) interpolation using cursor position."""
    length = len(curve)

    if cursor == 0:
        return curve[0].up_price if is_up else curve[0].dn_price
    if cursor >= length:
        return curve[-1].up_price if is_up else curve[-1].dn_price

    k_lo = curve[cursor - 1].strike
    k_hi = curve[cursor].strike
    p_lo = curve[cursor - 1].up_price if is_up else curve[cursor - 1].dn_price
    p_hi = curve[cursor].up_price if is_up else curve[cursor].dn_price

    if strike <= k_lo:
        return p_lo
    if strike >= k_hi:
        return p_hi

    rng = k_hi - k_lo
    if rng == 0:
        return p_lo

    offset = strike - k_lo
    ratio = div(offset, rng)
    if p_hi >= p_lo:
        return p_lo + mul(p_hi - p_lo, ratio)
    else:
        return p_lo - mul(p_lo - p_hi, ratio)


class Treap:
    def __init__(self):
        self.root: Optional[int] = None
        self.nodes: dict[int, Node] = {}
        self.size: int = 0
        self.mtm: int = 0

    def max_payout(self) -> int:
        if self.root is None:
            return 0
        return self.nodes[self.root].max_payout

    def strike_range(self) -> tuple[int, int]:
        if self.root is None:
            return (0, 0)
        root = self.nodes[self.root]
        return (root.sub_min, root.sub_max)

    def is_empty(self) -> bool:
        return self.root is None

    def evaluate(self, curve: list) -> int:
        """Evaluate total portfolio value against a piecewise-linear pricing curve.
        Curve elements must have .strike, .up_price, .dn_price attributes."""
        if self.root is None or len(curve) == 0:
            return 0
        value, _ = self._eval_inorder(self.root, curve, 0)
        return value

    def _eval_inorder(
        self, strike: int, curve: list, cursor: int
    ) -> tuple[int, int]:
        node = self.nodes[strike]
        length = len(curve)

        if node.agg_q_up == 0 and node.agg_q_dn == 0:
            return (0, cursor)

        # Advance cursor to first curve point strictly after sub_min
        while cursor < length and curve[cursor].strike <= node.sub_min:
            cursor += 1

        # No curve points strictly inside (sub_min, sub_max) → aggregate
        has_interior = (
            node.sub_min < node.sub_max
            and cursor < length
            and curve[cursor].strike < node.sub_max
        )

        if not has_interior:
            value = 0
            if node.agg_q_up > 0:
                k_avg = div(node.agg_qk_up, node.agg_q_up)
                value += mul(
                    node.agg_q_up, _interp_at(curve, cursor, k_avg, True)
                )
            if node.agg_q_dn > 0:
                k_avg = div(node.agg_qk_dn, node.agg_q_dn)
                value += mul(
                    node.agg_q_dn, _interp_at(curve, cursor, k_avg, False)
                )
            while cursor < length and curve[cursor].strike <= node.sub_max:
                cursor += 1
            return (value, cursor)

        # Curve has structure here — descend
        value = 0

        if node.left is not None:
            v, cursor = self._eval_inorder(node.left, curve, cursor)
            value += v

        while cursor < length and curve[cursor].strike <= strike:
            cursor += 1

        if node.q_up > 0:
            value += mul(node.q_up, _interp_at(curve, cursor, strike, True))
        if node.q_dn > 0:
            value += mul(node.q_dn, _interp_at(curve, cursor, strike, False))

        if node.right is not None:
            v, cursor = self._eval_inorder(node.right, curve, cursor)
            value += v

        return (value, cursor)

    def insert(self, strike: int, qty: int, is_up: bool):
        is_new = strike not in self.nodes
        new_root = self._insert_at(self.root, strike, qty, is_up)
        self.root = new_root
        if is_new:
            self.size += 1

    def remove(self, strike: int, qty: int, is_up: bool):
        had_node = strike in self.nodes
        new_root = self._remove_at(self.root, strike, qty, is_up)
        self.root = new_root
        if had_node and strike not in self.nodes:
            self.size -= 1

    # === Private: Insert ===

    def _insert_at(
        self, root: Optional[int], strike: int, qty: int, is_up: bool
    ) -> int:
        if root is None:
            self.nodes[strike] = _new_leaf(strike, qty, is_up)
            return strike

        root_strike = root

        if strike == root_strike:
            n = self.nodes[root_strike]
            if is_up:
                n.q_up += qty
            else:
                n.q_dn += qty
            self._recompute_agg(root_strike)
            return root_strike

        node = self.nodes[root_strike]

        if strike < root_strike:
            new_child = self._insert_at(node.left, strike, qty, is_up)
            if self.nodes[new_child].priority > node.priority:
                return self._rotate_right(root_strike, new_child)
            self.nodes[root_strike].left = new_child
        else:
            new_child = self._insert_at(node.right, strike, qty, is_up)
            if self.nodes[new_child].priority > node.priority:
                return self._rotate_left(root_strike, new_child)
            self.nodes[root_strike].right = new_child

        self._recompute_agg(root_strike)
        return root_strike

    # === Private: Remove ===

    def _remove_at(
        self, root: Optional[int], strike: int, qty: int, is_up: bool
    ) -> Optional[int]:
        assert root is not None, "ENodeNotFound"
        root_strike = root
        node = self.nodes[root_strike]

        if strike == root_strike:
            if is_up:
                assert node.q_up >= qty, "EInsufficientQuantity"
            else:
                assert node.q_dn >= qty, "EInsufficientQuantity"

            new_q_up = node.q_up - qty if is_up else node.q_up
            new_q_dn = node.q_dn - qty if not is_up else node.q_dn
            if new_q_up == 0 and new_q_dn == 0:
                return self._remove_node(root_strike)

            if is_up:
                self.nodes[root_strike].q_up -= qty
            else:
                self.nodes[root_strike].q_dn -= qty
            self._recompute_agg(root_strike)
            return root_strike

        if strike < root_strike:
            new_left = self._remove_at(node.left, strike, qty, is_up)
            self.nodes[root_strike].left = new_left
        else:
            new_right = self._remove_at(node.right, strike, qty, is_up)
            self.nodes[root_strike].right = new_right

        self._recompute_agg(root_strike)
        return root_strike

    def _remove_node(self, strike: int) -> Optional[int]:
        node = self.nodes[strike]
        has_left = node.left is not None
        has_right = node.right is not None

        if not has_left and not has_right:
            del self.nodes[strike]
            return None

        if has_left and has_right:
            promote_left = self.nodes[node.left].priority > self.nodes[node.right].priority
        else:
            promote_left = has_left

        if promote_left:
            left_strike = node.left
            left_node = self.nodes[left_strike]
            self.nodes[strike].left = left_node.right
            new_right = self._remove_node(strike)
            self.nodes[left_strike].right = new_right
            self._recompute_agg(left_strike)
            return left_strike
        else:
            right_strike = node.right
            right_node = self.nodes[right_strike]
            self.nodes[strike].right = right_node.left
            new_left = self._remove_node(strike)
            self.nodes[right_strike].left = new_left
            self._recompute_agg(right_strike)
            return right_strike

    # === Private: Rotations ===

    def _rotate_right(self, root_strike: int, left_strike: int) -> int:
        left_node = self.nodes[left_strike]
        self.nodes[root_strike].left = left_node.right
        self._recompute_agg(root_strike)
        self.nodes[left_strike].right = root_strike
        self._recompute_agg(left_strike)
        return left_strike

    def _rotate_left(self, root_strike: int, right_strike: int) -> int:
        right_node = self.nodes[right_strike]
        self.nodes[root_strike].right = right_node.left
        self._recompute_agg(root_strike)
        self.nodes[right_strike].left = root_strike
        self._recompute_agg(right_strike)
        return right_strike

    # === Private: Aggregates ===

    def _recompute_agg(self, strike: int):
        node = self.nodes[strike]
        node.agg_q_up = node.q_up
        node.agg_qk_up = mul(node.q_up, strike)
        node.agg_q_dn = node.q_dn
        node.agg_qk_dn = mul(node.q_dn, strike)
        node.sub_min = strike
        node.sub_max = strike

        left_agg_q_up = 0
        left_max_payout = 0
        right_agg_q_dn = 0
        right_max_payout = 0

        if node.left is not None:
            left = self.nodes[node.left]
            left_agg_q_up = left.agg_q_up
            left_max_payout = left.max_payout
            self._add_aggs(strike, left)

        if node.right is not None:
            right = self.nodes[node.right]
            right_agg_q_dn = right.agg_q_dn
            right_max_payout = right.max_payout
            self._add_aggs(strike, right)

        node.max_payout = max(
            left_max_payout + node.q_dn + right_agg_q_dn,
            left_agg_q_up + node.q_up + right_max_payout,
        )

    def _add_aggs(self, strike: int, b: Node):
        a = self.nodes[strike]
        a.agg_q_up += b.agg_q_up
        a.agg_qk_up += b.agg_qk_up
        a.agg_q_dn += b.agg_q_dn
        a.agg_qk_dn += b.agg_qk_dn
        a.sub_min = min(a.sub_min, b.sub_min)
        a.sub_max = max(a.sub_max, b.sub_max)

    # === Helpers ===

    def print_tree(self, node: Optional[int] = -1, indent: str = ""):
        if node == -1:
            node = self.root
        if node is None:
            return
        n = self.nodes[node]
        self.print_tree(n.right, indent + "    ")
        print(
            f"{indent}[{node}] up={n.q_up} dn={n.q_dn} "
            f"max_payout={n.max_payout} agg_up={n.agg_q_up} agg_dn={n.agg_q_dn}"
        )
        self.print_tree(n.left, indent + "    ")

    def brute_force_max_payout(self) -> int:
        """Sweep all strike boundaries to compute max payout directly."""
        if self.root is None:
            return 0
        strikes = sorted(self.nodes.keys())
        # Start with P below all strikes: all DOWN pays
        root = self.nodes[self.root]
        payout = root.agg_q_dn
        max_p = payout
        for s in strikes:
            n = self.nodes[s]
            payout += n.q_up
            payout -= n.q_dn
            max_p = max(max_p, payout)
        return max_p


@dataclass
class Op:
    is_insert: bool
    strike: int
    qty: int
    is_up: bool


def generate_ops(n: int = 10_000, seed: int = 42) -> list[Op]:
    """Generate n random insert/remove operations."""
    import random

    rng = random.Random(seed)
    ops: list[Op] = []
    # Track outstanding positions so removes are valid
    # (strike, is_up) -> total qty
    outstanding: dict[tuple[int, bool], int] = {}
    strikes = list(range(10, 200, 5))

    for _ in range(n):
        strike = rng.choice(strikes)
        is_up = rng.choice([True, False])
        key = (strike, is_up)
        current = outstanding.get(key, 0)

        # 70% insert, 30% remove (only if there's something to remove)
        if current > 0 and rng.random() < 0.3:
            qty = rng.randint(1, current)
            ops.append(Op(is_insert=False, strike=strike, qty=qty, is_up=is_up))
            outstanding[key] = current - qty
        else:
            qty = rng.randint(1, 500)
            ops.append(Op(is_insert=True, strike=strike, qty=qty, is_up=is_up))
            outstanding[key] = current + qty

    return ops


def brute_force_max_payouts(ops: list[Op]) -> list[int]:
    """Replay ops, compute max_payout via brute force sweep after each op."""
    # Track (strike, is_up) -> qty
    positions: dict[tuple[int, bool], int] = {}
    results: list[int] = []

    for op in ops:
        key = (op.strike, op.is_up)
        current = positions.get(key, 0)
        if op.is_insert:
            positions[key] = current + op.qty
        else:
            positions[key] = current - op.qty

        # Sweep all strike boundaries to find max payout
        strikes = sorted({k[0] for k, v in positions.items() if v > 0})
        if not strikes:
            results.append(0)
            continue

        total_dn = sum(v for (s, up), v in positions.items() if not up and v > 0)
        payout = total_dn
        max_p = payout
        for s in strikes:
            up_qty = positions.get((s, True), 0)
            dn_qty = positions.get((s, False), 0)
            payout += up_qty
            payout -= dn_qty
            max_p = max(max_p, payout)
        results.append(max_p)

    return results


if __name__ == "__main__":
    ops = generate_ops()
    bf_results = brute_force_max_payouts(ops)

    # Replay through treap and compare
    t = Treap()
    mismatches = 0
    for i, op in enumerate(ops):
        if op.is_insert:
            t.insert(op.strike, op.qty, op.is_up)
        else:
            t.remove(op.strike, op.qty, op.is_up)
        if t.max_payout() != bf_results[i]:
            action = "insert" if op.is_insert else "remove"
            direction = "UP" if op.is_up else "DOWN"
            print(
                f"MISMATCH at op {i}: {action} {op.qty} {direction} @ {op.strike} "
                f"— brute_force={bf_results[i]} treap={t.max_payout()}"
            )
            mismatches += 1
            if mismatches >= 10:
                break

    if mismatches == 0:
        print(f"All {len(ops)} operations match!")
