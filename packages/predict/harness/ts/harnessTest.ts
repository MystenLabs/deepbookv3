import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { nextDeployableExpiry } from "./cadenceSchedule.js";
import {
  HubSource,
  blockScholesForwardSubscription,
  blockScholesSpotSubscription,
  blockScholesSubscribeRequest,
  providerPublicKeyFromRegistryObject,
  serializableSnapshot,
  subscriptionItemMatches,
} from "./marketSource.js";
import { gridExpiries } from "./runnerConfig.js";
import { createCapacityStrategy } from "./strategies/capacity.js";
import { abortInfo } from "./trace.js";

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

test("capacity tree declares the semantic VM wall rather than a framework tag", () => {
  const strategy = createCapacityStrategy("tree");
  assert.deepEqual(strategy.expect?.terminal, ["cached objects limit"]);
  assert.equal(strategy.gasBudget, 50_000_000_000);
});

test("actor grid configuration is explicit and strictly parsed", () => {
  assert.deepEqual(
    gridExpiries("60000:2,300000:1", 120_000),
    [180_000, 240_000, 300_000],
  );
  assert.throws(() => gridExpiries("60000"), /invalid GRID_SPEC entry/);
  assert.throws(() => gridExpiries("0:3"), /invalid GRID_SPEC entry/);
});

test("hub snapshots require the current complete schema without provider credentials", async () => {
  const directory = mkdtempSync(path.join(tmpdir(), "predict-hub-"));
  const snapshotPath = path.join(directory, "snapshot.json");
  const expiry = 1_800_000_000_000;
  const encoded = serializableSnapshot({
    spot1e9: 10n,
    publishedAtMs: 20n,
    bsSpot1e9: 30n,
    bsSpotTsMs: 40,
    expiries: new Map([[
      expiry,
      {
        forward: 50,
        forward1e9: 60n,
        forwardTsMs: 70,
        svi: { alpha: 0.1, beta: 0.2, rho: -0.3, m: 0.4, sigma: 0.5 },
        svi1e9: {
          a: 1n,
          aNegative: false,
          b: 2n,
          sigma: 3n,
          rho: 4n,
          rhoNegative: true,
          m: 5n,
          mNegative: false,
        },
        sviTsMs: 80,
      },
    ]]),
  });
  const source = new HubSource(snapshotPath);
  await source.start([expiry]);
  try {
    writeFileSync(snapshotPath, JSON.stringify(encoded));
    assert.equal(source.latest()?.expiries.get(expiry)?.forward1e9, 60n);

    delete encoded.schemaVersion;
    writeFileSync(snapshotPath, JSON.stringify(encoded));
    assert.equal(source.latest(), null);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("provider registry parsing observes signer rotation and pause", () => {
  const encodedKey = (prefix: number, fill: number) =>
    Buffer.concat([Buffer.from([prefix]), Buffer.alloc(32, fill)]).toString("base64");
  const registry = (signerPublicKey: string, paused = false) => ({
    json: { fields: { paused, signer_pubkey: signerPublicKey } },
  });

  const first = providerPublicKeyFromRegistryObject(
    registry(encodedKey(2, 1)),
  );
  const rotated = providerPublicKeyFromRegistryObject(
    registry(encodedKey(3, 2)),
  );

  assert.notDeepEqual(first, rotated);
  assert.throws(
    () => providerPublicKeyFromRegistryObject(registry(encodedKey(2, 1), true)),
    /registry is paused/,
  );
});

test("Block Scholes subscriptions keep expected SIDs local and send complete descriptors", () => {
  const spot = blockScholesSpotSubscription();
  const forward = blockScholesForwardSubscription(1_785_250_800_000);
  assert.deepEqual(forward, {
    expectedSid: "0x1da97230ccd81eb5cfc2c4253f9088d83c71309dca38a68973814b7e8e253de0",
    request: {
      feed: "mark.px",
      asset: "future",
      exchange: "composite",
      base_asset: "BTC",
      quote_asset: "USD",
      expiry: "2026-07-28T15:00:00Z",
    },
  });
  const frame = JSON.parse(JSON.stringify(
    blockScholesSubscribeRequest(7, "forwards", [spot.request, forward.request]),
  ));
  assert.deepEqual(frame.params[0].batch, [spot.request, forward.request]);
  assert.equal("sid" in frame.params[0].batch[0], false);
  assert.equal("sid" in frame.params[0].batch[1], false);
  assert.equal(frame.params[0].batch[0].quote_asset, "USD");
  assert.equal(frame.params[0].batch[1].quote_asset, "USD");
  assert.deepEqual(frame.params[0].options.signature, {
    type: "SUI",
    pkg_ver: 1,
    signature_schema: "ecdsa",
    domain: { network: "testnet" },
  });
  const acknowledged = { sid: forward.expectedSid, ...forward.request };
  assert.equal(subscriptionItemMatches(forward.request, acknowledged), true);
  assert.equal(
    subscriptionItemMatches(forward.request, { ...acknowledged, exchange: "deribit" }),
    false,
  );
  const { exchange: _exchange, ...missingExchange } = acknowledged;
  assert.equal(subscriptionItemMatches(forward.request, missingExchange), false);
});
