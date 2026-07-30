// Local Block Scholes signer: the sim-side counterpart of `bs_oracle::verify`.
//
// The real verifier is published unmodified on localnet, so the only way to mint
// a batch is a genuinely valid signature. The sim therefore plays Block Scholes:
// run.sh generates a per-instance secp256k1 key, registers it via
// `registry::set_signer` (the sim publishes the package, so it holds the
// `AdminCap`), and every refresh signs a real BCS batch here — the same
// local-trusted-signer model as `localPyth.ts`.
//
// Wire format (verify.move): message = 65-byte recoverable signature (r||s||v)
// || BCS payload `(batch_kind: u8, timestamp: u64, updates)`. The signature
// covers the verifier package's own 32-byte address prepended to the payload
// (domain separator), hashed with keccak256.

import { bcs } from "@mysten/sui/bcs";
import { secp256k1 } from "@noble/curves/secp256k1.js";
import { keccak_256 } from "@noble/hashes/sha3.js";

import { bytesToHex, hexToBytes } from "./localPyth.js";

const BATCH_VALUE = 0;
const BATCH_SVI = 1;

const ValueUpdate = bcs.struct("ValueUpdate", {
    sid: bcs.u256(),
    timestamp: bcs.u64(),
    v: bcs.u128(),
});

const SviUpdate = bcs.struct("SviUpdate", {
    sid: bcs.u256(),
    timestamp: bcs.u64(),
    sviAMagnitude: bcs.u128(),
    sviAIsNegative: bcs.bool(),
    sviB: bcs.u128(),
    sviSigma: bcs.u128(),
    sviRhoMagnitude: bcs.u128(),
    sviRhoIsNegative: bcs.bool(),
    sviMMagnitude: bcs.u128(),
    sviMIsNegative: bcs.bool(),
});

export interface LocalBsSignerConfig {
    bsSignerPrivateKey: string;
    bsSignerPublicKey: string;
}

export interface BsValueUpdate {
    sid: bigint;
    /** Model "as of" time — pinned across retransmits of unchanged data. */
    timestampMs: bigint;
    /** 1e9-scaled value (the scale the sid's decimals field declares). */
    value: bigint;
}

export interface BsSviUpdate {
    sid: bigint;
    timestampMs: bigint;
    aMagnitude: bigint;
    aNegative: boolean;
    b: bigint;
    sigma: bigint;
    rhoMagnitude: bigint;
    rhoNegative: boolean;
    mMagnitude: bigint;
    mNegative: boolean;
}

export interface BsWireSignature {
    r: string;
    s: string;
    v: string | number;
}

interface SignParams {
    /** Local signer key registered on the localnet `SignerRegistry`. */
    signerPrivateKey: string;
    /** Locally published `bs_oracle` package id — the signature domain separator. */
    verifierPackageId: string;
    /** Envelope publish time — advances on every flush. */
    batchTimestampMs: bigint;
}

export function createLocalBsSignerConfig(): LocalBsSignerConfig {
    const privateKey = secp256k1.utils.randomSecretKey();
    return {
        bsSignerPrivateKey: bytesToHex(privateKey),
        bsSignerPublicKey: bytesToHex(secp256k1.getPublicKey(privateKey, true)),
    };
}

export function signedValueBatchBytes(
    params: SignParams & { updates: BsValueUpdate[] },
): Uint8Array {
    const payload = valueBatchPayloadBytes(params.batchTimestampMs, params.updates);
    return signMessage(params, payload);
}

export function signedSviBatchBytes(params: SignParams & { updates: BsSviUpdate[] }): Uint8Array {
    const payload = sviBatchPayloadBytes(params.batchTimestampMs, params.updates);
    return signMessage(params, payload);
}

export function valueBatchPayloadBytes(
    batchTimestampMs: bigint,
    updates: BsValueUpdate[],
): Uint8Array {
    const payload = concatBytes(
        envelopeBytes(BATCH_VALUE, batchTimestampMs),
        bcs
            .vector(ValueUpdate)
            .serialize(
                updates.map((u) => ({
                    sid: u.sid,
                    timestamp: u.timestampMs,
                    v: u.value,
                })),
            )
            .toBytes(),
    );
    return payload;
}

export function sviBatchPayloadBytes(
    batchTimestampMs: bigint,
    updates: BsSviUpdate[],
): Uint8Array {
    const payload = concatBytes(
        envelopeBytes(BATCH_SVI, batchTimestampMs),
        bcs
            .vector(SviUpdate)
            .serialize(
                updates.map((u) => ({
                    sid: u.sid,
                    timestamp: u.timestampMs,
                    sviAMagnitude: u.aMagnitude,
                    sviAIsNegative: u.aNegative,
                    sviB: u.b,
                    sviSigma: u.sigma,
                    sviRhoMagnitude: u.rhoMagnitude,
                    sviRhoIsNegative: u.rhoNegative,
                    sviMMagnitude: u.mMagnitude,
                    sviMIsNegative: u.mNegative,
                })),
            )
            .toBytes(),
    );
    return payload;
}

/// Rebuild the exact `r || s || recovery_id || BCS payload` byte vector the
/// testnet verifier accepts. Block Scholes returns the EVM recovery byte
/// (27/28); Sui's `ecdsa_k1` wire uses 0/1.
export function providerBatchMessageBytes(
    signature: BsWireSignature,
    payload: Uint8Array,
): Uint8Array {
    const { compact, recoveryId } = parseWireSignature(signature);
    return concatBytes(compact, Uint8Array.of(recoveryId), payload);
}

/// Validate one provider batch exactly as `bs_oracle::verify` does: hash the
/// verifier package address plus the reconstructed BCS payload, recover the
/// secp256k1 public key, and compare it with the live SignerRegistry key.
export function verifyProviderBatchSignature(params: {
    signature: BsWireSignature;
    payload: Uint8Array;
    verifierPackageId: string;
    expectedPublicKey: Uint8Array;
}): boolean {
    const { compact, recoveryId } = parseWireSignature(params.signature);
    const signedBytes = concatBytes(
        bcs.Address.serialize(params.verifierPackageId).toBytes(),
        params.payload,
    );
    const digest = keccak_256(signedBytes);
    const recovered = secp256k1.Signature
        .fromBytes(compact, "compact")
        .addRecoveryBit(recoveryId)
        .recoverPublicKey(digest)
        .toBytes(true);
    return bytesEqual(recovered, params.expectedPublicKey);
}

function envelopeBytes(batchKind: number, timestampMs: bigint): Uint8Array {
    return concatBytes(
        bcs.u8().serialize(batchKind).toBytes(),
        bcs.u64().serialize(timestampMs).toBytes(),
    );
}

function signMessage(params: SignParams, payload: Uint8Array): Uint8Array {
    // The verifier prepends its own runtime address before hashing, so the sim
    // signs over the locally published package id.
    const signedBytes = concatBytes(
        bcs.Address.serialize(params.verifierPackageId).toBytes(),
        payload,
    );
    const digest = keccak_256(signedBytes);
    // noble's "recovered" layout is v||r||s; Sui's ecrecover wants r||s||v.
    const recovered = secp256k1.sign(digest, hexToBytes(params.signerPrivateKey), {
        prehash: false,
        format: "recovered",
    });
    return concatBytes(recovered.slice(1), recovered.slice(0, 1), payload);
}

function parseWireSignature(signature: BsWireSignature): {
    compact: Uint8Array;
    recoveryId: number;
} {
    const r = hexToBytes(signature.r);
    const s = hexToBytes(signature.s);
    if (r.length !== 32 || s.length !== 32) {
        throw new Error(`Block Scholes signature must contain 32-byte r/s values`);
    }
    const rawV = typeof signature.v === "number"
        ? signature.v
        : Number(BigInt(signature.v));
    const recoveryId = rawV >= 27 ? rawV - 27 : rawV;
    if (recoveryId !== 0 && recoveryId !== 1) {
        throw new Error(`unsupported Block Scholes recovery id ${rawV}`);
    }
    return { compact: concatBytes(r, s), recoveryId };
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
    if (a.length !== b.length) return false;
    let difference = 0;
    for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
    return difference === 0;
}

function concatBytes(...parts: Uint8Array[]): Uint8Array {
    const length = parts.reduce((sum, part) => sum + part.length, 0);
    const out = new Uint8Array(length);
    let offset = 0;
    for (const part of parts) {
        out.set(part, offset);
        offset += part.length;
    }
    return out;
}
