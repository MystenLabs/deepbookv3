import { expect, test } from "vitest";

import {
	U64_MAX,
	leverageToRaw,
	priceToRaw,
	probabilityToRaw,
	rawToUsdc,
	toRaw,
	usdcToRaw,
} from "../src/units.js";

test("toRaw exact decimal string math (no float)", () => {
	expect(toRaw("12.5", 6)).toBe(12_500_000n);
	expect(toRaw(0.1, 6)).toBe(100_000n);
	expect(toRaw("105000", 9)).toBe(105_000_000_000_000n);
	expect(() => toRaw("1.1234567", 6)).toThrow(/decimals/);
	expect(() => toRaw("-1", 6)).toThrow(/negative/);
});
test("exponential-notation number inputs convert exactly", () => {
	// Number.toString() goes exponential below 1e-6 and at/above 1e21; these are
	// exactly representable and must not be rejected as "invalid".
	expect(probabilityToRaw(1e-7)).toBe(100n);
	expect(priceToRaw(1e-9)).toBe(1n);
	expect(toRaw(2.5e-7, 9)).toBe(250n);
	expect(toRaw(1e21, 6)).toBe(1_000_000_000_000_000_000_000_000_000n);
	// Still exact: sub-representable magnitudes throw rather than round.
	expect(() => toRaw(1e-10, 9)).toThrow(/decimals/);
});

test("wrappers", () => {
	expect(usdcToRaw(100)).toBe(100_000_000n);
	expect(rawToUsdc(12_500_000n)).toBe(12.5);
	expect(priceToRaw(105_000)).toBe(105_000_000_000_000n);
	expect(probabilityToRaw(0.3)).toBe(300_000_000n);
	expect(() => probabilityToRaw(1.5)).toThrow(/probability/);
	expect(leverageToRaw(2)).toBe(2_000_000_000n);
	expect(() => leverageToRaw(0.5)).toThrow(/leverage/);
	expect(U64_MAX).toBe(18446744073709551615n);
});
