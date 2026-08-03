import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { nextDeployableExpiry } from "./cadenceSchedule.js";
import {
  HubSource,
  providerPublicKeyFromRegistryObject,
  serializableSnapshot,
} from "./marketSource.js";
import { budgetLadder, gridExpiries } from "./runnerConfig.js";
import { createCapacityStrategy } from "./strategies/capacity.js";
import { createLiqBudgetStrategy } from "./strategies/liqBudget.js";
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

test("budget ladder parses, orders by time, and rejects malformed rungs", () => {
  assert.deepEqual(budgetLadder(""), []);
  assert.deepEqual(
    budgetLadder("1800:1500,0:24,2700:3000,900:512").map((rung) => [rung.atMs, rung.budget]),
    [
      [0, 24n],
      [900_000, 512n],
      [1_800_000, 1500n],
      [2_700_000, 3000n],
    ],
  );
  // A typo must fail at load, not as a BigInt TypeError an hour into the campaign it configures.
  assert.throws(() => budgetLadder("900:"), /invalid TRADE_LIQ_BUDGET_STAGES entry/);
  assert.throws(() => budgetLadder("abc"), /invalid TRADE_LIQ_BUDGET_STAGES entry/);
});

test("liq-budget probe keeps emitting single mints once the fill target is reached", async () => {
  // The failure this pins made the instrument useless without looking broken: batching all the way
  // to the index cap saturates the book long before a ladder steps, after which nothing is minted
  // and the run collects no single-mint samples at all while still reporting cleanly.
  const strategy = createLiqBudgetStrategy("healthy");
  const submitted: number[] = [];
  const ctx = {
    markets: () => [{ id: "0xm", expiryMs: Date.now() + 8 * 3_600_000 }],
    snapshot: () => ({}),
    rand: (lo: number, hi: number) => (lo + hi) / 2,
    pick: <T,>(items: T[]) => items[0],
    leverageCap: () => 5,
    resolve: () => ({
      feasible: true, lowerTick: 1, higherTick: 2, strikeUsd: 100, predictedProbability: 0.5,
      quantity: 1n, leverage1e9: 1_100_000_000n, maxProbability1e9: 1n, maxCost: 1n,
    }),
    trace: () => {},
    submitMintBatch: async (_market: unknown, legs: unknown[]) => {
      submitted.push(legs.length);
      return { events: [] };
    },
  } as unknown as Parameters<typeof strategy.tick>[0];

  for (let i = 0; i < 400; i++) await strategy.tick(ctx);

  const singles = submitted.filter((n) => n === 1).length;
  const minted = submitted.reduce((total, n) => total + n, 0);
  assert.ok(minted >= 2_000, `expected the fill to pass FILL_TARGET, minted ${minted}`);
  assert.ok(singles > 100, `expected sustained single-mint probes, got ${singles}`);
  // And the run is only reported complete once it has something to report.
  assert.equal(strategy.failure?.(), null);
});

test("liq-budget declares the computation cap only on the arm expected to reach it", () => {
  assert.equal(createLiqBudgetStrategy("healthy").expect, undefined);
  assert.deepEqual(createLiqBudgetStrategy("adverse").expect?.terminal, ["InsufficientGas"]);
  assert.equal(createLiqBudgetStrategy("healthy").gasBudget, 50_000_000_000);
});
