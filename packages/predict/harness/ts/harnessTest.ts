import assert from "node:assert/strict";
import test from "node:test";

import { secp256k1 } from "@noble/curves/secp256k1.js";

import { nextDeployableExpiry } from "./cadenceSchedule.js";
import { selectGasPaymentRefs } from "./grpcGas.js";
import {
  providerBatchMessageBytes,
  sviBatchPayloadBytes,
  signedValueBatchBytes,
  valueBatchPayloadBytes,
  verifyProviderBatchSignature,
} from "./localBlockScholes.js";
import { bytesToHex, hexToBytes } from "./localPyth.js";
import { abortInfo } from "./trace.js";

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

test("cadence scheduling treats window size as a time horizon and reserves higher-rank boundaries", () => {
  const minute = 60_000;
  const now = Date.UTC(2026, 6, 30, 1, 22, 30);
  const at = (hour: number, minuteOfHour: number) =>
    Date.UTC(2026, 6, 30, hour, minuteOfHour, 0);
  const live = [
    { expiryMs: at(1, 23) },
    { expiryMs: at(1, 24) },
    { expiryMs: at(1, 25) },
  ];

  // The one-minute cadence has only two owned markets, but its three-period
  // horizon is full because 01:25 belongs to the five-minute cadence.
  assert.equal(nextDeployableExpiry(live, 0, now, [0, 1, 2]), null);
  assert.equal(
    nextDeployableExpiry(live, 0, now + minute, [0, 1, 2]),
    at(1, 26),
  );
});

test("gRPC Move aborts retain module and code classification", () => {
  assert.deepEqual(
    abortInfo(new Error(
      "MoveAbort(MoveLocation { module: ModuleId { address: abc, name: Identifier(\"market_manager\") }, function: 1, instruction: 0, function_name: Some(\"x\") }, abort code: 5, in '0xabc::market_manager::next_deployable_market'",
    )),
    { module: "market_manager", code: 5 },
  );
  assert.equal(abortInfo(new Error("transport unavailable")), null);
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
