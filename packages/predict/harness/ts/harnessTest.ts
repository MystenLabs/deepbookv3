import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { nextDeployableExpiry } from "./cadenceSchedule.js";
import {
  HubSource,
  appliedOracleSourcesFromEvents,
  blockScholesForwardSubscription,
  blockScholesSpotSubscription,
  blockScholesSubscribeRequest,
  providerPublicKeyFromRegistryObject,
  projectLandedSnapshot,
  serializableSnapshot,
  subscriptionItemMatches,
} from "./marketSource.js";
import { rollDownSvi } from "./pricer.js";
import { gridExpiries } from "./runnerConfig.js";
import { pricingEnvFromSnapshot, type Snap } from "./strategyPricing.js";
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

test("SVI roll-down uses the observation source timestamp as its anchor", () => {
  assert.deepEqual(
    rollDownSvi(
      { a: 0.2, b: 0.4, rho: -0.3, m: 0.1, sigma: 0.5 },
      100,
      200,
      150,
    ),
    { a: 0.1, b: 0.2, rho: -0.3, m: 0.1, sigma: 0.5 },
  );
});

test("landed snapshot advances each source independently and ignores retransmit roll-downs", () => {
  const expiry = 200_000;
  const fixed = (a: bigint) => ({
    a, aNegative: false, b: 2n, sigma: 3n, rho: 4n,
    rhoNegative: true, m: 5n, mNegative: false,
  });
  const previous = {
    spot1e9: 10n,
    pythSourceTimestampMs: 90n,
    bsSpot1e9: 20n,
    bsSpotSourceTimestampMs: 100,
    expiries: new Map([[expiry, {
      forward: 30,
      forward1e9: 30n,
      forwardSourceTimestampMs: 70,
      svi: { alpha: 0.1, beta: 0.2, rho: -0.3, m: 0.4, sigma: 0.5 },
      svi1e9: fixed(1n),
      sviSourceTimestampMs: 80,
    }]]),
  };
  const candidate = {
    spot1e9: 11n,
    pythSourceTimestampMs: 101n,
    bsSpot1e9: 21n,
    bsSpotSourceTimestampMs: 100,
    expiries: new Map([[expiry, {
      forward: 31,
      forward1e9: 31n,
      forwardSourceTimestampMs: 95,
      svi: { alpha: 0.09, beta: 0.18, rho: -0.3, m: 0.4, sigma: 0.5 },
      svi1e9: fixed(9n),
      sviSourceTimestampMs: 80,
    }]]),
  };
  const landed = projectLandedSnapshot(previous, candidate, {
    pythSourceTimestampMs: 99n,
    bsSpotSourceTimestampMs: null,
    forwardSourceTimestampMsByExpiry: new Map([[expiry, 95]]),
    sviSourceTimestampMsByExpiry: new Map(),
  });
  assert.equal(landed.spot1e9, 11n);
  assert.equal(landed.pythSourceTimestampMs, 99n);
  assert.equal(landed.bsSpot1e9, 20n);
  assert.equal(landed.expiries.get(expiry)?.forward1e9, 31n);
  assert.equal(landed.expiries.get(expiry)?.svi1e9.a, 1n);

  const future = projectLandedSnapshot(landed, {
    ...candidate,
    bsSpot1e9: 22n,
    bsSpotSourceTimestampMs: 101,
  }, {
    pythSourceTimestampMs: null,
    bsSpotSourceTimestampMs: null,
    forwardSourceTimestampMsByExpiry: new Map(),
    sviSourceTimestampMsByExpiry: new Map(),
  });
  assert.equal(future.bsSpot1e9, 20n);
  assert.equal(future.bsSpotSourceTimestampMs, 100);
});

test("landed snapshot does not infer an on-chain advance after local state is lost", () => {
  const expiry = 200_000;
  const candidate = {
    spot1e9: 11n,
    pythSourceTimestampMs: 101n,
    bsSpot1e9: 21n,
    bsSpotSourceTimestampMs: 100,
    expiries: new Map([[expiry, {
      forward: 31,
      forward1e9: 31n,
      forwardSourceTimestampMs: 95,
      svi: { alpha: 0.09, beta: 0.18, rho: -0.3, m: 0.4, sigma: 0.5 },
      svi1e9: {
        a: 9n, aNegative: false, b: 2n, sigma: 3n, rho: 4n,
        rhoNegative: true, m: 5n, mNegative: false,
      },
      sviSourceTimestampMs: 80,
    }]]),
  };

  // A successful transaction can still be a complete on-chain no-op when another relayer
  // already stored equal/newer source times. With no local snapshot, timestamps alone cannot
  // prove which candidate values landed.
  const landed = projectLandedSnapshot(null, candidate, {
    pythSourceTimestampMs: null,
    bsSpotSourceTimestampMs: null,
    forwardSourceTimestampMsByExpiry: new Map(),
    sviSourceTimestampMsByExpiry: new Map(),
  });
  assert.equal(landed.bsSpotSourceTimestampMs, 0);
  assert.equal(landed.expiries.get(expiry)?.forwardSourceTimestampMs, 0);
  assert.equal(landed.expiries.get(expiry)?.sviSourceTimestampMs, 0);
});

test("oracle receipt events identify exactly which source lanes advanced", () => {
  const expiry = 200_000;
  const applied = appliedOracleSourcesFromEvents([
    {
      type: "0x1::oracle_lane::ObservationRecorded<0x1::oracle_lane::OracleRead<0x1::pyth_feed::RawSpot>>",
      parsedJson: { observation: { source_timestamp_ms: "101" } },
    },
    {
      type: "0x1::block_scholes_store::BlockScholesObservationRecorded<0x1::block_scholes_store::BsRead<u128>>",
      parsedJson: {
        series_kind: 1,
        expiry_ms: String(expiry),
        observation: { source_timestamp_ms: "95" },
      },
    },
  ]);

  assert.equal(applied.pythSourceTimestampMs, 101n);
  assert.equal(applied.bsSpotSourceTimestampMs, null);
  assert.equal(applied.forwardSourceTimestampMsByExpiry.get(expiry), 95);
  assert.equal(applied.sviSourceTimestampMsByExpiry.size, 0);
});

test("strategy pricing mirror enforces source freshness and stale-Pyth fallback", () => {
  const now = 100_000;
  const expiry = 200_000;
  const snap: Snap = {
    spot1e9: "110000000000",
    pythSourceTimestampMs: String(now - 1),
    bsSpot1e9: "100000000000",
    bsSpotSourceTimestampMs: now - 1,
    expiries: {
      [String(expiry)]: {
        forward: 105,
        forwardSourceTimestampMs: now - 1,
        sviSourceTimestampMs: now - 1,
        svi: { alpha: 0.1, beta: 0.2, rho: -0.3, m: 0.4, sigma: 0.5 },
      },
    },
  };
  assert.equal(pricingEnvFromSnapshot(snap, expiry, now)?.pythSpot, 110);

  snap.pythSourceTimestampMs = String(now - 10_001);
  const fallback = pricingEnvFromSnapshot(snap, expiry, now);
  assert.equal(fallback?.pythSpot, 100);
  assert.equal(fallback?.bsSpot, 100);

  snap.bsSpotSourceTimestampMs = now - 10_001;
  assert.equal(pricingEnvFromSnapshot(snap, expiry, now), null);
  snap.bsSpotSourceTimestampMs = now - 1;
  snap.expiries[String(expiry)].forwardSourceTimestampMs = now - 10_001;
  assert.equal(pricingEnvFromSnapshot(snap, expiry, now), null);
  snap.expiries[String(expiry)].forwardSourceTimestampMs = now - 1;
  snap.expiries[String(expiry)].sviSourceTimestampMs = now - 60_001;
  assert.equal(pricingEnvFromSnapshot(snap, expiry, now), null);
});

test("hub snapshots require the current complete schema without provider credentials", async () => {
  const directory = mkdtempSync(path.join(tmpdir(), "predict-hub-"));
  const snapshotPath = path.join(directory, "snapshot.json");
  const expiry = 1_800_000_000_000;
  const encoded = serializableSnapshot({
    spot1e9: 10n,
    pythSourceTimestampMs: 20n,
    bsSpot1e9: 30n,
    bsSpotSourceTimestampMs: 40,
    expiries: new Map([[
      expiry,
      {
        forward: 50,
        forward1e9: 60n,
        forwardSourceTimestampMs: 70,
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
        sviSourceTimestampMs: 80,
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
    signature_schema: "ecdsa",
    domain: { network: "testnet", pkg_ver: 1 },
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
