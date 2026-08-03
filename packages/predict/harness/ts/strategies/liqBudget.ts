// Trade-path liquidation-budget ceiling (DBU-695).
//
// WHAT IS BEING MEASURED. `trade_liquidation_budget` bounds the ambient liquidation pass that runs
// before every mint and every live redeem. It ships at 24 and is admin-raisable to a compile-time
// max of 3,000 that no measurement stands behind. The pass costs
// min(budget, active_leveraged_orders) candidates, each priced with an un-memoized `range_price`,
// so the deliverable is per-mint `compGas` as a joint function of the configured budget and the
// book — and the budget at which an ordinary mint stops fitting in one transaction.
//
// HOW ONE RUN SWEEPS IT. Because the cost is min(budget, book), a book built cheaply at budget 24
// can be re-probed at every higher rung without rebuilding it. The keeper walks
// TRADE_LIQ_BUDGET_STAGES ("<elapsedSeconds>:<budget>,…") and traces each rung as
// {type:"liqBudget", budget, requestedAtMs, elapsedMs}; the analysis joins probes to rungs on time
// and discards the request-to-landed window, where the in-force budget is indeterminate.
//
// FILL, THEN PROBE ONE AT A TIME. Every `mint_exact_quantity` in a PTB runs its own ambient pass,
// so an N-mint batch pays N sweeps and only n==1 transactions measure the trade path. Batching
// exists solely to reach a deep book fast: up to FILL_TARGET the probe batches (halving on any
// OOG), and past it every mint goes out alone for the rest of the run. A 1-leg batch is
// byte-identical to an ordinary mint, so each of those submissions IS the measurement.
//
// Getting the split wrong is silent: batching all the way to the index cap saturates the book in
// ~3 minutes, long before the first rung steps, after which there is nothing left to mint — the run
// then collects nothing while still reporting a clean verdict. `failure()` below exists so that
// outcome fails the run instead of passing as an empty success.
//
// PROFILES. `healthy` mints far above the floor so nothing is ever knocked out: every candidate is
// priced and found healthy, isolating the scan+price cost that every mint and live redeem pays
// whether or not anything is liquidatable. `adverse` mints just under the admission cap near the
// money, so real spot drift pushes orders under their knock-out threshold and the pass MEETS
// liquidatable candidates — which are not merely priced but removed from the paged index and from
// the payout treap. That is the branch the ceiling question is really about.
//
// Only `adverse` declares a terminal wall. At the pre-memo `correction_value` slope (~1.09M/order,
// the closest measured analogue) a scan-only pass at the 3,000 max costs ~3.26e9 of the 5e9
// computation cap — expensive, but it fits — so declaring the wall on `healthy` would fail every
// clean run VACUOUS, and would whitelist the OOG if it ever did happen. An undeclared arm that
// OOGs a single mint raises `liq-budget-wall-undeclared` in the analysis instead: a scan-only mint
// that cannot fit is a bigger finding than the one being measured.
//
// Run `adverse` with KEEPER_LIQ_BUDGET=0. The keeper's own permissionless liquidate() lane would
// otherwise sweep the liquidatable orders before a mint's ambient pass could reach them, and
// `liquidated` below only sees knockouts in the trader's OWN transactions — so a keeper sweeping in
// parallel leaves `book` over-counting, which understates the slope and overstates the ceiling.
import { type Instruction } from "../resolver.js";
import { type MintLeg, type Mkt, type Strategy, type StrategyCtx } from "../strategy.js";
import { errorTag, isOog } from "../trace.js";

const SCALE = 1_000_000_000n;
const TWO_HOURS_MS = 2 * 3_600_000;
const MAX_BOOK = 5_000; // EMaxActiveLeveragedOrders — the per-market index cap
const FUND = 20_000_000_000_000n;
const GAS_BUDGET = 50_000_000_000;
const START_BATCH = 40; // safely under the ~110-mint atomic-batch OOG ceiling at budget 24
// Book size at which the fill stops batching and every mint becomes a single-mint probe.
// MAX_BOOK - FILL_TARGET = 3,000 single mints, ~75 minutes at tickMs 1500, which outlasts a
// typical ladder so every rung gets probed.
const FILL_TARGET = 2_000;
// Consecutive single-mint OOGs after which the wall is measured and the strategy holds. Without it
// the probe submits a failing ~cap-sized transaction every tick forever: an OOG still executes and
// charges, so the trader's gas coin drains and the trace fills with duplicate wall records.
const WALL_CONFIRMATIONS = 3;

export type LiqBudgetProfile = "healthy" | "adverse";

interface LiqBudgetConfig {
  leverage: (ctx: StrategyCtx, probability: number) => number;
  probability: [number, number];
  directions: ("UP" | "DN")[];
  expect?: { terminal: string[]; note?: string };
}

const CONFIG: Record<LiqBudgetProfile, LiqBudgetConfig> = {
  healthy: {
    leverage: () => 1.1, // far above floor -> never knocked out -> book == mints issued
    probability: [0.45, 0.6],
    directions: ["UP"],
  },
  adverse: {
    leverage: (ctx, probability) => ctx.leverageCap(probability) * ctx.rand(0.9, 0.99),
    probability: [0.45, 0.55], // near the money -> high static floor -> tight knock-out level
    directions: ["UP", "DN"],
    expect: {
      terminal: ["InsufficientGas"],
      note: "per-tx computation cap on a liquidating ambient pass",
    },
  },
};

function farMarket(ctx: StrategyCtx): Mkt | null {
  const live = ctx.markets();
  if (!live.length) return null;
  const farthest = live.reduce((left, right) => (right.expiryMs > left.expiryMs ? right : left));
  return farthest.expiryMs > Date.now() + TWO_HOURS_MS ? farthest : null;
}

export function createLiqBudgetStrategy(profile: LiqBudgetProfile): Strategy {
  const config = CONFIG[profile];
  // Batch mints never enter ctx.held, so lock one market and track its index here. The book is
  // mints issued MINUS orders the ambient pass knocked out, counted from each transaction's
  // OrderLiquidated events: on `adverse` those removals are continuous, and counting issued mints
  // instead would overstate the candidates scanned, understate the per-candidate slope, and
  // overstate the very ceiling the run exists to set.
  let lockedId: string | null = null;
  let minted = 0;
  let liquidated = 0;
  let probes = 0;
  let batch = START_BATCH;
  let wallHits = 0; // consecutive single-mint OOGs; reset by any success

  const book = () => minted - liquidated;

  const pickMarket = (ctx: StrategyCtx): Mkt | null => {
    const live = ctx.markets();
    if (lockedId) {
      const locked = live.find((market) => market.id === lockedId);
      if (locked) return locked;
      // Absent from THIS tick's view is not proof it settled: markets() reads markets.json, which
      // comes back empty on a torn read and drops markets whose keeper-side `funded` set a restart
      // cleared. Resetting the counters on that alone would leave `book` under-reporting the live
      // index for the rest of the run — silently, and in the direction that corrupts the fit. So
      // hold state and wait; only a genuine re-lock onto a different market resets, below.
      if (!live.length) return null;
    }
    const market = farMarket(ctx);
    if (!market) return null;
    if (market.id !== lockedId) {
      lockedId = market.id;
      minted = 0;
      liquidated = 0;
      batch = START_BATCH;
      wallHits = 0;
    }
    return market;
  };

  const nextLeg = (ctx: StrategyCtx, market: Mkt): MintLeg | null => {
    const probability = ctx.rand(config.probability[0], config.probability[1]);
    const isUp = ctx.pick(config.directions) === "UP";
    const instruction: Instruction = {
      direction: isUp ? "UP" : "DN",
      leverage: config.leverage(ctx, probability),
      targetProbability: probability,
      spendUsd: ctx.rand(5, 10),
    };
    const resolved = ctx.resolve(instruction, market);
    if (!resolved) return null;
    return {
      strike1e9: BigInt(Math.round(resolved.strikeUsd)) * SCALE,
      isUp,
      quantity: resolved.quantity,
      leverage1e9: resolved.leverage1e9,
      maxCost: resolved.maxCost,
      maxProbability: resolved.maxProbability1e9,
    };
  };

  return {
    name: `liq-budget-${profile}`,
    tickMs: 1_500,
    maxOps: 0, // duration-only: fill to FILL_TARGET, then probe one mint at a time
    fund: FUND,
    gasBudget: GAS_BUDGET,
    expect: config.expect,
    // Semantically complete once the wall is pinned: higher rungs only cost more, so there is
    // nothing left to learn from a book and budget that already cannot fit one mint.
    done: () => batch === 1 && wallHits >= WALL_CONFIRMATIONS,
    // A sweep that produced no single-mint samples measured nothing, however cleanly it ran. Report
    // that as a terminal failure rather than let an empty run pass for a successful one.
    failure: () =>
      probes === 0 && book() >= FILL_TARGET
        ? `liq-budget-${profile}: reached a book of ${book()} without collecting a single-mint probe`
        : null,
    async tick(ctx) {
      const market = pickMarket(ctx);
      if (!market || !ctx.snapshot()) return null;
      if (batch === 1 && wallHits >= WALL_CONFIRMATIONS) return null; // wall measured — hold
      // Past FILL_TARGET every mint goes out alone, whether or not anything has OOG'd. Halving on
      // OOG alone is not enough: batching only shrinks when it stops fitting, so a run would sit at
      // n=5 or n=2 for most of the ladder and emit n==1 samples — the only ones the fit uses — at
      // the very top rung, if ever.
      if (book() >= FILL_TARGET) batch = 1;
      const want = Math.min(batch, MAX_BOOK - book());
      if (want <= 0) return null; // index cap with nothing knocked out — no room left to probe
      const legs: MintLeg[] = [];
      for (let i = 0; i < want; i++) {
        const leg = nextLeg(ctx, market);
        if (leg) legs.push(leg);
      }
      if (!legs.length) return null;
      try {
        // submitMintBatch traces {type:"mintBatch", n, gas, compGas, …meta}; at n==1 that IS an
        // ordinary mint's cost, which is the number the ceiling is set from. `book` is the index
        // size the ambient pass saw — BEFORE this transaction's own mints and knockouts.
        const result = await ctx.submitMintBatch(market, legs, {
          family: "liq-budget", profile, book: book(), batch,
        });
        // The ambient pass in this very transaction may have knocked orders out of the index. It is
        // folded into `book` rather than traced separately: consecutive records already determine
        // it, since book_next - book_prev = legs - knocked. That matters because a liquidating
        // candidate costs more than a merely scanned one (index removal plus payout-tree boundary
        // removal), so the per-candidate figure is a blend whose mix has to stay recoverable.
        const knocked = ((result?.events ?? []) as { type?: string }[]).filter((event) =>
          event.type?.includes("OrderLiquidated"),
        ).length;
        minted += legs.length;
        liquidated += knocked;
        if (legs.length === 1) probes += 1;
        wallHits = 0;
        return "mint";
      } catch (error) {
        if (isOog(error)) {
          // The cap: halve and retry smaller. At batch==1 there is nothing left to halve — that IS
          // the wall, so confirm it a few times and then hold.
          ctx.trace({
            type: "mintBatch", n: legs.length, family: "liq-budget", profile, book: book(), batch,
            oog: true, err: errorTag(error),
          });
          if (batch === 1) wallHits += 1;
          batch = Math.max(1, Math.floor(batch / 2));
        } else {
          ctx.trace({ type: "fail", tag: errorTag(error), n: legs.length, book: book(), family: "liq-budget", profile });
        }
        return null;
      }
    },
  };
}
