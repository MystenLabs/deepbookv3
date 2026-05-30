"""Dense NAV matrix mirror for Predict Python replay."""

from __future__ import annotations

from dataclasses import dataclass, field

PAGE_SLOTS = 128


@dataclass(slots=True)
class _NavPage:
    start_quantity: list[int] = field(default_factory=lambda: [0] * PAGE_SLOTS)
    start_strike_quantity: list[int] = field(default_factory=lambda: [0] * PAGE_SLOTS)
    end_quantity: list[int] = field(default_factory=lambda: [0] * PAGE_SLOTS)
    end_strike_quantity: list[int] = field(default_factory=lambda: [0] * PAGE_SLOTS)


def _apply_exact_delta(value: int, amount: int, add: bool) -> int:
    if add:
        return value + amount
    if value < amount:
        raise ValueError("insufficient quantity")
    return value - amount


def _apply_weighted_delta(quantity: int, strike_quantity: int, delta: tuple[int, int], add: bool) -> tuple[int, int]:
    dq, dsq = delta
    if add:
        return quantity + dq, strike_quantity + dsq
    if quantity < dq or strike_quantity < dsq:
        raise ValueError("insufficient weighted quantity")
    return quantity - dq, strike_quantity - dsq


class StrikeNavMatrix:
    def __init__(
        self,
        *,
        min_strike: int,
        tick_size: int,
        max_strike: int,
        float_scaling: int,
        neg_inf: int,
        pos_inf: int,
    ) -> None:
        if tick_size <= 0:
            raise ValueError("invalid tick size")
        if min_strike > max_strike:
            raise ValueError("invalid strike range")
        if min_strike % tick_size != 0 or max_strike % tick_size != 0:
            raise ValueError("unaligned strike grid")

        self.min_strike = min_strike
        self.tick_size = tick_size
        self.max_strike = max_strike
        self.float_scaling = float_scaling
        self.neg_inf = neg_inf
        self.pos_inf = pos_inf
        self.total_strikes = (max_strike - min_strike) // tick_size + 1
        page_count = (self.total_strikes - 1) // PAGE_SLOTS + 1
        self.pages = [_NavPage() for _ in range(page_count)]
        self.base_qty = 0
        self.floor_shares = 0
        self.version = 0

    def insert_range(self, lower: int, higher: int, qty: int, floor_shares: int) -> None:
        self._apply_range(lower, higher, qty, floor_shares, True)

    def remove_range(self, lower: int, higher: int, qty: int, floor_shares: int) -> None:
        self._apply_range(lower, higher, qty, floor_shares, False)

    def live_value(
        self,
        curve: list[dict[str, int]],
        *,
        minted_min_strike: int,
        minted_max_strike: int,
        floor_index: int,
    ) -> int:
        if not curve:
            raise ValueError("empty NAV curve")
        if curve[0]["strike"] > minted_min_strike or curve[-1]["strike"] < minted_max_strike:
            raise ValueError("invalid NAV curve range")

        value = self._mul_scaled(self.base_qty, self.float_scaling)
        page_lo, slot_lo = self._unchecked_strike_to_coords(curve[0]["strike"])
        start, end = self._boundary_weighted_quantities(page_lo, slot_lo)
        first = curve[0]
        value += self._mul_scaled(start[0], first["up_price"])
        value -= self._mul_scaled(end[0], first["up_price"])

        for i in range(1, len(curve)):
            lo = curve[i - 1]
            hi = curve[i]
            page_hi, slot_hi = self._unchecked_strike_to_coords(hi["strike"])
            start_delta, end_delta = self._accumulate_segment_values(page_lo, slot_lo, page_hi, slot_hi)
            value += self._weighted_segment_value(
                start_delta,
                lo["strike"],
                hi["strike"],
                lo["up_price"],
                hi["up_price"],
            )
            value -= self._weighted_segment_value(
                end_delta,
                lo["strike"],
                hi["strike"],
                lo["up_price"],
                hi["up_price"],
            )
            page_lo, slot_lo = page_hi, slot_hi

        floor_value = self.floor_shares * floor_index // self.float_scaling
        if value < floor_value:
            raise ValueError("NAV live value below aggregate floor")
        return value - floor_value

    def _apply_range(self, lower: int, higher: int, qty: int, floor_shares: int, add: bool) -> None:
        self._assert_range_boundaries(lower, higher, qty)
        self.floor_shares = _apply_exact_delta(self.floor_shares, floor_shares, add)

        if lower == self.neg_inf:
            self.base_qty = _apply_exact_delta(self.base_qty, qty, add)
        else:
            self._apply_boundary_delta(lower, qty, True, add)
        if higher != self.pos_inf:
            self._apply_boundary_delta(higher, qty, False, add)
        self.version += 1

    def _apply_boundary_delta(self, strike: int, qty: int, is_start: bool, add: bool) -> None:
        page_key, slot = self._unchecked_strike_to_coords(strike)
        weighted = (qty, self._mul_scaled(qty, strike))
        page = self.pages[page_key]
        for i in range(slot, PAGE_SLOTS):
            tick_index = page_key * PAGE_SLOTS + i
            if tick_index >= self.total_strikes:
                break
            if is_start:
                page.start_quantity[i], page.start_strike_quantity[i] = _apply_weighted_delta(
                    page.start_quantity[i],
                    page.start_strike_quantity[i],
                    weighted,
                    add,
                )
            else:
                page.end_quantity[i], page.end_strike_quantity[i] = _apply_weighted_delta(
                    page.end_quantity[i],
                    page.end_strike_quantity[i],
                    weighted,
                    add,
                )

    def _boundary_weighted_quantities(self, page_key: int, slot: int) -> tuple[tuple[int, int], tuple[int, int]]:
        page = self.pages[page_key]
        start = (page.start_quantity[slot], page.start_strike_quantity[slot])
        end = (page.end_quantity[slot], page.end_strike_quantity[slot])
        if slot == 0:
            return start, end
        prev_start = (page.start_quantity[slot - 1], page.start_strike_quantity[slot - 1])
        prev_end = (page.end_quantity[slot - 1], page.end_strike_quantity[slot - 1])
        return (
            (start[0] - prev_start[0], start[1] - prev_start[1]),
            (end[0] - prev_end[0], end[1] - prev_end[1]),
        )

    def _accumulate_segment_values(
        self,
        start_page: int,
        start_slot: int,
        end_page: int,
        end_slot: int,
    ) -> tuple[tuple[int, int], tuple[int, int]]:
        page_key = start_page
        start_delta = (0, 0)
        end_delta = (0, 0)
        while page_key <= end_page:
            page = self.pages[page_key]
            end_inclusive = end_slot if page_key == end_page else PAGE_SLOTS - 1
            start_delta = (
                start_delta[0] + page.start_quantity[end_inclusive],
                start_delta[1] + page.start_strike_quantity[end_inclusive],
            )
            end_delta = (
                end_delta[0] + page.end_quantity[end_inclusive],
                end_delta[1] + page.end_strike_quantity[end_inclusive],
            )

            if page_key == start_page:
                start_delta = (
                    start_delta[0] - page.start_quantity[start_slot],
                    start_delta[1] - page.start_strike_quantity[start_slot],
                )
                end_delta = (
                    end_delta[0] - page.end_quantity[start_slot],
                    end_delta[1] - page.end_strike_quantity[start_slot],
                )

            if page_key == end_page:
                break
            page_key += 1
        return start_delta, end_delta

    def _assert_range_boundaries(self, lower: int, higher: int, qty: int) -> None:
        if lower >= higher:
            raise ValueError("invalid NAV range")
        if lower == self.neg_inf and higher == self.pos_inf:
            raise ValueError("invalid NAV range")
        if qty <= 0:
            raise ValueError("zero NAV quantity")
        if lower != self.neg_inf:
            self._assert_finite_boundary(lower)
        if higher != self.pos_inf:
            self._assert_finite_boundary(higher)

    def _assert_finite_boundary(self, strike: int) -> None:
        if strike < self.min_strike or strike > self.max_strike:
            raise ValueError("finite strike out of range")
        if (strike - self.min_strike) % self.tick_size != 0:
            raise ValueError("unaligned finite strike")

    def _unchecked_strike_to_coords(self, strike: int) -> tuple[int, int]:
        tick_index = (strike - self.min_strike) // self.tick_size
        return tick_index // PAGE_SLOTS, tick_index % PAGE_SLOTS

    def _mul_scaled(self, a: int, b: int) -> int:
        return a * b // self.float_scaling

    def _div_scaled(self, a: int, b: int) -> int:
        return a * self.float_scaling // b

    def _weighted_segment_value(
        self,
        weighted: tuple[int, int],
        strike_lo: int,
        strike_hi: int,
        price_lo: int,
        price_hi: int,
    ) -> int:
        quantity = weighted[0]
        if quantity == 0:
            return 0
        strike_avg = self._div_scaled(weighted[1], quantity)
        ratio = self._div_scaled(strike_avg - strike_lo, strike_hi - strike_lo)
        if price_hi >= price_lo:
            price = price_lo + self._mul_scaled(price_hi - price_lo, ratio)
        else:
            price = price_lo - self._mul_scaled(price_lo - price_hi, ratio)
        return self._mul_scaled(quantity, price)
