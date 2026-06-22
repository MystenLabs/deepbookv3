"""Paged liquidation index mirror used by ``python_replay.py``.

The shape follows ``strike_exposure/index/liquidation_book.move`` and
``order.move``: active leveraged order IDs are held in sorted pages, and the
passive scan advances a watermark through the tail after a fixed head scan.
"""

from __future__ import annotations

from bisect import bisect_left, bisect_right

PAGE_CAPACITY = 64

QUANTITY_LOTS_OFFSET = 200
FLOOR_SHARES_OFFSET = 136
OPENED_AT_OFFSET = 88
# Absolute u24 ticks pack at these offsets (order.move LOWER_TICK_OFFSET /
# HIGHER_TICK_OFFSET). The grid-relative boundary-index encoding is gone: the
# order now stores absolute ticks directly.
LOWER_TICK_OFFSET = 64
HIGHER_TICK_OFFSET = 40

U24_MASK = (1 << 24) - 1
U32_MASK = (1 << 32) - 1
U40_MASK = (1 << 40) - 1
U48_MASK = (1 << 48) - 1
U64_MASK = (1 << 64) - 1


def tick_for_order_side(
    strike: int,
    *,
    tick_size: int,
    pos_inf_tick: int,
    neg_inf: int,
    pos_inf: int,
) -> int:
    # Absolute tick for an order boundary: raw_strike = tick * tick_size, with tick 0
    # the neg-inf sentinel (lower side) and pos_inf_tick the pos-inf sentinel (higher
    # side). Mirrors range_codec / order.move; no centered grid.
    if strike == neg_inf:
        return 0
    if strike == pos_inf:
        return pos_inf_tick
    if strike % tick_size != 0:
        raise ValueError("unaligned order strike")
    tick = strike // tick_size
    if tick <= 0 or tick >= pos_inf_tick:
        raise ValueError("strike tick outside the finite tick domain")
    return tick


def encode_order_id(
    *,
    opened_at_ms: int,
    lower_tick: int,
    higher_tick: int,
    pos_inf_tick: int,
    floor_shares: int,
    quantity: int,
    sequence: int,
    position_lot_size: int,
) -> int:
    # Mirrors order::new / assert_valid_order_shape exactly (absolute u24 ticks).
    quantity_lots = quantity // position_lot_size
    if quantity_lots <= 0 or quantity_lots > U32_MASK or quantity % position_lot_size != 0:
        raise ValueError("invalid order quantity")
    if floor_shares < 0 or floor_shares > U64_MASK or floor_shares > quantity:
        raise ValueError("invalid floor shares")
    if opened_at_ms > U48_MASK:
        raise ValueError("opened_at_ms does not fit in order id")
    if lower_tick > U24_MASK or higher_tick > U24_MASK:
        raise ValueError("tick does not fit in order id")
    if lower_tick > pos_inf_tick or higher_tick > pos_inf_tick:
        raise ValueError("tick outside protocol domain")
    if lower_tick >= higher_tick:
        raise ValueError("invalid tick range")
    if lower_tick == 0 and higher_tick == pos_inf_tick:
        raise ValueError("full-open tick range is invalid")
    if sequence > U40_MASK:
        raise ValueError("sequence does not fit in order id")
    # Leveraged orders must have one open boundary (lower == neg-inf OR higher ==
    # pos-inf), so the floor is one-sided.
    if floor_shares > 0 and lower_tick != 0 and higher_tick != pos_inf_tick:
        raise ValueError("leveraged orders must have one open boundary")

    quantity_lots_key = U32_MASK - quantity_lots
    floor_shares_key = U64_MASK - floor_shares
    return (
        (quantity_lots_key << QUANTITY_LOTS_OFFSET)
        | (floor_shares_key << FLOOR_SHARES_OFFSET)
        | (opened_at_ms << OPENED_AT_OFFSET)
        | (lower_tick << LOWER_TICK_OFFSET)
        | (higher_tick << HIGHER_TICK_OFFSET)
        | sequence
    )


class LiquidationBook:
    def __init__(self) -> None:
        self.pages: dict[int, list[int]] = {}
        self.page_ids: list[int] = []
        self.max_order_ids: list[int] = []
        self.next_page_id = 0
        self.active_order_count = 0
        self.passive_watermark: int | None = None
        self.liquidated_orders: set[int] = set()
        self.refs_by_order_id: dict[int, str] = {}
        self.order_ids_by_ref: dict[str, int] = {}

    def insert_order(self, order_id: int, ref: str) -> None:
        if order_id in self.liquidated_orders:
            raise ValueError("liquidated order already exists")
        if ref in self.order_ids_by_ref or order_id in self.refs_by_order_id:
            raise ValueError("active order already exists")
        self._insert_active_order_id(order_id)
        self.refs_by_order_id[order_id] = ref
        self.order_ids_by_ref[ref] = order_id

    def remove_ref(self, ref: str) -> int:
        order_id = self.order_ids_by_ref.get(ref)
        if order_id is None:
            raise ValueError(f"active order {ref} not found")
        self.remove_order_id(order_id)
        return order_id

    def remove_order_id(self, order_id: int) -> None:
        self._remove_active_order_id(order_id)
        ref = self.refs_by_order_id.pop(order_id)
        del self.order_ids_by_ref[ref]

    def mark_ref_liquidated(self, ref: str) -> int:
        order_id = self.remove_ref(ref)
        if order_id in self.liquidated_orders:
            raise ValueError("liquidated order already exists")
        self.liquidated_orders.add(order_id)
        return order_id

    def clear_liquidated(self, order_id: int) -> None:
        if order_id not in self.liquidated_orders:
            raise ValueError("liquidated order not found")
        self.liquidated_orders.remove(order_id)

    def is_liquidated(self, order_id: int) -> bool:
        return order_id in self.liquidated_orders

    def ref_for(self, order_id: int) -> str:
        return self.refs_by_order_id[order_id]

    def active_refs(self) -> list[str]:
        refs: list[str] = []
        for page_id in self.page_ids:
            refs.extend(self.refs_by_order_id[order_id] for order_id in self.pages[page_id])
        return refs

    def select_liquidation_candidates(self, budget: int, head_scan_divisor: int) -> list[int]:
        candidates: list[int] = []
        if self.active_order_count == 0 or budget == 0:
            return candidates

        tail_budget = budget // head_scan_divisor
        head_budget = budget - tail_budget

        tail_start = self._collect_head_candidates(candidates, head_budget)
        scan_budget = budget - len(candidates)
        self._collect_passive_candidates(candidates, scan_budget, tail_start)
        return candidates

    def _insert_active_order_id(self, order_id: int) -> None:
        if self.active_order_count == 0:
            page_id = self._new_page_id()
            self.pages[page_id] = [order_id]
            self.page_ids.append(page_id)
            self.max_order_ids.append(order_id)
            self.active_order_count = 1
            return

        page_ix = self._page_index_for_insert(order_id)
        page_id = self.page_ids[page_ix]
        page = self.pages[page_id]
        offset = bisect_left(page, order_id)
        if offset < len(page) and page[offset] == order_id:
            raise ValueError("active order already exists")
        page.insert(offset, order_id)

        should_split = len(page) > PAGE_CAPACITY
        right_order_ids: list[int] = []
        if should_split:
            split_at = len(page) // 2
            right_order_ids = page[split_at:]
            del page[split_at:]

        self.max_order_ids[page_ix] = page[-1]
        if should_split:
            right_page_id = self._new_page_id()
            self.pages[right_page_id] = right_order_ids
            self.page_ids.insert(page_ix + 1, right_page_id)
            self.max_order_ids.insert(page_ix + 1, right_order_ids[-1])
        self.active_order_count += 1

    def _remove_active_order_id(self, order_id: int) -> None:
        if self.active_order_count == 0:
            raise ValueError("active order not found")
        page_ix = bisect_left(self.max_order_ids, order_id)
        if page_ix >= len(self.page_ids):
            raise ValueError("active order not found")
        page_id = self.page_ids[page_ix]
        page = self.pages[page_id]
        offset = bisect_left(page, order_id)
        if offset >= len(page) or page[offset] != order_id:
            raise ValueError("active order not found")
        page.pop(offset)

        self.active_order_count -= 1
        if not page:
            self._remove_page_at(page_ix)
        else:
            self.max_order_ids[page_ix] = page[-1]
            self._merge_page_if_small(page_ix)

        if self.active_order_count == 0:
            self.passive_watermark = None

    def _collect_head_candidates(self, candidates: list[int], budget: int) -> tuple[int, int] | None:
        count = 0
        candidate = self._first_cursor()
        while count < budget and candidate is not None:
            candidates.append(self._order_id_at(candidate))
            count += 1
            candidate = self._next_cursor(candidate)
        return candidate

    def _collect_passive_candidates(
        self,
        candidates: list[int],
        scan_budget: int,
        tail_start: tuple[int, int] | None,
    ) -> None:
        if scan_budget == 0 or tail_start is None:
            return
        passive_domain_count = self.active_order_count - len(candidates)
        if passive_domain_count == 0:
            return

        candidate = self._first_passive_cursor(tail_start)
        added = 0
        visited = 0
        last_order_id: int | None = None
        while added < scan_budget and visited < passive_domain_count:
            order_id = self._order_id_at(candidate)
            candidates.append(order_id)
            added += 1
            visited += 1
            last_order_id = order_id
            next_cursor = self._next_cursor(candidate)
            candidate = next_cursor if next_cursor is not None else tail_start

        if last_order_id is not None:
            self.passive_watermark = last_order_id

    def _first_passive_cursor(self, tail_start: tuple[int, int]) -> tuple[int, int]:
        if self.passive_watermark is not None:
            candidate = self._cursor_after_order_id(self.passive_watermark)
            if candidate is not None and not self._is_before(candidate, tail_start):
                return candidate
        return tail_start

    def _first_cursor(self) -> tuple[int, int] | None:
        if self.active_order_count == 0:
            return None
        return (0, 0)

    def _next_cursor(self, cursor: tuple[int, int]) -> tuple[int, int] | None:
        page_ix, offset = cursor
        page = self.pages[self.page_ids[page_ix]]
        next_offset = offset + 1
        if next_offset < len(page):
            return (page_ix, next_offset)
        next_page_ix = page_ix + 1
        if next_page_ix < len(self.page_ids):
            return (next_page_ix, 0)
        return None

    def _cursor_after_order_id(self, order_id: int) -> tuple[int, int] | None:
        page_ix = bisect_right(self.max_order_ids, order_id)
        if page_ix >= len(self.page_ids):
            return None
        page = self.pages[self.page_ids[page_ix]]
        offset = bisect_right(page, order_id)
        if offset < len(page):
            return (page_ix, offset)
        if page_ix + 1 < len(self.page_ids):
            return (page_ix + 1, 0)
        return None

    def _order_id_at(self, cursor: tuple[int, int]) -> int:
        page_ix, offset = cursor
        return self.pages[self.page_ids[page_ix]][offset]

    @staticmethod
    def _is_before(cursor: tuple[int, int], other: tuple[int, int]) -> bool:
        return cursor[0] < other[0] or (cursor[0] == other[0] and cursor[1] < other[1])

    def _new_page_id(self) -> int:
        page_id = self.next_page_id
        self.next_page_id += 1
        return page_id

    def _page_index_for_insert(self, order_id: int) -> int:
        page_ix = bisect_left(self.max_order_ids, order_id)
        if page_ix < len(self.page_ids):
            return page_ix
        return len(self.page_ids) - 1

    def _remove_page_at(self, page_ix: int) -> None:
        page_id = self.page_ids.pop(page_ix)
        self.max_order_ids.pop(page_ix)
        del self.pages[page_id]

    def _merge_page_if_small(self, page_ix: int) -> None:
        page_count = len(self.page_ids)
        if page_count <= 1:
            return
        page_len = self._page_length(page_ix)
        if page_len >= PAGE_CAPACITY // 2:
            return
        if page_ix > 0:
            left_ix = page_ix - 1
            if self._page_length(left_ix) + page_len <= PAGE_CAPACITY:
                self._merge_adjacent_pages(left_ix, page_ix)
                return
        if page_ix + 1 < page_count:
            right_ix = page_ix + 1
            if page_len + self._page_length(right_ix) <= PAGE_CAPACITY:
                self._merge_adjacent_pages(page_ix, right_ix)

    def _page_length(self, page_ix: int) -> int:
        return len(self.pages[self.page_ids[page_ix]])

    def _merge_adjacent_pages(self, left_ix: int, right_ix: int) -> None:
        left_page = self.pages[self.page_ids[left_ix]]
        right_page_id = self.page_ids[right_ix]
        left_page.extend(self.pages.pop(right_page_id))
        self.max_order_ids[left_ix] = left_page[-1]
        self.page_ids.pop(right_ix)
        self.max_order_ids.pop(right_ix)
