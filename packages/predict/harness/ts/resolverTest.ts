// Offline self-check for the resolver math (no localnet). Runs the resolver against
// a real BS snapshot for a few instructions and prints strike / predicted prob /
// feasibility / quantity. Run: npx tsx resolverTest.ts
import { type Instruction, type MarketParams, type Snapshot, resolveMint } from "./resolver.js";

// Real Block Scholes snapshot (BTC, a daily expiry) + spot from a probe run.
const snap: Snapshot = {
  pythSpot: 60000,
  bsSpot: 60000,
  bsForward: 60050,
  svi: { a: 0.000373398, b: 0.009563705, rho: 0.173092107, m: 0.028569114, sigma: 0.004909991 },
};

// Contract defaults: Lmax 3x, ltv 0.85, entry-prob [0.01, 0.99], lot 10_000.
// tick = $0.01; admission grid = $1.
const mkt: MarketParams = {
  tickSize: 0.01,
  admissionTickSize: 1,
  maxAdmissionLeverage: 3,
  minEntryProbability: 0.01,
  maxEntryProbability: 0.99,
  liquidationLtv: 0.85,
  lotSize: 10_000,
};

const cases: Instruction[] = [
  { direction: "UP", leverage: 2, targetProbability: 0.05, spendUsd: 100 }, // expect infeasible (cap ~1.48x)
  { direction: "UP", leverage: 1.3, targetProbability: 0.05, spendUsd: 100 }, // feasible
  { direction: "UP", leverage: 2, targetProbability: 0.3, spendUsd: 100 }, // feasible (cap ~2.44x)
  { direction: "DN", leverage: 2, targetProbability: 0.3, spendUsd: 100 }, // feasible
  { direction: "UP", leverage: 3, targetProbability: 0.5, spendUsd: 100 }, // expect infeasible (cap <3x)
];

for (const c of cases) {
  const r = resolveMint(c, snap, mkt);
  const q = Number(r.quantity) / 1e6; // DUSDC -> $ max payout
  console.log(
    `${c.leverage}x ${c.direction} @ ~${(c.targetProbability * 100).toFixed(0)}c $${c.spendUsd}: ` +
      `${r.feasible ? "OK  " : "INFEASIBLE"} strike=$${r.strikeUsd.toFixed(0)} ` +
      `p=${(r.predictedProbability * 100).toFixed(2)}c qty=${q.toFixed(1)} ticks=[${r.lowerTick},${r.higherTick}]` +
      (r.reason ? `  (${r.reason})` : ""),
  );
}
