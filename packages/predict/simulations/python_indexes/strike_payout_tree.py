"""Sparse payout-liability treap mirror for Predict Python replay."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib


@dataclass(frozen=True, slots=True)
class PayoutTerms:
    terminal_payout: int
    live_backing_payout: int


@dataclass(frozen=True, slots=True)
class PayoutSummary:
    total_start: PayoutTerms
    total_end: PayoutTerms
    max_live_backing_prefix_gain: int


@dataclass(slots=True)
class PayoutNode:
    priority: int
    left: int | None
    right: int | None
    summary: PayoutSummary


ZERO_TERMS = PayoutTerms(0, 0)
ZERO_SUMMARY = PayoutSummary(ZERO_TERMS, ZERO_TERMS, 0)


def strike_priority(strike: int) -> int:
    digest = hashlib.blake2b(strike.to_bytes(8, "little"), digest_size=32).digest()
    out = 0
    for byte in digest[:8]:
        out = (out << 8) | byte
    return out


def _apply_terms_delta(value: PayoutTerms, delta: PayoutTerms, add: bool) -> PayoutTerms:
    if add:
        return PayoutTerms(
            value.terminal_payout + delta.terminal_payout,
            value.live_backing_payout + delta.live_backing_payout,
        )
    if value.terminal_payout < delta.terminal_payout or value.live_backing_payout < delta.live_backing_payout:
        raise ValueError("insufficient payout terms")
    return PayoutTerms(
        value.terminal_payout - delta.terminal_payout,
        value.live_backing_payout - delta.live_backing_payout,
    )


def _add_terms(left: PayoutTerms, right: PayoutTerms) -> PayoutTerms:
    return PayoutTerms(
        left.terminal_payout + right.terminal_payout,
        left.live_backing_payout + right.live_backing_payout,
    )


def _positive_live_delta(start: int, end: int, gain: int) -> int:
    positive = start + gain
    return positive - end if positive > end else 0


def _boundary_summary(start: PayoutTerms, end: PayoutTerms) -> PayoutSummary:
    return PayoutSummary(
        total_start=start,
        total_end=end,
        max_live_backing_prefix_gain=_positive_live_delta(
            start.live_backing_payout,
            end.live_backing_payout,
            0,
        ),
    )


def _combine_summaries(left: PayoutSummary, right: PayoutSummary) -> PayoutSummary:
    right_gain_after_left = _positive_live_delta(
        left.total_start.live_backing_payout,
        left.total_end.live_backing_payout,
        right.max_live_backing_prefix_gain,
    )
    return PayoutSummary(
        total_start=_add_terms(left.total_start, right.total_start),
        total_end=_add_terms(left.total_end, right.total_end),
        max_live_backing_prefix_gain=max(left.max_live_backing_prefix_gain, right_gain_after_left),
    )


def _summarize_node(
    left: PayoutSummary,
    local_start: PayoutTerms,
    local_end: PayoutTerms,
    right: PayoutSummary,
) -> PayoutSummary:
    return _combine_summaries(_combine_summaries(left, _boundary_summary(local_start, local_end)), right)


class StrikePayoutTree:
    def __init__(
        self,
        *,
        min_strike: int,
        tick_size: int,
        max_strike: int,
        neg_inf: int,
        pos_inf: int,
    ) -> None:
        if tick_size <= 0:
            raise ValueError("invalid tick size")
        if min_strike > max_strike:
            raise ValueError("invalid strike range")
        if min_strike % tick_size != 0 or max_strike % tick_size != 0:
            raise ValueError("unaligned strike grid")
        self.root: int | None = None
        self.nodes: dict[int, PayoutNode] = {}
        self.tick_size = tick_size
        self.min_strike = min_strike
        self.max_strike = max_strike
        self.neg_inf = neg_inf
        self.pos_inf = pos_inf
        self.base = ZERO_TERMS

    def insert_range(self, lower: int, higher: int, terminal_payout: int, live_backing_payout: int) -> None:
        self._apply_range(lower, higher, PayoutTerms(terminal_payout, live_backing_payout), True)

    def remove_range(self, lower: int, higher: int, terminal_payout: int, live_backing_payout: int) -> None:
        self._apply_range(lower, higher, PayoutTerms(terminal_payout, live_backing_payout), False)

    def max_live_backing_payout(self) -> int:
        max_payout = self.base.live_backing_payout
        if self.root is not None:
            max_payout += self.nodes[self.root].summary.max_live_backing_prefix_gain
        return max_payout

    def settled_payout_liability(self, settlement: int) -> int:
        return self._settlement_prefix_terms(self.root, settlement, self.base).terminal_payout

    def _apply_range(self, lower: int, higher: int, terms: PayoutTerms, add: bool) -> None:
        self._assert_range_boundaries(lower, higher)
        if terms.terminal_payout == 0 and terms.live_backing_payout == 0:
            return
        if terms.terminal_payout > terms.live_backing_payout:
            raise ValueError("invalid payout terms")

        if lower == self.neg_inf:
            self.base = _apply_terms_delta(self.base, terms, add)
            self._apply_boundary_delta(higher, terms, False, add)
        else:
            self._apply_boundary_delta(lower, terms, True, add)
            if higher != self.pos_inf:
                self._apply_boundary_delta(higher, terms, False, add)

    def _apply_boundary_delta(self, strike: int, terms: PayoutTerms, is_start: bool, add: bool) -> None:
        self.root = self._apply_at(self.root, strike, terms, is_start, add)

    def _apply_at(
        self,
        root: int | None,
        strike: int,
        terms: PayoutTerms,
        is_start: bool,
        add: bool,
    ) -> int:
        if root is None:
            if not add:
                raise ValueError("insufficient payout terms")
            self.nodes[strike] = self._new_leaf(strike, terms, is_start)
            return strike

        node = self.nodes[root]
        left_summary = self._subtree_summary(node.left)
        right_summary = self._subtree_summary(node.right)
        local_start, local_end = self._local_boundary_terms_from_summaries(node, left_summary, right_summary)

        if strike == root:
            if is_start:
                local_start = _apply_terms_delta(local_start, terms, add)
            else:
                local_end = _apply_terms_delta(local_end, terms, add)
            self._write_node_with_summaries(root, node, local_start, local_end, left_summary, right_summary)
            return root

        if strike < root:
            new_left = self._apply_at(node.left, strike, terms, is_start, add)
            left_node = self.nodes[new_left]
            if left_node.priority > node.priority:
                return self._rotate_right(root, node, local_start, local_end, new_left, left_node)
            node.left = new_left
            left_summary = left_node.summary
        else:
            new_right = self._apply_at(node.right, strike, terms, is_start, add)
            right_node = self.nodes[new_right]
            if right_node.priority > node.priority:
                return self._rotate_left(root, node, local_start, local_end, new_right, right_node)
            node.right = new_right
            right_summary = right_node.summary

        self._write_node_with_summaries(root, node, local_start, local_end, left_summary, right_summary)
        return root

    def _new_leaf(self, strike: int, terms: PayoutTerms, is_start: bool) -> PayoutNode:
        start, end = (terms, ZERO_TERMS) if is_start else (ZERO_TERMS, terms)
        return PayoutNode(
            priority=strike_priority(strike),
            left=None,
            right=None,
            summary=_boundary_summary(start, end),
        )

    def _rotate_right(
        self,
        root_strike: int,
        root_node: PayoutNode,
        root_start: PayoutTerms,
        root_end: PayoutTerms,
        left_strike: int,
        left_node: PayoutNode,
    ) -> int:
        left_start, left_end = self._local_boundary_terms(left_node)
        root_node.left = left_node.right
        self._write_node(root_strike, root_node, root_start, root_end)
        left_node.right = root_strike
        self._write_node(left_strike, left_node, left_start, left_end)
        return left_strike

    def _rotate_left(
        self,
        root_strike: int,
        root_node: PayoutNode,
        root_start: PayoutTerms,
        root_end: PayoutTerms,
        right_strike: int,
        right_node: PayoutNode,
    ) -> int:
        right_start, right_end = self._local_boundary_terms(right_node)
        root_node.right = right_node.left
        self._write_node(root_strike, root_node, root_start, root_end)
        right_node.left = root_strike
        self._write_node(right_strike, right_node, right_start, right_end)
        return right_strike

    def _settlement_prefix_terms(self, root: int | None, settlement: int, running: PayoutTerms) -> PayoutTerms:
        if root is None:
            return running
        node = self.nodes[root]
        if settlement <= root:
            return self._settlement_prefix_terms(node.left, settlement, running)

        left_summary = self._subtree_summary(node.left)
        right_summary = self._subtree_summary(node.right)
        running = _apply_terms_delta(running, left_summary.total_start, True)
        running = _apply_terms_delta(running, left_summary.total_end, False)
        local_start, local_end = self._local_boundary_terms_from_summaries(node, left_summary, right_summary)
        running = _apply_terms_delta(running, local_start, True)
        running = _apply_terms_delta(running, local_end, False)
        return self._settlement_prefix_terms(node.right, settlement, running)

    def _write_node(self, strike: int, node: PayoutNode, local_start: PayoutTerms, local_end: PayoutTerms) -> None:
        self._write_node_with_summaries(
            strike,
            node,
            local_start,
            local_end,
            self._subtree_summary(node.left),
            self._subtree_summary(node.right),
        )

    def _write_node_with_summaries(
        self,
        strike: int,
        node: PayoutNode,
        local_start: PayoutTerms,
        local_end: PayoutTerms,
        left: PayoutSummary,
        right: PayoutSummary,
    ) -> None:
        node.summary = _summarize_node(left, local_start, local_end, right)
        self.nodes[strike] = node

    def _local_boundary_terms(self, node: PayoutNode) -> tuple[PayoutTerms, PayoutTerms]:
        left = self._subtree_summary(node.left)
        right = self._subtree_summary(node.right)
        return self._local_boundary_terms_from_summaries(node, left, right)

    @staticmethod
    def _local_boundary_terms_from_summaries(
        node: PayoutNode,
        left: PayoutSummary,
        right: PayoutSummary,
    ) -> tuple[PayoutTerms, PayoutTerms]:
        local_start = _apply_terms_delta(node.summary.total_start, left.total_start, False)
        local_start = _apply_terms_delta(local_start, right.total_start, False)
        local_end = _apply_terms_delta(node.summary.total_end, left.total_end, False)
        local_end = _apply_terms_delta(local_end, right.total_end, False)
        return local_start, local_end

    def _subtree_summary(self, root: int | None) -> PayoutSummary:
        if root is None:
            return ZERO_SUMMARY
        return self.nodes[root].summary

    def _assert_range_boundaries(self, lower: int, higher: int) -> None:
        if lower >= higher:
            raise ValueError("invalid payout range")
        if lower == self.neg_inf and higher == self.pos_inf:
            raise ValueError("invalid payout range")
        if lower != self.neg_inf:
            self._assert_finite_boundary(lower)
        if higher != self.pos_inf:
            self._assert_finite_boundary(higher)

    def _assert_finite_boundary(self, strike: int) -> None:
        if strike < self.min_strike or strike > self.max_strike:
            raise ValueError("finite strike out of range")
        if (strike - self.min_strike) % self.tick_size != 0:
            raise ValueError("unaligned finite strike")
