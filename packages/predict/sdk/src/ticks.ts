const TICK_BITS = 30n;

/** +inf sentinel tick: the upper bound of an UP range. */
export const POS_INF_TICK = (1n << TICK_BITS) - 1n;

export type Side = "up" | "down";

// Convert a raw binary-range strike to the `(lower_tick, higher_tick)` pair the
// `mint` entrypoint takes directly (there is no standalone packed range key).
// An UP order is `(strike, +inf)` -> lower_tick = strike/tick_size, higher_tick =
// POS_INF_TICK; a DOWN order is `(-inf, strike)` -> lower_tick = 0 (neg-inf),
// higher_tick = strike/tick_size.
export function binaryRangeTicks(
	strikeRaw: bigint,
	side: Side,
	tickSize: bigint,
): { lowerTick: bigint; higherTick: bigint } {
	const tick = strikeRaw / tickSize;
	if (tick * tickSize !== strikeRaw) {
		throw new Error(`strike ${strikeRaw} is not a whole tick multiple of ${tickSize}`);
	}
	if (tick <= 0n || tick >= POS_INF_TICK) {
		throw new Error(`strike tick ${tick} outside the finite tick domain (1..POS_INF_TICK-1)`);
	}
	const isUp = side === "up";
	return {
		lowerTick: isUp ? tick : 0n,
		higherTick: isUp ? POS_INF_TICK : tick,
	};
}
