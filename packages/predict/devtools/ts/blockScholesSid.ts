import { bcs } from "@mysten/sui/bcs";
import { fromHex, normalizeSuiAddress } from "@mysten/sui/utils";
import { keccak_256 } from "@noble/hashes/sha3.js";

// These descriptors mirror propbook::block_scholes_sid, which delegates the
// canonical BCS layout and hashing contract to the provider-owned bs_sid package.
const DECIMALS = 9;
const TIMESTAMP_PRECISION = "ms";

// The local Predict development system uses one numeric identity for its Pyth
// feed and Propbook underlying.
export const PREDICT_ORACLE_ID = 1;
// Canonical provider spelling used for store binding and every SID/subscription descriptor.
export const PREDICT_BLOCK_SCHOLES_BASE_ASSET = "BTC";

const encodedString = (value: string): Uint8Array => bcs.string().serialize(value).toBytes();
const encodedU8 = (value: number): Uint8Array => bcs.u8().serialize(value).toBytes();
const encodedU64 = (value: bigint): Uint8Array => bcs.u64().serialize(value).toBytes();
const encodedBool = (value: boolean): Uint8Array => bcs.bool().serialize(value).toBytes();

function concat(...parts: Uint8Array[]): Uint8Array {
    const length = parts.reduce((sum, part) => sum + part.length, 0);
    const result = new Uint8Array(length);
    let offset = 0;
    for (const part of parts) {
        result.set(part, offset);
        offset += part.length;
    }
    return result;
}

function some(value: Uint8Array): Uint8Array {
    return concat(Uint8Array.of(1), value);
}

function none(): Uint8Array {
    return Uint8Array.of(0);
}

function expiryAt(expiryMs: bigint): Uint8Array {
    // bs_sid::Expiry { kind: absolute (0), value: unix milliseconds }.
    return concat(encodedU8(0), encodedU64(expiryMs));
}

function digest(oraclePackageId: string, feed: string, body: Uint8Array): bigint {
    const scope = fromHex(normalizeSuiAddress(oraclePackageId));
    const bytes = keccak_256(concat(scope, encodedString(feed), body));
    let result = 0n;
    for (const byte of bytes) result = (result << 8n) | BigInt(byte);
    return result;
}

export function spotSid(oraclePackageId: string, baseAsset: string): bigint {
    return digest(
        oraclePackageId,
        "index.px",
        concat(
            encodedString("spot"),
            encodedString("blockscholes"),
            encodedString(baseAsset),
            encodedString("USD"),
            none(),
            encodedBool(false),
            none(),
            encodedU8(DECIMALS),
            encodedString(TIMESTAMP_PRECISION),
        ),
    );
}

export function forwardSid(oraclePackageId: string, baseAsset: string, expiryMs: bigint): bigint {
    return digest(
        oraclePackageId,
        "mark.px",
        concat(
            encodedString("future"),
            encodedString("composite"),
            encodedString(baseAsset),
            encodedString("USD"),
            some(expiryAt(expiryMs)),
            none(),
            none(),
            none(),
            none(),
            none(),
            encodedU8(DECIMALS),
            encodedString(TIMESTAMP_PRECISION),
        ),
    );
}

export function sviSid(oraclePackageId: string, baseAsset: string, expiryMs: bigint): bigint {
    return digest(
        oraclePackageId,
        "model.params",
        concat(
            encodedString("option"),
            encodedString("composite"),
            encodedString(baseAsset),
            encodedString("SVI"),
            expiryAt(expiryMs),
            encodedU8(DECIMALS),
            encodedString(TIMESTAMP_PRECISION),
        ),
    );
}
