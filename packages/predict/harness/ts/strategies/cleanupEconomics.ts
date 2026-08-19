import { type Instruction } from "../resolver.js";
import { type CleanoutPosition } from "../../../devtools/ts/runtime.js";
import { type MintLeg, type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";
import { errorTag } from "../trace.js";

const SCALE = 1_000_000_000n;
const RETRIES = 8;

export type CleanupProfile = "survivor";

interface CleanupConfig {
  sizes: number[];
  fund: bigint;
  maxWaitTicks: number;
}

const CONFIG: Record<CleanupProfile, CleanupConfig> = {
  survivor: {
    sizes: [1, 3, 5, 10, 20],
    fund: 40_000_000_000_000n,
    maxWaitTicks: 60,
  },
};

type Phase = "mint" | "wait" | "done";

function targetMarket(ctx: StrategyCtx): Mkt | null {
  const market = ctx.nearestExpiry();
  return market && market.expiryMs - Date.now() >= 25_000 ? market : null;
}

function mintLeg(
  ctx: StrategyCtx,
  market: Mkt,
  profile: CleanupProfile,
  index: number,
  size: number,
): MintLeg | null {
  const probability = ctx.rand(0.45, 0.6);
  const isUp = true;
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

export function createCleanupStrategy(profile: CleanupProfile): Strategy {
  const config = CONFIG[profile];
  let phase: Phase = "mint";
  let sizeIndex = 0;
  let target: {
    marketId: string;
    positions: CleanoutPosition[];
  } | null = null;
  let waitTicks = 0;
  let retries = 0;
  let terminalFailure: string | null = null;

  const currentSize = () => config.sizes[sizeIndex];
  const advance = () => {
    sizeIndex += 1;
    target = null;
    waitTicks = 0;
    retries = 0;
    phase = sizeIndex >= config.sizes.length ? "done" : "mint";
  };
  const fail = (
    ctx: StrategyCtx,
    message: string,
    where: string,
    tag: string,
  ) => {
    terminalFailure = message;
    ctx.trace({
      type: "fail",
      family: "cleanup-economics",
      profile,
      fatal: true,
      where,
      tag,
      n: currentSize(),
    });
  };

  return {
    name: `cleanup-${profile}`,
    tickMs: 4_000,
    maxOps: 0,
    fund: config.fund,
    done: () => phase === "done",
    failure: () => terminalFailure,
    async tick(ctx) {
      if (phase === "done" || terminalFailure) return null;

      if (phase === "mint") {
        if (!ctx.snapshot()) return null;
        const market = targetMarket(ctx);
        if (!market) return null;
        const size = currentSize();
        const legs: MintLeg[] = [];
        for (let index = 0; index < size; index += 1) {
          const leg = mintLeg(ctx, market, profile, index, size);
          if (leg) legs.push(leg);
        }
        if (legs.length !== size) return null;
        try {
          const result = await ctx.submitMintBatch(market, legs, {
            family: "cleanup-economics",
            profile,
            nTarget: size,
          });
          const minted = ((result.events ?? []) as any[]).filter((event) =>
            event.type?.includes("OrderMinted"),
          );
          const positions = minted.map((event, index) => ({
            orderId: String(event.parsedJson.order_id),
            quantity: legs[index].quantity,
          }));
          if (positions.length !== size) {
            fail(
              ctx,
              `mint batch emitted ${positions.length}/${size} OrderMinted events`,
              "mint-events",
              `minted ${positions.length}/${size}`,
            );
            return null;
          }
          target = { marketId: market.id, positions };
          waitTicks = 0;
          retries = 0;
          phase = "wait";
          return "mint";
        } catch (error) {
          ctx.trace({
            type: "fail",
            family: "cleanup-economics",
            profile,
            where: "mint",
            tag: errorTag(error),
            n: size,
          });
          return null;
        }
      }

      if (!target) {
        phase = "mint";
        return null;
      }
      let settled = false;
      try {
        settled = await ctx.isSettled(target.marketId);
      } catch {
        // A transient read failure stays inside the bounded settlement wait.
      }
      if (!settled) {
        waitTicks += 1;
        if (waitTicks > config.maxWaitTicks) {
          fail(
            ctx,
            `settlement timed out for n=${currentSize()} market=${target.marketId}`,
            "settlement",
            "settle-timeout",
          );
        }
        return null;
      }

      try {
        const result = await ctx.cleanout(
          target.marketId,
          target.positions,
        );
        advance();
      } catch (error) {
        retries += 1;
        if (retries > RETRIES) {
          fail(
            ctx,
            `cleanout exhausted ${RETRIES} retries for n=${currentSize()}: ${errorTag(error)}`,
            "cleanout",
            errorTag(error),
          );
        } else {
          ctx.trace({
            type: "cleanupRetry",
            family: "cleanup-economics",
            profile,
            phase: "cleanout",
            attempt: retries,
            tag: errorTag(error),
            n: currentSize(),
          });
        }
      }
      return null;
    },
  };
}
