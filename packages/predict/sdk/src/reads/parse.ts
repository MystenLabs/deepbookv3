// BCS decoders for the return values of on-chain reads. Hand-written (not via the
// `bcs` codec) so the read layer carries no runtime coupling to a schema per read —
// these shapes (u64 LE, vector<ID>, Option) are stable Move ABI. Ported from the
// harness's devInspect parsers (`packages/predict/harness/ts/runtime.ts:394-415`).
// Round-tripped against `@mysten/sui/bcs` in tests/reads.test.ts.

// Read a ULEB128-encoded length prefix, returning [value, nextOffset].
function readUleb(bytes: Uint8Array, offset: number): [number, number] {
	let value = 0;
	let shift = 0;
	let i = offset;
	for (;;) {
		const b = bytes[i++] ?? 0;
		value |= (b & 0x7f) << shift;
		if ((b & 0x80) === 0) break;
		shift += 7;
	}
	return [value, i];
}

// 32 raw bytes → a 0x-prefixed, lowercase, full-length object/address id.
function toId(bytes: Uint8Array): string {
	let hex = "";
	for (const b of bytes) hex += b.toString(16).padStart(2, "0");
	return `0x${hex}`;
}

// BCS u64: 8 little-endian bytes → bigint.
export function parseU64LE(bytes: Uint8Array): bigint {
	let v = 0n;
	for (let i = 7; i >= 0; i--) v = (v << 8n) | BigInt(bytes[i] ?? 0);
	return v;
}

// BCS vector<ID> / vector<address>: ULEB128 length, then N × 32-byte addresses.
export function parseVectorOfIds(bytes: Uint8Array): string[] {
	const [len, start] = readUleb(bytes, 0);
	const ids: string[] = [];
	let i = start;
	for (let k = 0; k < len; k++) {
		ids.push(toId(bytes.subarray(i, i + 32)));
		i += 32;
	}
	return ids;
}

// BCS Option<u64>: 1 tag byte (0 = None, 1 = Some), then the u64 LE if Some.
export function parseOptionalU64(bytes: Uint8Array): bigint | null {
	if ((bytes[0] ?? 0) === 0) return null;
	return parseU64LE(bytes.subarray(1));
}

// BCS Option<ID>: 1 tag byte (0 = None, 1 = Some), then a 32-byte id if Some.
export function parseOptionalId(bytes: Uint8Array): string | null {
	if ((bytes[0] ?? 0) === 0) return null;
	return toId(bytes.subarray(1, 33));
}
