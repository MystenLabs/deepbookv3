import assert from "node:assert/strict";
import test from "node:test";

import { secp256k1 } from "@noble/curves/secp256k1.js";
import { ObjectError } from "@mysten/sui/client";

import { forwardSid, spotSid, sviSid } from "./blockScholesSid.js";
import { netGasCharge, selectGasPaymentRefs } from "./grpcGas.js";
import { transactionClockTimestampMs } from "./grpcClock.js";
import { objectLookupExists } from "./grpcObjects.js";
import {
  providerBatchFromJson,
  providerBatchMessageBytes,
  sviBatchPayloadBytes,
  valueBatchPayloadBytes,
  verifyProviderBatchSignature,
} from "./blockScholesWire.js";
import { signedValueBatchBytes } from "./localBlockScholes.js";
import {
  LAZER_CHANNEL_FIXED_RATE_200MS,
  buildLazerUpdateBytes,
  bytesToHex,
  hexToBytes,
} from "./localPyth.js";

const ORACLE_PACKAGE_ID = `0x${"11".repeat(32)}`;
const EXPIRY_MS = 1_785_250_800_000n;

function sidHex(value: bigint): string {
  return `0x${value.toString(16).padStart(64, "0")}`;
}

test("derives the provider's pinned spot, forward, and SVI vectors", () => {
  // The upstream `bs_sid::sid::index_px` implementation at the Move.toml-pinned revision,
  // using its vector scope and default `blockscholes` exchange.
  assert.equal(
    sidHex(spotSid(ORACLE_PACKAGE_ID, "HYPE")),
    "0x215ab77d29adef1066cb6a229a7e74e083bee79b5aff973a36d2ba2aa8f560f3",
  );
  assert.equal(
    sidHex(forwardSid(ORACLE_PACKAGE_ID, "HYPE", EXPIRY_MS)),
    "0x767852094662e0763fdfb8cc02f08969892b2d083159df16cb91ccb6505e3cd6",
  );
  assert.equal(
    sidHex(sviSid(ORACLE_PACKAGE_ID, "HYPE", EXPIRY_MS)),
    "0x29f876378481972bf272eddcbb987579ec3a75a634533295c3c8c2cbfe548a6a",
  );
});

test("scopes spot SIDs by oracle package and base asset", () => {
  const btc = spotSid(ORACLE_PACKAGE_ID, "BTC");
  assert.notEqual(btc, spotSid(ORACLE_PACKAGE_ID, "ETH"));
  assert.notEqual(btc, spotSid(`0x${"22".repeat(32)}`, "BTC"));
});

test("provider value wire round-trips and remains verifier-domain-bound", () => {
  const signerPrivateKey = `0x${"1".padStart(64, "0")}`;
  const verifierPackageId = `0x${"ab".repeat(32)}`;
  const updates = [{
    sid: 0x1234n,
    timestampMs: 1_755_000_000_123n,
    value: 6_500_012_345_678n,
  }];
  const batchTimestampMs = 1_755_000_000_999n;
  const payload = valueBatchPayloadBytes(batchTimestampMs, updates);
  assert.equal(
    Buffer.from(payload).toString("hex"),
    "00e7d1269e980100000134120000000000000000000000000000000000000000000000000000000000007bce269e980100004e49ed66e90500000000000000000000",
  );
  const wire = signedValueBatchBytes({
    signerPrivateKey,
    verifierPackageId,
    batchTimestampMs,
    updates,
  });
  const signature = {
    r: bytesToHex(wire.slice(0, 32)),
    s: bytesToHex(wire.slice(32, 64)),
    v: wire[64] + 27,
  };
  const expectedPublicKey = secp256k1.getPublicKey(hexToBytes(signerPrivateKey), true);

  assert.deepEqual(wire.slice(65), payload);
  assert.deepEqual(providerBatchMessageBytes(signature, payload), wire);
  assert.equal(verifyProviderBatchSignature({
    signature,
    payload,
    verifierPackageId,
    expectedPublicKey,
  }), true);
  assert.equal(verifyProviderBatchSignature({
    signature,
    payload,
    verifierPackageId: `0x${"cd".repeat(32)}`,
    expectedPublicKey,
  }), false);
});

test("SVI payload fixture preserves contract field order and sign bits", () => {
  const payload = sviBatchPayloadBytes(1_755_000_000_999n, [{
    sid: 0x1234n,
    timestampMs: 1_755_000_000_123n,
    aMagnitude: 40_000_000n,
    aNegative: false,
    b: 100_000_000n,
    sigma: 200_000_000n,
    rhoMagnitude: 700_000_000n,
    rhoNegative: true,
    mMagnitude: 0n,
    mNegative: false,
  }]);
  assert.equal(
    Buffer.from(payload).toString("hex"),
    "01e7d1269e980100000134120000000000000000000000000000000000000000000000000000000000007bce269e98010000005a62020000000000000000000000000000e1f50500000000000000000000000000c2eb0b0000000000000000000000000027b929000000000000000000000000010000000000000000000000000000000000",
  );
});

test("provider notification parsing preserves integer strings and rejects JSON numbers", () => {
  const batch = providerBatchFromJson({
    batch_kind: 0,
    timestamp: "1755000000999",
    values: [{
      sid: "0x1234",
      t: "1755000000123",
      v: "6500012345678",
    }],
  });
  assert.equal(batch.kind, "value");
  assert.equal(batch.updates[0].sid, 0x1234n);
  assert.equal(batch.updates[0].value, 6_500_012_345_678n);
  assert.throws(
    () => providerBatchFromJson({
      batch_kind: 0,
      timestamp: 1_755_000_000_999,
      values: [],
    }),
    /data.timestamp must be an integer string/,
  );
});

test("gRPC gas payment aggregates paged coins and excludes transaction inputs", () => {
  const coins = [
    { objectId: "used", version: "1", digest: "a", balance: "100" },
    { objectId: "forty-a", version: "2", digest: "b", balance: "40" },
    { objectId: "forty-b", version: "3", digest: "c", balance: "40" },
    { objectId: "ten", version: "4", digest: "d", balance: "10" },
  ];
  assert.deepEqual(
    selectGasPaymentRefs(coins, new Set(["used"]), 50n).map((coin) => coin.objectId),
    ["forty-a", "forty-b"],
  );
  assert.throws(
    () => selectGasPaymentRefs(coins, new Set(["used", "forty-a", "forty-b"]), 20n),
    /eligible SUI gas balance 10 does not cover budget 20/,
  );
});

test("gRPC gas charge tracks storage rebates when rotating a pinned coin", () => {
  assert.equal(
    netGasCharge({
      computationCost: "200",
      storageCost: "50",
      storageRebate: "25",
    }),
    225n,
  );
  assert.equal(
    netGasCharge({
      computationCost: "10",
      storageCost: "5",
      storageRebate: "30",
    }),
    -15n,
  );
});

test("pricing time comes from the exact Clock input rather than the checkpoint", async () => {
  const requestedVersions: bigint[] = [];
  const checkpointTimestampMs = 1_755_000_000_279;
  const timestampMs = await transactionClockTimestampMs(
    {
      unchangedConsensusObjects: [{
        kind: "ReadOnlyRoot",
        objectId: "0x6",
        version: "41",
        digest: "clock-digest",
      }],
    },
    async (version) => {
      requestedVersions.push(version);
      return {
        object: {
          objectId: "0x6",
          version,
          objectType: "0x2::clock::Clock",
          json: {
            kind: {
              oneofKind: "structValue",
              structValue: {
                fields: {
                  timestamp_ms: {
                    kind: {
                      oneofKind: "stringValue",
                      stringValue: "1755000000123",
                    },
                  },
                },
              },
            },
          },
        },
      };
    },
  );

  assert.deepEqual(requestedVersions, [41n]);
  assert.equal(timestampMs, 1_755_000_000_123);
  assert.notEqual(timestampMs, checkpointTimestampMs);
});

test("a queue-commit Lazer update carries the cohort's fixed-rate channel and τ", () => {
  // Pyth Lazer LeEcdsa layout: update magic (u32) | 65-byte signature | payload length (u16) |
  // payload. The payload is magic (u32) | envelope µs (u64) | channel (u8) | feed count (u8) |
  // feed id (u32) | property count (u8) | then (property id, value) pairs, all little-endian.
  const tauMs = 1_785_250_799_800n;
  const update = buildLazerUpdateBytes({
    signerPrivateKey: new Uint8Array(32).fill(7),
    feedId: 1,
    spot1e9: 65_000_000_000_000n,
    sourceTimestampMs: tauMs,
    channel: LAZER_CHANNEL_FIXED_RATE_200MS,
  });
  const view = new DataView(update.buffer, update.byteOffset, update.byteLength);
  const payloadOffset = 4 + 65 + 2;
  assert.equal(view.getUint16(4 + 65, true), update.length - payloadOffset);
  assert.equal(view.getBigUint64(payloadOffset + 4, true), 1_785_250_799_800_000n);
  assert.equal(update[payloadOffset + 12], 3);
  // Feed: id 1 with price, exponent, and feed-update-time properties.
  assert.equal(view.getUint32(payloadOffset + 14, true), 1);
  assert.equal(update[payloadOffset + 18], 3);
  assert.equal(view.getBigUint64(payloadOffset + 20, true), 65_000_000_000_000n);
  // Property 12 (feed update time) is an Option<u64>: some, then τ in µs, so the price's
  // generation time meets the order's earliest price time (τ).
  const updateTimeOffset = payloadOffset + 20 + 8 + 1 + 2;
  assert.equal(update[updateTimeOffset], 12);
  assert.equal(update[updateTimeOffset + 1], 1);
  assert.equal(view.getBigUint64(updateTimeOffset + 2, true), 1_785_250_799_800_000n);

  const realTime = buildLazerUpdateBytes({
    signerPrivateKey: new Uint8Array(32).fill(7),
    feedId: 1,
    spot1e9: 65_000_000_000_000n,
    sourceTimestampMs: tauMs,
  });
  assert.equal(realTime[payloadOffset + 12], 1);
});

test("an object lookup exists only for a live object, not for an error naming its ID", () => {
  const id = `0x${"ab".repeat(32)}`;
  // A missing object comes back as an ObjectError that still carries the requested ID.
  const missing = new ObjectError("notExists", "object not found", { reason: "notFound", objectId: id });
  assert.equal(objectLookupExists(missing), false);
  assert.equal(objectLookupExists(new ObjectError("deleted", "deleted", { reason: "deleted", objectId: id })), false);
  assert.equal(objectLookupExists({ objectId: id, version: "3", digest: "d" }), true);
  assert.equal(objectLookupExists(undefined), false);
  // Any other lookup failure is not an answer either way.
  assert.throws(
    () => objectLookupExists(new ObjectError("INTERNAL", "boom", { reason: "unknown", objectId: id })),
    /boom/,
  );
});
