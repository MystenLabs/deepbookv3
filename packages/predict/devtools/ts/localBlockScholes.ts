// Local signer wrapper around the provider-neutral Block Scholes wire codec.

import { bcs } from "@mysten/sui/bcs";
import { secp256k1 } from "@noble/curves/secp256k1.js";
import { keccak_256 } from "@noble/hashes/sha3.js";

import {
  type BsSviUpdate,
  type BsValueUpdate,
  sviBatchPayloadBytes,
  valueBatchPayloadBytes,
} from "./blockScholesWire.js";
import { bytesToHex, hexToBytes } from "./localPyth.js";

export interface LocalBsSignerConfig {
  bsSignerPrivateKey: string;
  bsSignerPublicKey: string;
}

interface SignParams {
  signerPrivateKey: string;
  verifierPackageId: string;
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
  return signMessage(
    params,
    valueBatchPayloadBytes(params.batchTimestampMs, params.updates),
  );
}

export function signedSviBatchBytes(
  params: SignParams & { updates: BsSviUpdate[] },
): Uint8Array {
  return signMessage(
    params,
    sviBatchPayloadBytes(params.batchTimestampMs, params.updates),
  );
}

function signMessage(params: SignParams, payload: Uint8Array): Uint8Array {
  const signedBytes = concatBytes(
    bcs.Address.serialize(params.verifierPackageId).toBytes(),
    payload,
  );
  const recovered = secp256k1.sign(
    keccak_256(signedBytes),
    hexToBytes(params.signerPrivateKey),
    { prehash: false, format: "recovered" },
  );
  return concatBytes(recovered.slice(1), recovered.slice(0, 1), payload);
}

function concatBytes(...parts: Uint8Array[]): Uint8Array {
  const output = new Uint8Array(
    parts.reduce((length, part) => length + part.length, 0),
  );
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}
