import assert from "node:assert/strict";
import test from "node:test";

import { secp256k1 } from "@noble/curves/secp256k1.js";

import { netGasCharge, selectGasPaymentRefs } from "./grpcGas.js";
import { transactionClockTimestampMs } from "./grpcClock.js";
import {
  providerBatchFromJson,
  providerBatchMessageBytes,
  sviBatchPayloadBytes,
  valueBatchPayloadBytes,
  verifyProviderBatchSignature,
} from "./blockScholesWire.js";
import { signedValueBatchBytes } from "./localBlockScholes.js";
import { bytesToHex, hexToBytes } from "./localPyth.js";

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
