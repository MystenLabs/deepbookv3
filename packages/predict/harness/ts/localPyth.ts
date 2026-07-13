import { secp256k1 } from "@noble/curves/secp256k1.js";
import { keccak_256 } from "@noble/hashes/sha3.js";
import {
  bytesToHex as nobleBytesToHex,
  hexToBytes as nobleHexToBytes,
} from "@noble/hashes/utils.js";

const GOVERNANCE_CONTRACT = "0xa36234ef3749a2c94136b6345bceff450791ef1ebc99e918f16f8075a441bb24";
const GOVERNANCE_CHAIN = 1;
const RECEIVER_CHAIN_SUI = 21;
const TRUSTED_SIGNER_TTL_SECONDS = 365 * 24 * 60 * 60;
const VAA_VERSION = 1;
const GUARDIAN_SET_INDEX = 0;
const GOVERNANCE_NONCE = 1;
const GOVERNANCE_CONSISTENCY_LEVEL = 1;
const PYTH_GOVERNANCE_MODULE = 3;
const UPDATE_TRUSTED_SIGNER_ACTION = 1;
const LAZER_UPDATE_MAGIC = 1_296_547_300;
const LAZER_PAYLOAD_MAGIC = 2_479_346_549;
const LAZER_CHANNEL_REAL_TIME = 1;
const LAZER_PRICE_PROPERTY = 0;
const LAZER_EXPONENT_PROPERTY = 4;
const LAZER_EXACT_1E9_EXPONENT = -9;

export interface LocalPythConfig {
  governanceChain: number;
  governanceContract: string;
  receiverChain: number;
  guardianPrivateKey: string;
  guardianAddress?: string;
  signerPrivateKey: string;
  signerPublicKey: string;
  signerExpiresAtSeconds: string;
}

export interface UpdateTrustedSignerVaaParams {
  guardianPrivateKey: Uint8Array;
  governanceChain: number;
  governanceContract: Uint8Array;
  receiverChain: number;
  signerPublicKey: Uint8Array;
  signerExpiresAtSeconds: bigint;
  timestampSeconds: number;
  sequence: bigint;
}

export interface LazerUpdateParams {
  signerPrivateKey: Uint8Array;
  feedId: number;
  spot1e9: bigint;
  sourceTimestampMs: bigint;
}

export function createLocalPythConfig(nowSeconds = Math.floor(Date.now() / 1000)): LocalPythConfig {
  const guardianPrivateKey = secp256k1.utils.randomSecretKey();
  const signerPrivateKey = secp256k1.utils.randomSecretKey();
  const signerExpiresAtSeconds = BigInt(nowSeconds + TRUSTED_SIGNER_TTL_SECONDS);

  return {
    governanceChain: GOVERNANCE_CHAIN,
    governanceContract: GOVERNANCE_CONTRACT,
    receiverChain: RECEIVER_CHAIN_SUI,
    guardianPrivateKey: bytesToHex(guardianPrivateKey),
    guardianAddress: bytesToHex(guardianAddressFromPrivateKey(guardianPrivateKey)),
    signerPrivateKey: bytesToHex(signerPrivateKey),
    signerPublicKey: bytesToHex(compressedPublicKeyFromPrivateKey(signerPrivateKey)),
    signerExpiresAtSeconds: signerExpiresAtSeconds.toString(),
  };
}

export function buildUpdateTrustedSignerVaaBytes(params: UpdateTrustedSignerVaaParams): Uint8Array {
  assertLength(params.governanceContract, 32, "governanceContract");
  assertLength(params.signerPublicKey, 33, "signerPublicKey");

  const payload = concatBytes(
    new TextEncoder().encode("PTGM"),
    u8(PYTH_GOVERNANCE_MODULE),
    u8(UPDATE_TRUSTED_SIGNER_ACTION),
    u16be(params.receiverChain),
    params.signerPublicKey,
    u64be(params.signerExpiresAtSeconds),
  );

  return buildVaa({
    guardianPrivateKey: params.guardianPrivateKey,
    guardianSetIndex: GUARDIAN_SET_INDEX,
    timestampSeconds: params.timestampSeconds,
    nonce: GOVERNANCE_NONCE,
    emitterChain: params.governanceChain,
    emitterAddress: params.governanceContract,
    sequence: params.sequence,
    consistencyLevel: GOVERNANCE_CONSISTENCY_LEVEL,
    payload,
  });
}

export function buildLazerUpdateBytes(params: LazerUpdateParams): Uint8Array {
  const sourceTimestampUs = params.sourceTimestampMs * 1_000n;
  const payload = concatBytes(
    u32le(LAZER_PAYLOAD_MAGIC),
    u64le(sourceTimestampUs),
    u8(LAZER_CHANNEL_REAL_TIME),
    u8(1),
    u32le(params.feedId),
    u8(2),
    u8(LAZER_PRICE_PROPERTY),
    u64le(params.spot1e9),
    u8(LAZER_EXPONENT_PROPERTY),
    u16le(twosComplementI16(LAZER_EXACT_1E9_EXPONENT)),
  );

  return concatBytes(
    u32le(LAZER_UPDATE_MAGIC),
    signRecoverableRsv(params.signerPrivateKey, keccak_256(payload)),
    u16le(payload.length),
    payload,
  );
}

export function updateTrustedSignerVaaFromConfig(config: LocalPythConfig): Uint8Array {
  return buildUpdateTrustedSignerVaaBytes({
    guardianPrivateKey: hexToBytes(config.guardianPrivateKey),
    governanceChain: config.governanceChain,
    governanceContract: hexToBytes(config.governanceContract),
    receiverChain: config.receiverChain,
    signerPublicKey: hexToBytes(config.signerPublicKey),
    signerExpiresAtSeconds: BigInt(config.signerExpiresAtSeconds),
    timestampSeconds: Math.floor(Date.now() / 1000),
    sequence: 1n,
  });
}

export function lazerUpdateFromConfig(
  config: LocalPythConfig,
  feedId: number,
  spot1e9: bigint,
  sourceTimestampMs: bigint,
): Uint8Array {
  return buildLazerUpdateBytes({
    signerPrivateKey: hexToBytes(config.signerPrivateKey),
    feedId,
    spot1e9,
    sourceTimestampMs,
  });
}

export function compressedPublicKeyFromPrivateKey(privateKey: Uint8Array): Uint8Array {
  return secp256k1.getPublicKey(privateKey, true);
}

export function guardianAddressFromPrivateKey(privateKey: Uint8Array): Uint8Array {
  const uncompressed = secp256k1.getPublicKey(privateKey, false);
  return keccak_256(uncompressed.slice(1)).slice(-20);
}

export function hexToBytes(value: string): Uint8Array {
  return nobleHexToBytes(value.startsWith("0x") ? value.slice(2) : value);
}

export function bytesToHex(value: Uint8Array): string {
  return `0x${nobleBytesToHex(value)}`;
}

function buildVaa(params: {
  guardianPrivateKey: Uint8Array;
  guardianSetIndex: number;
  timestampSeconds: number;
  nonce: number;
  emitterChain: number;
  emitterAddress: Uint8Array;
  sequence: bigint;
  consistencyLevel: number;
  payload: Uint8Array;
}): Uint8Array {
  assertLength(params.emitterAddress, 32, "emitterAddress");
  const body = concatBytes(
    u32be(params.timestampSeconds),
    u32be(params.nonce),
    u16be(params.emitterChain),
    params.emitterAddress,
    u64be(params.sequence),
    u8(params.consistencyLevel),
    params.payload,
  );
  const digest = keccak_256(keccak_256(body));
  const signature = signRecoverableRsv(params.guardianPrivateKey, digest);

  return concatBytes(
    u8(VAA_VERSION),
    u32be(params.guardianSetIndex),
    u8(1),
    u8(0),
    signature,
    body,
  );
}

function signRecoverableRsv(privateKey: Uint8Array, digest: Uint8Array): Uint8Array {
  const recovered = secp256k1.sign(digest, privateKey, {
    prehash: false,
    format: "recovered",
  });
  return concatBytes(recovered.slice(1), recovered.slice(0, 1));
}

function assertLength(value: Uint8Array, expected: number, name: string) {
  if (value.length !== expected) {
    throw new Error(`${name} must be ${expected} bytes, got ${value.length}`);
  }
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

function u8(value: number): Uint8Array {
  return Uint8Array.of(value);
}

function u16le(value: number): Uint8Array {
  assertRange(value, 0xffff, "u16");
  return Uint8Array.of(value & 0xff, (value >> 8) & 0xff);
}

function u16be(value: number): Uint8Array {
  assertRange(value, 0xffff, "u16");
  return Uint8Array.of((value >> 8) & 0xff, value & 0xff);
}

function u32le(value: number): Uint8Array {
  assertRange(value, 0xffffffff, "u32");
  return Uint8Array.of(
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  );
}

function u32be(value: number): Uint8Array {
  assertRange(value, 0xffffffff, "u32");
  return Uint8Array.of(
    (value >> 24) & 0xff,
    (value >> 16) & 0xff,
    (value >> 8) & 0xff,
    value & 0xff,
  );
}

function u64le(value: bigint): Uint8Array {
  assertBigIntRange(value, (1n << 64n) - 1n, "u64");
  const out = new Uint8Array(8);
  let current = value;
  for (let i = 0; i < out.length; i++) {
    out[i] = Number(current & 0xffn);
    current >>= 8n;
  }
  return out;
}

function u64be(value: bigint): Uint8Array {
  assertBigIntRange(value, (1n << 64n) - 1n, "u64");
  const out = new Uint8Array(8);
  let current = value;
  for (let i = out.length - 1; i >= 0; i--) {
    out[i] = Number(current & 0xffn);
    current >>= 8n;
  }
  return out;
}

function twosComplementI16(value: number): number {
  if (value < -0x8000 || value > 0x7fff) {
    throw new Error(`i16 out of range: ${value}`);
  }
  return value & 0xffff;
}

function assertRange(value: number, max: number, name: string) {
  if (!Number.isInteger(value) || value < 0 || value > max) {
    throw new Error(`${name} out of range: ${value}`);
  }
}

function assertBigIntRange(value: bigint, max: bigint, name: string) {
  if (value < 0n || value > max) {
    throw new Error(`${name} out of range: ${value}`);
  }
}
