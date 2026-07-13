import { expect, test } from "vitest";

import { POS_INF_TICK, binaryRangeTicks } from "../src/ticks.js";
import { priceToRaw } from "../src/units.js";

const TICK_SIZE = 10_000_000n;

test("POS_INF_TICK sentinel", () => {
	expect(POS_INF_TICK).toBe((1n << 30n) - 1n);
});

test("UP order encodes (strike, +inf)", () => {
	expect(binaryRangeTicks(priceToRaw(105_000), "up", TICK_SIZE)).toEqual({
		lowerTick: 10_500_000n,
		higherTick: POS_INF_TICK,
	});
});

test("DOWN order encodes (-inf, strike)", () => {
	expect(binaryRangeTicks(priceToRaw(105_000), "down", TICK_SIZE)).toEqual({
		lowerTick: 0n,
		higherTick: 10_500_000n,
	});
});

test("misaligned strike throws", () => {
	expect(() => binaryRangeTicks(priceToRaw(105_000) + 1n, "up", TICK_SIZE)).toThrow(
		/tick multiple/,
	);
});

test("out-of-domain tick throws", () => {
	// tick 0 (neg-inf sentinel)
	expect(() => binaryRangeTicks(0n, "up", TICK_SIZE)).toThrow(/finite tick domain/);
	// tick >= POS_INF_TICK
	expect(() => binaryRangeTicks(POS_INF_TICK * TICK_SIZE, "up", TICK_SIZE)).toThrow(
		/finite tick domain/,
	);
});
