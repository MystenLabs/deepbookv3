// Strategy abstraction for the harness trade generator.
//
// A Strategy is a code module (ts/strategies/<name>.ts) that decides what to do each tick.
// The runner (traderService.ts) builds a StrategyContext — state readers + action helpers
// that wrap the existing PTB builders, plus the bookkeeping (held orders, tracked PLP) — and
// calls strategy.tick(ctx) on a pace, stopping at the strategy's maxOps (run-to-completion).
//
// Two layers of action helpers: high-level mint/redeem/supply/withdraw (resolve + submit +
// bookkeeping + trace), and low-level submitMint (build + submit only) for strategies that
// need raw control (e.g. the adversarial probe sending a deliberately-over-cap order).
//
// Trading is queued (delayed execution): a mint or early sell is enqueued, then filled at its
// τ by a commit of the Pyth price for τ plus a resolve. Both are permissionless, so the trader
// fills its own order: it waits for τ, signs the updater's latest spot for τ with the local
// Pyth signer, and commits and resolves in one PTB. A held position is an Open queue record.
import { readFileSync } from "node:fs";

import { RESOLVER_MARKET } from "./predictConfig.js";
import { type Instruction, type Resolved, resolveMint } from "./resolver.js";
import { pricingEnvFromSnapshot, type Snap } from "./strategyPricing.js";
import { type QueueOutcome, enqueuedOrder, heldAfterSell, recordOutcome } from "./queueEvents.js";
import { abortInfo, appendTrace, gasBreakdownOf, gasOf } from "./trace.js";
import {
  type CleanoutPosition,
  type OracleFeedIds,
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
  cleanoutAccountTx,
  commitAndResolveTx,
  enqueueMintTx,
  enqueueRedeemOpenTx,
  readIsSettled,
  requestSupplyFromCustodyTx,
  requestWithdrawTx,
} from "../../devtools/ts/runtime.js";

const SCALE = 1_000_000_000n;
// `expiry_market::ERecordNotOpen` / `ENotRecordOwner`: the held record no longer holds a
// sellable position (filled away, settled, or moved), so stale local state is terminal.
const TERMINAL_REDEEM_ABORTS = new Set(["expiry_market:22", "expiry_market:23"]);
// Commit once the updater has had time to land the τ price, and resolve a bounded batch
// (resolve visits at most this many records, finished ones included).
const FILL_DELAY_MS = 150;
const RESOLVE_BATCH = 50n;

export interface Mkt {
  id: string;
  expiryMs: number;
}
export type { Snap } from "./strategyPricing.js";
// An Open queue record the trader holds: the position a filled mint (or the remainder of a
// partial sell) left in the market's queue.
export interface Held {
  recordId: bigint;
  marketId: string;
  quantity: bigint;
}
// A placed queued order and its fill attempt: the enqueue result, the commit+resolve result,
// and what that did to the order's record.
export interface QueuedFill {
  enqueue: any;
  fill: any;
  recordId: bigint;
  outcome: QueueOutcome;
}
export interface MintLeg {
  strike1e9: bigint;
  isUp: boolean;
  quantity: bigint;
  maxCost: bigint;
  maxProbability: bigint;
}
export type OpKind = "mint" | "redeem" | "supply" | "withdraw";
export interface GasBreakdown {
  computationCost: number;
  storageCost: number;
  storageRebate: number;
  nonRefundableStorageFee: number;
  net: number; // comp + storage - rebate; NEGATIVE = the cleaner is paid (refund)
}

// Everything a strategy can read + do in one tick. The runner owns the actual deps; a
// strategy only sees this interface.
export interface StrategyCtx {
  readonly feeds: OracleFeedIds;
  markets(): Mkt[]; // live markets the keeper is advertising (markets.json)
  snapshot(): Snap | null; // latest oracle snapshot (snapshot.json)
  readonly held: Held[]; // the trader's open orders (runner-maintained)
  plpShares: bigint; // tracked PLP shares (updated by refreshPlp)

  // pricing: resolve an instruction against a specific market's warmed env; null if cold/infeasible.
  resolve(inst: Instruction, market: Mkt): Resolved | null;

  // high-level actions: resolve/submit + bookkeeping + trace; return the OpKind or null (no-op).
  mint(market: Mkt, inst: Instruction): Promise<"mint" | null>;
  redeem(h: Held, closeQuantity: bigint): Promise<"redeem" | null>;
  supply(amountUsdc: bigint): Promise<"supply" | null>;
  withdraw(shares: bigint): Promise<"withdraw" | null>;

  // low-level: enqueue a mint with explicit params and fill it at τ (no bookkeeping/trace) —
  // for probes. A guard refusal aborts the enqueue; a limit that fails only at τ refunds.
  submitMint(market: Mkt, p: MintLeg): Promise<QueuedFill>;
  // low-level: the pre-cutover BATCH mint (N mint_exact_quantity calls in ONE PTB) behind the
  // capacity and cleanup measurements. Unavailable after the delayed-execution cutover, which a
  // fresh localnet publish starts past: it throws instead of submitting, so those strategies fail
  // with that reason until they are redesigned around queued orders.
  submitMintBatch(market: Mkt, legs: MintLeg[], meta?: Record<string, unknown>): Promise<any>;
  refreshPlp(): Promise<void>; // refresh ctx.plpShares from chain
  // Phase-2b (lp-adversary / E5) scaffolding — NOT consumed by any current strategy yet:

  // Cleanout gas-incentive (E1): submit ONE permissionless PTB that redeems every settled
  // position on THIS account, and return + trace the full gas breakdown (net < 0 ⇒ the cleaner
  // is paid). Requires the market settled — gate on isSettled first. After the cutover an
  // account holds no position (try_settle pays Open queue records), so only the cleanup
  // strategy, which still needs a queued-flow redesign, calls it.
  cleanout(marketId: string, positions: CleanoutPosition[]): Promise<GasBreakdown & { nSettled: number }>;
  isSettled(marketId: string): Promise<boolean>; // devInspect expiry_market::is_settled

  // utils
  rand(lo: number, hi: number): number;
  pick<T>(a: T[]): T;
  nearestExpiry(): Mkt | null;
  randomExpiry(): Mkt | null;
  pruneSettled(): void; // drop held orders whose market is no longer live (settled)
  trace(record: Record<string, unknown>): void;
}

// A strategy module. tickMs/maxOps drive the runner; fund is read by the campaign (via meta.ts)
// to fund this strategy's trader. Every keeper runs the full prod cadence set (1m/5m/1h), so a
// strategy spans all cadences via the markets it picks (nearestExpiry/randomExpiry) — no per-
// strategy cadence.
export interface Strategy {
  name: string;
  tickMs: number; // pace between ticks
  maxOps: number; // run-to-completion target (0 = unbounded; duration-only)
  fund: bigint; // USDC the keeper should fund this strategy's trader
  gasBudget?: number; // MIST; raise only for measurements whose PTB must reach a protocol wall
  // Declared terminal wall(s) this stress strategy is PROBING — substrings matched by `analyze` against
  // abort tags and the saved failed-tx `executionErrorSource`. A framework abort that IS a declared wall
  // (e.g. the object-cache limit "cached objects limit", which bricks a normal flush but is the whole
  // point here) is expected, not a bug oracle hit; a run that never reaches a declared wall fails as
  // VACUOUS (a stress that did not stress). Scope narrowly — this whitelist is per-strategy, not global.
  expect?: { terminal: string[]; note?: string };
  // Optional semantic completion for phased strategies whose useful work is
  // not naturally expressed as an operation count.
  done?: () => boolean;
  // Optional terminal failure for phased measurement strategies. The runner
  // exits non-zero instead of reporting a semantically incomplete sweep as
  // successful merely because its retry budget was exhausted.
  failure?: () => string | null;
  tick(ctx: StrategyCtx): Promise<OpKind | null>;
}

export interface ContextDeps {
  feeds: OracleFeedIds;
  instanceDir: string;
  wrapperId: string;
  label: string;
  strategyName: string;
  submit: (tx: any, label: string) => Promise<any>;
  readPlpBalance: (owner: string) => Promise<bigint>;
  traderAddress: string;
}

const rand = (lo: number, hi: number) => lo + Math.random() * (hi - lo);
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const outcomeTrace = (outcome: QueueOutcome): Record<string, unknown> =>
  outcome.status === "filled"
    ? { outcome: "filled", quantity: Number(outcome.quantity), amount: Number(outcome.amount) / 1e6 }
    : outcome.status === "refunded"
      ? { outcome: "refunded", reason: outcome.reason }
      : { outcome: "waiting" };
const pick = <T>(a: T[]): T => a[Math.floor(Math.random() * a.length)];
const isTerminalRedeemAbort = (err: unknown): boolean => {
  const a = abortInfo(err);
  return a ? TERMINAL_REDEEM_ABORTS.has(`${a.module}:${a.code}`) : false;
};
const readJson = (p: string): any => {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};

// Build the StrategyContext from the runner's deps. Holds the held/plpShares state.
export function makeContext(deps: ContextDeps): StrategyCtx {
  const held: Held[] = [];
  let plpShares = 0n;

  const markets = (): Mkt[] => readJson(`${deps.instanceDir}/markets.json`) ?? [];
  const snapshot = (): Snap | null => readJson(`${deps.instanceDir}/snapshot.json`);

  const envFor = (market: Mkt): { pythSpot: number; bsSpot: number; bsForward: number; svi: any } | null => {
    const snap = snapshot();
    return snap ? pricingEnvFromSnapshot(snap, market.expiryMs, Date.now()) : null;
  };

  const resolve = (inst: Instruction, market: Mkt): Resolved | null => {
    const env = envFor(market);
    if (!env) return null;
    const r = resolveMint(inst, env, RESOLVER_MARKET);
    return r.feasible ? r : null;
  };

  // Enqueue, wait for the order's τ, then commit the updater's latest spot as the signed price
  // for τ and resolve, in one PTB. An enqueue refusal throws. A failed fill PTB also throws; the
  // order then waits for another trader's commit or is refunded at its deadline by a later
  // resolve.
  const placeAndFill = async (market: Mkt, enqueueTx: any, label: string): Promise<QueuedFill> => {
    const enqueue = await deps.submit(enqueueTx, label);
    const order = enqueuedOrder(enqueue.events);
    const waitMs = Number(order.tauMs) + FILL_DELAY_MS - Date.now();
    if (waitMs > 0) await sleep(waitMs);
    const spot = snapshot()?.spot1e9;
    if (!spot) throw new Error(`no updater spot to commit for record ${order.recordId}`);
    const fill = await deps.submit(
      commitAndResolveTx({
        expiryMarketId: market.id,
        protocolConfigId: PROTOCOL_CONFIG_ID,
        prices: [{ tauMs: order.tauMs, channel: order.channel, spot1e9: BigInt(spot) }],
        maxOrders: RESOLVE_BATCH,
      }),
      `${label}-fill`,
    );
    return { enqueue, fill, recordId: order.recordId, outcome: recordOutcome(fill.events, order.recordId) };
  };

  const ctx: StrategyCtx = {
    feeds: deps.feeds,
    markets,
    snapshot,
    held,
    get plpShares() {
      return plpShares;
    },
    set plpShares(v: bigint) {
      plpShares = v;
    },
    resolve,

    async submitMint(market, p) {
      return placeAndFill(
        market,
        enqueueMintTx({
          expiryMarketId: market.id, wrapperId: deps.wrapperId, protocolConfigId: PROTOCOL_CONFIG_ID, ...deps.feeds,
          strike: p.strike1e9, isUp: p.isUp, quantity: p.quantity,
          maxCost: p.maxCost, maxProbability: p.maxProbability,
        }),
        "mint",
      );
    },

    async submitMintBatch() {
      throw new Error(
        "submitMintBatch: the pre-cutover batch mint aborts after the delayed-execution cutover; this strategy needs a queued-flow redesign",
      );
    },

    async mint(market, inst) {
      const r = resolve(inst, market);
      if (!r) return null;
      const spot = Number(snapshot()?.spot1e9 ?? 0) / 1e9;
      const placed = await ctx.submitMint(market, {
        strike1e9: BigInt(Math.round(r.strikeUsd)) * SCALE, isUp: inst.direction === "UP",
        quantity: r.quantity, maxCost: r.maxCost, maxProbability: r.maxProbability1e9,
      });
      const { outcome } = placed;
      if (outcome.status === "filled") {
        held.push({ recordId: placed.recordId, marketId: market.id, quantity: outcome.remainingQuantity });
      }
      ctx.trace({
        type: "mint", market: market.id.slice(0, 10), direction: inst.direction, moneyness: spot ? r.strikeUsd / spot : 0,
        prob: r.predictedProbability, ...outcomeTrace(outcome),
        gas: gasOf(placed.enqueue), fillGas: gasOf(placed.fill),
      });
      return "mint";
    },

    async redeem(h, closeQuantity) {
      const dropHeld = () => {
        const i = held.indexOf(h);
        if (i >= 0) held.splice(i, 1);
      };

      let placed: QueuedFill;
      try {
        placed = await placeAndFill(
          { id: h.marketId, expiryMs: 0 },
          enqueueRedeemOpenTx({
            expiryMarketId: h.marketId, wrapperId: deps.wrapperId, protocolConfigId: PROTOCOL_CONFIG_ID, ...deps.feeds,
            recordId: h.recordId, closeQuantity,
          }),
          "redeem",
        );
      } catch (e) {
        // Only stale local position state is terminal. Pricing, queue-capacity, stuck-queue,
        // and RPC failures keep the record tracked for retry.
        if (isTerminalRedeemAbort(e)) dropHeld();
        throw e;
      }
      const { outcome } = placed;
      // The position (or what is left of it) now lives in the sell's own record.
      const next = heldAfterSell(h, placed.recordId, outcome);
      const idx = held.indexOf(h);
      if (idx >= 0) {
        if (next) held[idx] = next;
        else held.splice(idx, 1);
      }
      ctx.trace({
        type: "redeem", market: h.marketId.slice(0, 10), partial: closeQuantity < h.quantity,
        ...outcomeTrace(outcome), gas: gasOf(placed.enqueue), fillGas: gasOf(placed.fill),
      });
      return "redeem";
    },

    async supply(amountUsdc) {
      const res = await deps.submit(
        requestSupplyFromCustodyTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, wrapperId: deps.wrapperId, amount: amountUsdc }),
        "supply",
      );
      ctx.trace({ type: "supply", amount: Number(amountUsdc) / 1e6, gas: gasOf(res) });
      return "supply";
    },

    async withdraw(shares) {
      const res = await deps.submit(
        requestWithdrawTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, wrapperId: deps.wrapperId, shares }),
        "withdraw",
      );
      ctx.trace({ type: "withdraw", shares: Number(shares), gas: gasOf(res) });
      return "withdraw";
    },

    async refreshPlp() {
      plpShares = await deps.readPlpBalance(deps.traderAddress);
    },

    async cleanout(marketId, positions) {
      const res = await deps.submit(
        cleanoutAccountTx({ expiryMarketId: marketId, wrapperId: deps.wrapperId, positions }),
        "cleanout",
      );
      const g = gasBreakdownOf(res);
      // A settled position's cleanout removes its active-index entry and adjusts cached liability
      // (process_settled_close); the payout-tree node persists under the settled-liability model.
      // NB: the P-9 gas figures predate the tombstone removal (DBU-592) — the per-position
      // structure needs re-measurement under the derived-state model.
      const evs = (res.events ?? []) as any[];
      const nSettled = evs.filter((e) => e.type?.includes("SettledOrderRedeemed")).length;
      ctx.trace({ type: "cleanout", n: positions.length, nSettled, ...g });
      return { ...g, nSettled };
    },
    async isSettled(marketId) {
      return readIsSettled(marketId);
    },

    rand,
    pick,
    nearestExpiry() {
      const m = markets();
      return m.length ? m.reduce((a, b) => (a.expiryMs <= b.expiryMs ? a : b)) : null;
    },
    randomExpiry() {
      const m = markets();
      return m.length ? pick(m) : null;
    },
    pruneSettled() {
      const live = new Set(markets().map((m) => m.id));
      for (let i = held.length - 1; i >= 0; i--) if (!live.has(held[i].marketId)) held.splice(i, 1);
    },
    trace(record) {
      appendTrace(deps.label, { strategy: deps.strategyName, ...record });
    },
  };
  return ctx;
}
