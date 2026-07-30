import { bcs } from "@mysten/sui/bcs";
import { secp256k1 } from "@noble/curves/secp256k1.js";
import { keccak_256 } from "@noble/hashes/sha3.js";

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

export interface BsValueUpdate {
  sid: bigint;
  timestampMs: bigint;
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

export type ProviderBatch =
  | {
      kind: "value";
      batchTimestampMs: bigint;
      updates: BsValueUpdate[];
      payload: Uint8Array;
    }
  | {
      kind: "svi";
      batchTimestampMs: bigint;
      updates: BsSviUpdate[];
      payload: Uint8Array;
    };

export function providerBatchFromJson(data: unknown): ProviderBatch {
  const batch = objectValue(data, "data");
  const values = batch.values;
  if (!Array.isArray(values)) {
    throw new Error("Block Scholes data.values must be an array");
  }
  const batchTimestampMs = decimalInteger(batch.timestamp, "data.timestamp");
  if (batch.batch_kind === BATCH_VALUE) {
    const updates = values.map((raw, index): BsValueUpdate => {
      const value = objectValue(raw, `data.values[${index}]`);
      return {
        sid: decimalInteger(value.sid, `data.values[${index}].sid`),
        timestampMs: decimalInteger(value.t, `data.values[${index}].t`),
        value: decimalInteger(value.v, `data.values[${index}].v`),
      };
    });
    return {
      kind: "value",
      batchTimestampMs,
      updates,
      payload: valueBatchPayloadBytes(batchTimestampMs, updates),
    };
  }
  if (batch.batch_kind === BATCH_SVI) {
    const updates = values.map((raw, index): BsSviUpdate => {
      const value = objectValue(raw, `data.values[${index}]`);
      const field = (name: string) => `data.values[${index}].${name}`;
      return {
        sid: decimalInteger(value.sid, field("sid")),
        timestampMs: decimalInteger(value.t, field("t")),
        aMagnitude: decimalInteger(value.svi_a_magnitude, field("svi_a_magnitude")),
        aNegative: booleanValue(value.svi_a_is_negative, field("svi_a_is_negative")),
        b: decimalInteger(value.svi_b, field("svi_b")),
        sigma: decimalInteger(value.svi_sigma, field("svi_sigma")),
        rhoMagnitude: decimalInteger(
          value.svi_rho_magnitude,
          field("svi_rho_magnitude"),
        ),
        rhoNegative: booleanValue(
          value.svi_rho_is_negative,
          field("svi_rho_is_negative"),
        ),
        mMagnitude: decimalInteger(
          value.svi_m_magnitude,
          field("svi_m_magnitude"),
        ),
        mNegative: booleanValue(
          value.svi_m_is_negative,
          field("svi_m_is_negative"),
        ),
      };
    });
    return {
      kind: "svi",
      batchTimestampMs,
      updates,
      payload: sviBatchPayloadBytes(batchTimestampMs, updates),
    };
  }
  throw new Error(`unsupported Block Scholes batch kind ${String(batch.batch_kind)}`);
}

export function valueBatchPayloadBytes(
  batchTimestampMs: bigint,
  updates: BsValueUpdate[],
): Uint8Array {
  return concatBytes(
    envelopeBytes(BATCH_VALUE, batchTimestampMs),
    bcs
      .vector(ValueUpdate)
      .serialize(
        updates.map((update) => ({
          sid: update.sid,
          timestamp: update.timestampMs,
          v: update.value,
        })),
      )
      .toBytes(),
  );
}

export function sviBatchPayloadBytes(
  batchTimestampMs: bigint,
  updates: BsSviUpdate[],
): Uint8Array {
  return concatBytes(
    envelopeBytes(BATCH_SVI, batchTimestampMs),
    bcs
      .vector(SviUpdate)
      .serialize(
        updates.map((update) => ({
          sid: update.sid,
          timestamp: update.timestampMs,
          sviAMagnitude: update.aMagnitude,
          sviAIsNegative: update.aNegative,
          sviB: update.b,
          sviSigma: update.sigma,
          sviRhoMagnitude: update.rhoMagnitude,
          sviRhoIsNegative: update.rhoNegative,
          sviMMagnitude: update.mMagnitude,
          sviMIsNegative: update.mNegative,
        })),
      )
      .toBytes(),
  );
}

export function providerBatchMessageBytes(
  signature: BsWireSignature,
  payload: Uint8Array,
): Uint8Array {
  const { compact, recoveryId } = parseWireSignature(signature);
  return concatBytes(compact, Uint8Array.of(recoveryId), payload);
}

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
  const recovered = secp256k1.Signature
    .fromBytes(compact, "compact")
    .addRecoveryBit(recoveryId)
    .recoverPublicKey(keccak_256(signedBytes))
    .toBytes(true);
  return bytesEqual(recovered, params.expectedPublicKey);
}

function envelopeBytes(batchKind: number, timestampMs: bigint): Uint8Array {
  return concatBytes(
    bcs.u8().serialize(batchKind).toBytes(),
    bcs.u64().serialize(timestampMs).toBytes(),
  );
}

function parseWireSignature(signature: BsWireSignature): {
  compact: Uint8Array;
  recoveryId: number;
} {
  const r = hexBytes(signature.r);
  const s = hexBytes(signature.s);
  if (r.length !== 32 || s.length !== 32) {
    throw new Error("Block Scholes signature must contain 32-byte r/s values");
  }
  const rawV =
    typeof signature.v === "number"
      ? signature.v
      : Number(BigInt(signature.v));
  const recoveryId = rawV >= 27 ? rawV - 27 : rawV;
  if (recoveryId !== 0 && recoveryId !== 1) {
    throw new Error(`unsupported Block Scholes recovery id ${rawV}`);
  }
  return { compact: concatBytes(r, s), recoveryId };
}

function objectValue(value: unknown, field: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Block Scholes ${field} must be an object`);
  }
  return value as Record<string, unknown>;
}

function decimalInteger(value: unknown, field: string): bigint {
  if (typeof value !== "string" || !/^(?:0x[0-9a-fA-F]+|[0-9]+)$/.test(value)) {
    throw new Error(`Block Scholes ${field} must be an integer string`);
  }
  return BigInt(value);
}

function booleanValue(value: unknown, field: string): boolean {
  if (typeof value !== "boolean") {
    throw new Error(`Block Scholes ${field} must be a boolean`);
  }
  return value;
}

function hexBytes(value: string): Uint8Array {
  const normalized = value.startsWith("0x") ? value.slice(2) : value;
  if (normalized.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(normalized)) {
    throw new Error("Block Scholes signature contains invalid hex");
  }
  return Uint8Array.from(Buffer.from(normalized, "hex"));
}

function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

function concatBytes(...parts: Uint8Array[]): Uint8Array {
  const length = parts.reduce((sum, part) => sum + part.length, 0);
  const output = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}
