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
  landedSnapshotFrom,
  serializableLandedSnapshot,
  type LandedMarketSnapshot,
  serializableSnapshot,
  subscriptionItemMatches,
} from "./marketSource.js";
import { rollDownSvi } from "./pricer.js";
import {
  type KeeperChain,
  type LaneMarket,
  settleAndFlush,
  settleExpired,
  settleFailed,
  settleThenFlush,
} from "./keeperLanes.js";
import {
  enqueuedOrder,
  heldAfterSell,
  orderQuantity,
  recordOutcome,
  settlementComplete,
  settlementMadeProgress,
} from "./queueEvents.js";
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
    bsSpotHistory: [{ value1e9: 20n, sourceTimestampMs: 100 }],
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
  assert.equal(landed.spot1e9, 0n);
  assert.equal(landed.bsSpot1e9, 0n);
  assert.equal(landed.bsSpotSourceTimestampMs, 0);
  assert.equal(landed.expiries.get(expiry)?.forward1e9, 0n);
  assert.equal(landed.expiries.get(expiry)?.forwardSourceTimestampMs, 0);
  assert.equal(landed.expiries.get(expiry)?.svi1e9.a, 0n);
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

test("confirmed spot history stays bounded across no-ops and snapshot restarts", () => {
  let landed: LandedMarketSnapshot | null = null;
  const noAdvances = {
    pythSourceTimestampMs: null,
    bsSpotSourceTimestampMs: null,
    forwardSourceTimestampMsByExpiry: new Map<number, number>(),
    sviSourceTimestampMsByExpiry: new Map<number, number>(),
  };
  for (let timestamp = 1; timestamp <= 24; timestamp++) {
    const candidate = {
      spot1e9: 0n, pythSourceTimestampMs: 0n,
      bsSpot1e9: BigInt(timestamp), bsSpotSourceTimestampMs: timestamp,
      expiries: new Map(),
    };
    landed = projectLandedSnapshot(landed, candidate, {
      ...noAdvances, bsSpotSourceTimestampMs: timestamp,
    });
    const expected = Array.from({ length: Math.min(timestamp, 10) }, (_, i) => {
      const sourceTimestampMs = Math.max(1, timestamp - 9) + i;
      return { sourceTimestampMs, value1e9: BigInt(sourceTimestampMs) };
    });
    assert.deepEqual(landed.bsSpotHistory, expected);
    const persisted = JSON.parse(JSON.stringify(serializableLandedSnapshot(landed)));
    assert.deepEqual(landedSnapshotFrom(persisted, []), landed);
    for (const sourceTimestampMs of [0, timestamp - 1, timestamp, timestamp + 100]) {
      const noOp = projectLandedSnapshot(landed, {
        ...candidate, bsSpot1e9: 999n, bsSpotSourceTimestampMs: sourceTimestampMs,
      }, noAdvances);
      assert.deepEqual(noOp, landed);
    }
    landed = landedSnapshotFrom(persisted, []);
  }
  const encoded = serializableLandedSnapshot(landed!);
  assert.throws(() => landedSnapshotFrom(serializableSnapshot(landed!), []), /schema mismatch/);
  assert.throws(() => landedSnapshotFrom({ ...encoded, schemaVersion: 2 }, []), /schemaVersion/);
  assert.throws(() => landedSnapshotFrom({ ...encoded, bsSpotHistory: [] }, []), /match latest/);
  assert.throws(() => landedSnapshotFrom({ ...encoded, bsSpotHistory: Array(11).fill({}) }, []), /history/);
  assert.throws(() => landedSnapshotFrom({ ...encoded, bsSpotHistory: [
    { value1e9: "24", sourceTimestampMs: 24 },
    { value1e9: "24", sourceTimestampMs: 24 },
  ] }, []), /invalid landed spot read/);
});

test("strategy pricing mirror enforces source freshness and stale-Pyth fallback", () => {
  const now = 100_000;
  const expiry = 200_000;
  const snap: Snap = {
    schemaVersion: 3,
    bsSpotHistory: [{ value1e9: "100000000000", sourceTimestampMs: now - 1 }],
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
  snap.bsSpotHistory[0].sourceTimestampMs = now - 10_001;
  snap.expiries[String(expiry)].forwardSourceTimestampMs = now - 10_001;
  assert.equal(pricingEnvFromSnapshot(snap, expiry, now), null);
  snap.bsSpotSourceTimestampMs = now - 1;
  snap.bsSpotHistory[0].sourceTimestampMs = now - 1;
  snap.expiries[String(expiry)].forwardSourceTimestampMs = now - 10_001;
  assert.equal(pricingEnvFromSnapshot(snap, expiry, now), null);
  snap.expiries[String(expiry)].forwardSourceTimestampMs = now - 1;
  snap.expiries[String(expiry)].sviSourceTimestampMs = now - 60_001;
  assert.equal(pricingEnvFromSnapshot(snap, expiry, now), null);
});

test("strategy pricing uses the retained matching spot instead of the latest spot", () => {
  const now = 100_000;
  const expiry = 200_000;
  const snap = {
    schemaVersion: 3,
    spot1e9: "110000000000",
    pythSourceTimestampMs: "99999",
    bsSpot1e9: "200000000000",
    bsSpotSourceTimestampMs: 99_999,
    bsSpotHistory: [
      { value1e9: "100000000000", sourceTimestampMs: 99_998 },
      { value1e9: "200000000000", sourceTimestampMs: 99_999 },
    ],
    expiries: {
      [String(expiry)]: {
        forward: 105,
        forwardSourceTimestampMs: 99_998,
        sviSourceTimestampMs: 99_998,
        svi: { alpha: 0.1, beta: 0.2, rho: -0.3, m: 0.4, sigma: 0.5 },
      },
    },
  };
  assert.equal(pricingEnvFromSnapshot(snap, expiry, now)?.bsSpot, 100);
  snap.bsSpotHistory.shift();
  assert.equal(pricingEnvFromSnapshot(snap, expiry, now), null);
  snap.expiries[String(expiry)].forwardSourceTimestampMs = 99_999;
  assert.equal(pricingEnvFromSnapshot(snap, expiry, now)?.bsSpot, 200);
  snap.schemaVersion = 2;
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

const PKG = "0x1234";
const queueEvent = (name: string, parsedJson: any) => ({
  type: `${PKG}::order_events::${name}`,
  parsedJson,
});

test("an enqueue receipt yields the record, its τ, and its channel", () => {
  const order = enqueuedOrder([
    { type: `${PKG}::account::Withdrawn`, parsedJson: {} },
    queueEvent("OrderEnqueued", {
      record_id: "7",
      timing: { placed_at_ms: "1000", earliest_price_ms: "2000", tau_ms: "2000", deadline_ms: "7000", cutoff_ms: "50000", pyth_channel: 3 },
    }),
  ]);
  assert.deepEqual(order, { recordId: 7n, tauMs: 2000n, channel: 3 });
  assert.throws(() => enqueuedOrder([]), /no OrderEnqueued/);
});

test("a filled position's quantity decodes from the packed order id", () => {
  // order.move packs (lots << 100) | (lower_tick << 70) | (higher_tick << 40) | sequence,
  // with 10_000 quantity units per lot.
  const orderId = (25n << 100n) | (123n << 70n) | (456n << 40n) | 9n;
  assert.equal(orderQuantity(orderId), 250_000n);
  assert.equal(orderQuantity(0n), 0n);
});

test("a commit+resolve receipt reports each record's fill, refund, or wait", () => {
  const remaining = (3n << 100n) | (1n << 70n) | (2n << 40n);
  const events = [
    queueEvent("CohortCommitted", { tau_ms: "2000" }),
    queueEvent("QueuedOrderFilled", {
      record_id: "4", quantity: "20000", amount: "11000000",
      position: { order_id: remaining.toString(), root_id: "1", opened_at_ms: "2000" },
    }),
    queueEvent("QueuedOrderFilled", {
      record_id: "5", quantity: "10000", amount: "3000000",
      position: { order_id: "0", root_id: "0", opened_at_ms: "0" },
    }),
    queueEvent("QueuedOrderRefunded", { record_id: "6", reason: 8, position_returned: true }),
  ];
  assert.deepEqual(recordOutcome(events, 4n), {
    status: "filled", quantity: 20_000n, amount: 11_000_000n, remainingQuantity: 30_000n,
  });
  assert.deepEqual(recordOutcome(events, 5n), {
    status: "filled", quantity: 10_000n, amount: 3_000_000n, remainingQuantity: 0n,
  });
  assert.deepEqual(recordOutcome(events, 6n), { status: "refunded", reason: 8, positionReturned: true });
  assert.deepEqual(recordOutcome(events, 9n), { status: "waiting" });
});

test("settlement phases stop on completion or on a call that made no progress", () => {
  assert.equal(settlementComplete({ settled: false, payoutCursor: 0n, nextId: 0n }), false);
  assert.equal(settlementComplete({ settled: true, payoutCursor: 3n, nextId: 5n }), false);
  assert.equal(settlementComplete({ settled: true, payoutCursor: 5n, nextId: 5n }), true);
  // A market that never had a queue reads (0, 0) once settled.
  assert.equal(settlementComplete({ settled: true, payoutCursor: 0n, nextId: 0n }), true);

  assert.equal(settlementMadeProgress([queueEvent("QueuedOrderRefunded", {})]), true);
  assert.equal(settlementMadeProgress([{ type: `${PKG}::config_events::MarketSettled`, parsedJson: {} }]), true);
  assert.equal(settlementMadeProgress([queueEvent("OpenRecordSettled", {})]), true);
  assert.equal(settlementMadeProgress([queueEvent("MarketPayoutsCompleted", {})]), true);
  // Only the Propbook observation insert: try_settle returned without moving.
  assert.equal(
    settlementMadeProgress([{ type: `${PKG}::oracle_lane::ObservationInserted<${PKG}::x::Y>`, parsedJson: {} }]),
    false,
  );
  assert.equal(settlementMadeProgress(undefined), false);
});

test("a refunded sell keeps the position tracked in the reopened sell record", () => {
  // Record 4 holds 30_000. Enqueueing a sell of 10_000 closes record 4 and moves the whole
  // position into sell record 9; the refund reopens record 9 with it.
  const held = { recordId: 4n, marketId: "0xm", quantity: 30_000n };
  const afterRefund = heldAfterSell(held, 9n, { status: "refunded", reason: 8, positionReturned: true });
  assert.deepEqual(afterRefund, { recordId: 9n, marketId: "0xm", quantity: 30_000n });
  // The retry sells from record 9, not the closed record 4, and a partial fill leaves the
  // remainder in the retry's own record 12.
  const afterRetry = heldAfterSell(afterRefund!, 12n, {
    status: "filled", quantity: 10_000n, amount: 4_000_000n, remainingQuantity: 20_000n,
  });
  assert.deepEqual(afterRetry, { recordId: 12n, marketId: "0xm", quantity: 20_000n });
  // A full close leaves nothing; a sell still waiting holds the position in its record.
  assert.equal(
    heldAfterSell(afterRetry!, 15n, { status: "filled", quantity: 20_000n, amount: 1n, remainingQuantity: 0n }),
    null,
  );
  assert.deepEqual(heldAfterSell(afterRetry!, 15n, { status: "waiting" }), {
    recordId: 15n, marketId: "0xm", quantity: 20_000n,
  });
});

// A model of the chain the keeper lanes drive. Each market has `waiting` queued orders and
// `nextId` records; try_settle refunds waiting orders, then settles, then moves the payout
// cursor `payoutBatch` records per call, as `expiry_market::try_settle` does. A settle PTB
// with `sweep` and the flush snapshot both deactivate a settled market, as
// rebalance_expiry_cash and plp::snapshot_expiry_pricer do, and the snapshot aborts on an
// expired unsettled market. A PTB that fails changes nothing.
interface ModelMarket {
  id: string;
  expiryMs: number;
  active: boolean;
  settled: boolean;
  waiting: number;
  nextId: number;
  cursor: number;
}

class ModelChain implements KeeperChain {
  now = 0;
  payoutBatch = 1;
  flushes: string[][] = [];
  violations: string[] = [];
  failSettle: ((market: ModelMarket) => boolean) | null = null;
  failAfterSnapshot = false;
  // Advances the clock between the pre-flush settlement pass and the snapshot.
  clockAtSnapshot: number | null = null;
  readonly markets = new Map<string, ModelMarket>();

  add(id: string, expiryMs: number, waiting: number, openRecords: number): void {
    this.markets.set(id, {
      id, expiryMs, active: true, settled: false, waiting, nextId: waiting + openRecords, cursor: 0,
    });
  }

  // No settled market with unpaid records may leave the active set: nothing rediscovers it.
  private check(): void {
    for (const m of this.markets.values()) {
      if (m.settled && m.cursor < m.nextId && !m.active) this.violations.push(m.id);
    }
  }

  async clockMs() { return this.now; }

  async activeMarkets(): Promise<LaneMarket[]> {
    return [...this.markets.values()].filter((m) => m.active).map((m) => ({ id: m.id, expiryMs: m.expiryMs }));
  }

  async settlementProgress(marketId: string) {
    const m = this.markets.get(marketId)!;
    return { settled: m.settled, payoutCursor: BigInt(m.cursor), nextId: BigInt(m.nextId) };
  }

  async settlePhase(market: LaneMarket, sweep: boolean) {
    const m = this.markets.get(market.id)!;
    if (this.failSettle?.(m)) throw new Error(`settle PTB aborted for ${m.id}`);
    const events: { type: string; parsedJson: object }[] = [];
    const emit = (name: string) => events.push({ type: `0x1::order_events::${name}`, parsedJson: {} });
    if (!m.settled) {
      if (this.now < m.expiryMs) return events;
      if (m.waiting > 0) {
        m.waiting -= 1;
        emit("QueuedOrderRefunded");
      } else {
        m.settled = true;
        events.push({ type: "0x1::config_events::MarketSettled", parsedJson: {} });
      }
    } else if (m.cursor < m.nextId) {
      m.cursor = Math.min(m.nextId, m.cursor + this.payoutBatch);
      emit("OpenRecordSettled");
      if (m.cursor === m.nextId) emit("MarketPayoutsCompleted");
    }
    if (sweep && m.settled) m.active = false;
    this.check();
    return events;
  }

  async flush(marketIds: string[]) {
    if (this.clockAtSnapshot !== null) this.now = this.clockAtSnapshot;
    const members = marketIds.map((id) => this.markets.get(id)!).filter((m) => m.active);
    const expiredUnsettled = members.find((m) => !m.settled && this.now >= m.expiryMs);
    if (expiredUnsettled) throw new Error(`EExpiredMarketNotSettled ${expiredUnsettled.id}`);
    for (const m of members) if (m.settled) m.active = false;
    this.check();
    this.flushes.push(marketIds);
    if (this.failAfterSnapshot) throw new Error("finish_flush leg failed after the snapshot");
    return { events: [] };
  }

  unpaid(): string[] {
    return [...this.markets.values()].filter((m) => m.settled && m.cursor < m.nextId).map((m) => m.id);
  }
}

test("a flush failure after the snapshot never strands a settled market's unpaid records", async () => {
  const chain = new ModelChain();
  chain.add("a", 1_000, 1, 2);
  chain.add("b", 5_000, 1, 3);
  chain.add("c", 60_000, 0, 2);

  // Tick 1: the settlement lane finishes and sweeps `a`. `b` then expires before the flush
  // lane (a boundary-race straggler): the lane settles and pays it before the snapshot, so the
  // snapshot meets no settled market with unpaid records, and the leg failing after the
  // snapshot loses nothing.
  chain.now = 2_000;
  const settled = await settleExpired(chain);
  assert.deepEqual(settled.map((r) => [r.market.id, settleFailed(r)]), [["a", false]]);
  chain.now = 6_000;
  chain.failAfterSnapshot = true;
  const lane = await settleThenFlush(chain);
  assert.deepEqual(lane.preFlush.map((r) => [r.market.id, settleFailed(r)]), [["b", false]]);
  assert.match(String(lane.error), /after the snapshot/);
  assert.deepEqual(chain.flushes, [["c"]]);
  assert.deepEqual(chain.unpaid(), []);
  assert.deepEqual(chain.violations, []);

  // A market that expires after the pre-flush pass makes the snapshot abort instead: it stays
  // active and unsettled, and the next tick (a fresh keeper, as after a restart) settles it.
  chain.failAfterSnapshot = false;
  chain.clockAtSnapshot = 61_000;
  const raced = await settleAndFlush(chain);
  assert.equal(raced.settled.length, 0);
  assert.equal(raced.flush, null);
  const deferred = await settleThenFlush(chain);
  assert.match(String(deferred.error), /EExpiredMarketNotSettled c/);
  assert.equal(chain.markets.get("c")!.active, true);
  chain.clockAtSnapshot = null;
  const next = await settleAndFlush(chain);
  assert.deepEqual(next.settled.map((r) => [r.market.id, settleFailed(r)]), [["c", false]]);
  assert.equal(next.flush?.error, undefined);
  assert.deepEqual(chain.unpaid(), []);
  assert.deepEqual(chain.violations, []);
});

test("a payout failure keeps the market active and holds the flush until a later tick pays it", async () => {
  const chain = new ModelChain();
  chain.add("a", 1_000, 0, 3);
  chain.add("b", 60_000, 0, 1);
  chain.now = 2_000;
  // The second payout batch aborts once.
  let failures = 1;
  chain.failSettle = (m) => m.id === "a" && m.settled && m.cursor === 1 && failures-- > 0;

  const failed = await settleAndFlush(chain);
  assert.deepEqual(failed.settled.map((r) => [r.market.id, settleFailed(r)]), [["a", true]]);
  assert.equal(failed.flush, null);
  assert.deepEqual(chain.flushes, []);
  const a = chain.markets.get("a")!;
  assert.deepEqual([a.settled, a.cursor, a.active], [true, 1, true]);
  assert.deepEqual(chain.violations, []);

  // The next tick rebuilds its work list from the active set, which still holds `a`.
  const resumed = await settleAndFlush(chain);
  assert.deepEqual(resumed.settled.map((r) => [r.market.id, settleFailed(r)]), [["a", false]]);
  assert.deepEqual([a.cursor, a.active], [3, false]);
  assert.deepEqual(chain.flushes, [["b"]]);

  // A payout failure in the pre-flush pass skips the flush the same way.
  chain.add("c", 70_000, 0, 2);
  chain.now = 75_000;
  failures = 1;
  chain.failSettle = (m) => m.id === "c" && m.settled && m.cursor === 1 && failures-- > 0;
  const lane = await settleThenFlush(chain);
  assert.equal(lane.skipped, true);
  assert.deepEqual(chain.flushes, [["b"]]);
  assert.equal(chain.markets.get("c")!.active, true);
  assert.deepEqual(chain.violations, []);
  await settleAndFlush(chain);
  assert.deepEqual(chain.unpaid(), []);
  assert.deepEqual(chain.violations, []);
});
