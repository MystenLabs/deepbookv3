export const U64_MAX = (1n << 64n) - 1n;

// Expand exponential notation to a plain decimal string, exactly (string math).
// JS Number.toString() emits exponentials below 1e-6 and at/above 1e21, which
// the plain-decimal regex in toRaw would otherwise reject with a misleading
// "invalid" error even when the value is exactly representable.
function expandExponential(s: string): string {
	const m = /^(\d+)(?:\.(\d+))?[eE]([+-]?\d+)$/.exec(s);
	if (!m) return s;
	const [, whole, frac = "", expStr] = m;
	const digits = whole + frac;
	const point = whole.length + Number(expStr);
	if (point <= 0) return "0." + "0".repeat(-point) + digits;
	if (point >= digits.length) return digits + "0".repeat(point - digits.length);
	return digits.slice(0, point) + "." + digits.slice(point);
}

/** Exact decimal→raw conversion via string math. Throws on negatives and excess precision. */
export function toRaw(value: number | string, decimals: number): bigint {
	const s = expandExponential(typeof value === "number" ? value.toString() : value.trim());
	if (!/^\d+(\.\d+)?$/.test(s)) throw new Error(`invalid or negative decimal value: ${s}`);
	const [whole, frac = ""] = s.split(".");
	if (frac.length > decimals) throw new Error(`${s} exceeds ${decimals} decimals`);
	return BigInt(whole) * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, "0") || "0");
}

/**
 * Raw→decimal for DISPLAY. Casts through Number, so values above 2^53 raw lose
 * precision in the low digits — fine for UI, not for accounting. Exact values
 * stay available as bigints from the primitives layer (`accountBalance`,
 * `poolStats`, …).
 */
export function fromRaw(raw: bigint, decimals: number): number {
	return Number(raw) / 10 ** decimals;
}

export const usdcToRaw = (v: number | string) => toRaw(v, 6);
export const rawToUsdc = (raw: bigint) => fromRaw(raw, 6);
export const priceToRaw = (v: number | string) => toRaw(v, 9);
export const rawToPrice = (raw: bigint) => fromRaw(raw, 9);
export function probabilityToRaw(p: number): bigint {
	if (p < 0 || p > 1) throw new Error(`probability must be in [0,1], got ${p}`);
	return toRaw(p, 9);
}
export const rawToProbability = (raw: bigint) => fromRaw(raw, 9);
export function leverageToRaw(l: number): bigint {
	if (l < 1) throw new Error(`leverage must be >= 1, got ${l}`);
	return toRaw(l, 9);
}
