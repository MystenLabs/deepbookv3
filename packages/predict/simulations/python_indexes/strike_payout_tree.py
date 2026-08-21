"""Independent quantity-only payout index used by the Predict parity model."""

from __future__ import annotations

from collections.abc import Callable


class StrikePayoutTree:
    """A deliberately simple ordered-boundary model of the on-chain AVL index.

    The contract optimizes access with an AVL tree. Parity uses a plain dictionary
    and sorted folds so the expected economics do not share its implementation.
    """

    def __init__(self, *, tick_size: int, pos_inf_tick: int) -> None:
        if tick_size <= 0:
            raise ValueError("invalid tick size")
        self.tick_size = tick_size
        self.pos_inf_tick = pos_inf_tick
        self.base = 0
        self.boundaries: dict[int, list[int]] = {}

    def insert_range(self, lower_tick: int, higher_tick: int, quantity: int) -> None:
        self._apply_range(lower_tick, higher_tick, quantity, True)

    def remove_range(self, lower_tick: int, higher_tick: int, quantity: int) -> None:
        self._apply_range(lower_tick, higher_tick, quantity, False)

    def payout_reserve_terms(self) -> tuple[int, int]:
        running = self.base
        maximum = running
        total = self.base
        for start, end in self._ordered_boundaries():
            total += start
            running += start
            running -= end
            maximum = max(maximum, running)
        return maximum, total

    def range_max_payout(self, lower_tick: int, higher_tick: int) -> int:
        return max(
            self._payout_at_raw_price(price)
            for price in self._candidate_prices(lower_tick, higher_tick)
        )

    def complement_max_payout(self, lower_tick: int, higher_tick: int) -> int:
        candidates = self._candidate_prices(0, self.pos_inf_tick)
        lower_raw = lower_tick * self.tick_size
        higher_raw = higher_tick * self.tick_size
        outside = [price for price in candidates if price <= lower_raw or price > higher_raw]
        return max((self._payout_at_raw_price(price) for price in outside), default=0)

    def settled_payout_liability(self, settlement_price: int) -> int:
        return self._payout_at_raw_price(settlement_price)

    def walk_linear(self, up_price: Callable[[int], int], float_scaling: int) -> int:
        starts = 0
        ends = 0
        for tick, (start, end) in sorted(self.boundaries.items()):
            price = up_price(tick * self.tick_size)
            starts += price * start // float_scaling
            ends += price * end // float_scaling
        return max(0, self.base + starts - ends)

    def _apply_range(
        self,
        lower_tick: int,
        higher_tick: int,
        quantity: int,
        add: bool,
    ) -> None:
        self._assert_range(lower_tick, higher_tick)
        if quantity < 0:
            raise ValueError("negative payout quantity")
        if quantity == 0:
            return
        if lower_tick == 0:
            self.base = self._delta(self.base, quantity, add)
        else:
            self._apply_boundary(lower_tick, quantity, 0, add)
        if higher_tick != self.pos_inf_tick:
            self._apply_boundary(higher_tick, 0, quantity, add)

    def _apply_boundary(self, tick: int, start: int, end: int, add: bool) -> None:
        current_start, current_end = self.boundaries.get(tick, [0, 0])
        next_start = self._delta(current_start, start, add)
        next_end = self._delta(current_end, end, add)
        if next_start == 0 and next_end == 0:
            self.boundaries.pop(tick, None)
        else:
            self.boundaries[tick] = [next_start, next_end]

    @staticmethod
    def _delta(value: int, amount: int, add: bool) -> int:
        if add:
            return value + amount
        if amount > value:
            raise ValueError("insufficient payout quantity")
        return value - amount

    def _ordered_boundaries(self) -> list[tuple[int, int]]:
        return [tuple(self.boundaries[tick]) for tick in sorted(self.boundaries)]

    def _payout_at_raw_price(self, settlement_price: int) -> int:
        if settlement_price <= 0:
            raise ValueError("settlement price must be positive")
        prefix_limit_tick = (settlement_price + self.tick_size - 1) // self.tick_size
        running = self.base
        for tick, (start, end) in sorted(self.boundaries.items()):
            if tick >= prefix_limit_tick:
                break
            running += start
            running -= end
        return running

    def _candidate_prices(self, lower_tick: int, higher_tick: int) -> list[int]:
        lower_raw = lower_tick * self.tick_size
        finite_higher = higher_tick != self.pos_inf_tick
        higher_raw = higher_tick * self.tick_size if finite_higher else None
        prices = [max(1, lower_raw + 1)]
        if lower_tick == 0:
            prices.append(1)
        for tick in sorted(self.boundaries):
            raw = tick * self.tick_size
            if raw > lower_raw and (higher_raw is None or raw <= higher_raw):
                prices.append(raw)
            if raw >= lower_raw and (higher_raw is None or raw < higher_raw):
                prices.append(raw + 1)
        if higher_raw is not None:
            prices.append(max(1, higher_raw))
        elif self.boundaries:
            prices.append(max(self.boundaries) * self.tick_size + 1)
        return sorted(set(prices))

    def _assert_range(self, lower_tick: int, higher_tick: int) -> None:
        if lower_tick < 0 or higher_tick > self.pos_inf_tick or lower_tick >= higher_tick:
            raise ValueError("invalid payout range")
        if lower_tick == 0 and higher_tick == self.pos_inf_tick:
            raise ValueError("invalid payout range")
