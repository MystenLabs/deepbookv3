export const U64_MAX = (1n << 64n) - 1n;

/** Exact decimal→raw conversion via string math. Throws on negatives and excess precision. */
export function toRaw(value: number | string, decimals: number): bigint {
	const s = typeof value === "number" ? value.toString() : value.trim();
	if (!/^\d+(\.\d+)?$/.test(s)) throw new Error(`invalid or negative decimal value: ${s}`);
	const [whole, frac = ""] = s.split(".");
	if (frac.length > decimals) throw new Error(`${s} exceeds ${decimals} decimals`);
	return BigInt(whole) * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, "0") || "0");
}

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
