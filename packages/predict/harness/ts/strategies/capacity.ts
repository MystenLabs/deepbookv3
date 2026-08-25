import { FAR_MARKET_MIN_HORIZON_MS } from "../predictConfig.js";
import { type Instruction } from "../resolver.js";
import { type MintLeg, type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";
import { errorTag, isOog } from "../trace.js";

const SCALE = 1_000_000_000n;
const MAX_BOOK = 5_000;
const FUND = 20_000_000_000_000n;
const GAS_BUDGET = 50_000_000_000;

export type CapacityProfile = "single" | "pool" | "tree" | "user-off" | "user-on";

interface CapacityConfig {
  profile: CapacityProfile;
  batchSize: number;
  probability: [number, number];
}

const CONFIG: Record<CapacityProfile, CapacityConfig> = {
  single: {
    profile: "single",
    batchSize: 40,
    probability: [0.45, 0.6],
  },
  pool: {
    profile: "pool",
    batchSize: 40,
    probability: [0.45, 0.6],
  },
  tree: {
    profile: "tree",
    batchSize: 12,
    probability: [0.02, 0.98],
  },
  // Single-leg mints on one far market. `user-off` is the no-grid control;
  // `user-on` cuts a grid and snapshots a 2% max marginal rate so the quote
  // walks capital. maxCost is uncapped on both so a growing charge cannot
  // abort the measurement.
  "user-off": {
    profile: "user-off",
    batchSize: 1,
    probability: [0.45, 0.6],
  },
  "user-on": {
    profile: "user-on",
    batchSize: 1,
    probability: [0.45, 0.6],
  },
};

const USER_PROFILES = new Set<CapacityProfile>(["user-off", "user-on"]);
const USER_MAX_COST = 1_000_000_000_000_000n;
const USER_IMPACT_RATE = 20_000_000n; // 2%, 1e9-scaled

function farMarket(ctx: StrategyCtx): Mkt | null {
  const live = ctx.markets();
  if (!live.length) return null;
  const farthest = live.reduce((left, right) =>
    right.expiryMs > left.expiryMs ? right : left,
  );
  return farthest.expiryMs > Date.now() + FAR_MARKET_MIN_HORIZON_MS ? farthest : null;
}

function mintLeg(
  ctx: StrategyCtx,
  market: Mkt,
  probability: number,
  isUp = true,
): MintLeg | null {
  const instruction: Instruction = {
    direction: isUp ? "UP" : "DN",
    targetProbability: probability,
    spendUsd: ctx.rand(5, 10),
  };
  const resolved = ctx.resolve(instruction, market);
  if (!resolved) return null;
  return {
    strike1e9: BigInt(Math.round(resolved.strikeUsd)) * SCALE,
    isUp,
    quantity: resolved.quantity,
    maxCost: resolved.maxCost,
    maxProbability: resolved.maxProbability1e9,
  };
}

export function createCapacityStrategy(profile: CapacityProfile): Strategy {
  const config = CONFIG[profile];
  const perMarket = new Map<string, number>();
  let lockedId: string | null = null;
  let roundRobin = 0;
  const usedStrikes = new Set<number>();
  let probabilityCursor = config.probability[1];

  const resetLocked = () => {
    lockedId = null;
    usedStrikes.clear();
    probabilityCursor = config.probability[1];
  };

  const pickMarket = (ctx: StrategyCtx): Mkt | null => {
    const live = ctx.markets();
    const liveIds = new Set(live.map((market) => market.id));
    for (const id of perMarket.keys()) {
      if (!liveIds.has(id)) perMarket.delete(id);
    }
    if (profile === "pool") {
      if (!live.length) return null;
      const market = live[roundRobin % live.length];
      roundRobin += 1;
      return market;
    }
    if (lockedId) {
      const locked = live.find((market) => market.id === lockedId);
      if (locked) return locked;
      resetLocked();
    }
    const market = farMarket(ctx);
    if (market) lockedId = market.id;
    return market;
  };

  const nextTreeLeg = (ctx: StrategyCtx, market: Mkt): MintLeg | null => {
    while (probabilityCursor > config.probability[0]) {
      const probability = probabilityCursor;
      probabilityCursor -= 0.00045;
      const leg = mintLeg(ctx, market, probability);
      if (!leg) continue;
      const strike = Number(leg.strike1e9 / SCALE);
      if (usedStrikes.has(strike)) continue;
      usedStrikes.add(strike);
      return leg;
    }
    return null;
  };

  return {
    name: `capacity-${profile}`,
    tickMs: profile === "tree" ? 1_200 : 1_500,
    fund: FUND,
    gasBudget: GAS_BUDGET,
    // The tree profile still drives the node count the flush hits the
    // object-cache ceiling at. user-on turns the inventory-impact rate on;
    // the keeper create pushes an off-chain 1% ladder.
    inventoryImpactMaxRate: profile === "user-on" ? USER_IMPACT_RATE : 0n,
    maxOps: USER_PROFILES.has(profile) ? 40 : 0,
    expect:
      profile === "tree"
        ? {
            terminal: ["cached objects limit"],
            note: "single-market payout-tree object-cache ceiling at the isolated node limit",
          }
        : undefined,
    async tick(ctx) {
      const market = pickMarket(ctx);
      if (!market || !ctx.snapshot()) return null;
      const have = perMarket.get(market.id) ?? 0;
      const room = (profile === "tree" ? 1_000 : MAX_BOOK) - have;
      if (room <= 0) return null;
      const batchSize =
        profile === "tree" && have > 940
          ? 2
          : config.batchSize;
      const legs: MintLeg[] = [];
      const [minimum, maximum] = config.probability;
      for (let index = 0; index < Math.min(batchSize, room); index += 1) {
        const leg =
          profile === "tree"
            ? nextTreeLeg(ctx, market)
            : mintLeg(
                ctx,
                market,
                ctx.rand(minimum, maximum),
              );
        if (leg) {
          if (USER_PROFILES.has(profile)) leg.maxCost = USER_MAX_COST;
          legs.push(leg);
        }
      }
      if (!legs.length) return null;

      try {
        await ctx.submitMintBatch(market, legs, {
          family: "capacity",
          profile,
          book: have,
        });
        perMarket.set(market.id, have + legs.length);
        const total = [...perMarket.values()].reduce(
          (sum, size) => sum + size,
          0,
        );
        ctx.trace({
          type: profile === "tree" ? "nodes" : "book",
          family: "capacity",
          profile,
          size: total,
          nodeCount: profile === "tree" ? usedStrikes.size : undefined,
          markets: perMarket.size,
          market: market.id,
          perMarket: have + legs.length,
        });
        return "mint";
      } catch (error) {
        if (profile === "tree") {
          for (const leg of legs) {
            usedStrikes.delete(Number(leg.strike1e9 / SCALE));
          }
        }
        if (isOog(error)) {
          ctx.trace({
            type: "mintBatch",
            family: "capacity",
            profile,
            n: legs.length,
            book: have,
            oog: true,
            err: errorTag(error),
          });
        } else {
          ctx.trace({
            type: "fail",
            family: "capacity",
            profile,
            tag: errorTag(error),
            n: legs.length,
            book: have,
          });
        }
        return null;
      }
    },
  };
}
