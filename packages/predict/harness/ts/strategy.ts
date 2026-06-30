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
import { readFileSync } from "node:fs";

import { RESOLVER_MARKET } from "./predictConfig.js";
import { type Instruction, type Resolved, resolveMint } from "./resolver.js";
import { appendTrace, gasOf } from "./trace.js";
import {
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
  mintTx,
  redeemTx,
  requestSupplyFromCustodyTx,
  requestWithdrawTx,
} from "./runtime.js";

const SCALE = 1_000_000_000n;
const ADMISSION_K = 0.2;

export interface Mkt {
  id: string;
  expiryMs: number;
}
export interface Snap {
  spot1e9: string;
  publishedAtMs: string;
  expiries: Record<string, { forward: number; svi: { alpha: number; beta: number; rho: number; m: number; sigma: number } }>;
}
export interface Held {
  orderId: string;
  marketId: string;
  quantity: bigint;
  leverage1e9: bigint;
}
export type OpKind = "mint" | "redeem" | "supply" | "withdraw";

// Everything a strategy can read + do in one tick. The runner owns the actual deps; a
// strategy only sees this interface.
export interface StrategyCtx {
  readonly feeds: any;
  markets(): Mkt[]; // live markets the keeper is advertising (markets.json)
  snapshot(): Snap | null; // latest oracle snapshot (snapshot.json)
  readonly held: Held[]; // the trader's open orders (runner-maintained)
  plpShares: bigint; // tracked PLP shares (updated by refreshPlp)

  // pricing: resolve an instruction against a specific market's warmed env; null if cold/infeasible.
  resolve(inst: Instruction, market: Mkt): Resolved | null;

  // high-level actions: resolve/submit + bookkeeping + trace; return the OpKind or null (no-op).
  mint(market: Mkt, inst: Instruction): Promise<"mint" | null>;
  redeem(h: Held, closeQuantity: bigint): Promise<"redeem" | null>;
  supply(amountDusdc: bigint): Promise<"supply" | null>;
  withdraw(shares: bigint): Promise<"withdraw" | null>;

  // low-level: build + submit a mint with explicit params (no bookkeeping/trace) — for probes.
  submitMint(market: Mkt, p: { strike1e9: bigint; isUp: boolean; quantity: bigint; leverage1e9: bigint; maxCost: bigint; maxProbability: bigint }): Promise<any>;
  refreshPlp(): Promise<void>; // refresh ctx.plpShares from chain

  // utils
  rand(lo: number, hi: number): number;
  pick<T>(a: T[]): T;
  leverageCap(p: number): number;
  nearestExpiry(): Mkt | null;
  randomExpiry(): Mkt | null;
  pruneSettled(): void; // drop held orders whose market is no longer live (settled)
  trace(record: Record<string, unknown>): void;
}

// A strategy module. tickMs/maxOps drive the runner; fund/cadence are read by the campaign
// (via meta.ts) to configure the keeper for this strategy's localnet.
export interface Strategy {
  name: string;
  tickMs: number; // pace between ticks
  maxOps: number; // run-to-completion target (0 = unbounded; duration-only)
  fund: bigint; // DUSDC the keeper should fund this strategy's trader
  cadence: number; // keeper cadence id for this strategy's localnet
  tick(ctx: StrategyCtx): Promise<OpKind | null>;
}

export interface ContextDeps {
  feeds: any;
  instanceDir: string;
  wrapperId: string;
  label: string;
  strategyName: string;
  submit: (tx: any, label: string) => Promise<any>;
  readPlpBalance: (owner: string) => Promise<bigint>;
  traderAddress: string;
}

const rand = (lo: number, hi: number) => lo + Math.random() * (hi - lo);
const pick = <T>(a: T[]): T => a[Math.floor(Math.random() * a.length)];
const leverageCap = (p: number) =>
  1 + (RESOLVER_MARKET.maxAdmissionLeverage - 1) * ((p * (1 + ADMISSION_K)) / (p + ADMISSION_K));
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
    const exp = snap?.expiries?.[String(market.expiryMs)];
    if (!snap || !exp) return null;
    const spot = Number(snap.spot1e9) / 1e9;
    const svi = { a: exp.svi.alpha, b: exp.svi.beta, rho: exp.svi.rho, m: exp.svi.m, sigma: exp.svi.sigma };
    return { pythSpot: spot, bsSpot: spot, bsForward: Number(exp.forward), svi };
  };

  const resolve = (inst: Instruction, market: Mkt): Resolved | null => {
    const env = envFor(market);
    if (!env) return null;
    const r = resolveMint(inst, env, RESOLVER_MARKET);
    return r.feasible ? r : null;
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
      return deps.submit(
        mintTx({
          expiryMarketId: market.id, wrapperId: deps.wrapperId, protocolConfigId: PROTOCOL_CONFIG_ID, ...deps.feeds,
          strike: p.strike1e9, isUp: p.isUp, quantity: p.quantity, leverage: p.leverage1e9,
          maxCost: p.maxCost, maxProbability: p.maxProbability,
        }),
        "mint",
      );
    },

    async mint(market, inst) {
      const r = resolve(inst, market);
      if (!r) return null;
      const spot = Number(snapshot()?.spot1e9 ?? 0) / 1e9;
      const res = await ctx.submitMint(market, {
        strike1e9: BigInt(Math.round(r.strikeUsd)) * SCALE, isUp: inst.direction === "UP",
        quantity: r.quantity, leverage1e9: r.leverage1e9, maxCost: r.maxCost, maxProbability: r.maxProbability1e9,
      });
      const ev = res.events?.find((e: any) => e.type?.includes("OrderMinted"));
      if (ev) held.push({ orderId: ev.parsedJson.order_id, marketId: market.id, quantity: r.quantity, leverage1e9: r.leverage1e9 });
      ctx.trace({
        type: "mint", market: market.id.slice(0, 10), direction: inst.direction, moneyness: spot ? r.strikeUsd / spot : 0,
        prob: r.predictedProbability, leverage: inst.leverage, netPremium: ev ? Number(ev.parsedJson.net_premium) / 1e6 : 0, gas: gasOf(res),
      });
      return "mint";
    },

    async redeem(h, closeQuantity) {
      let res;
      try {
        res = await deps.submit(
          redeemTx({ expiryMarketId: h.marketId, wrapperId: deps.wrapperId, protocolConfigId: PROTOCOL_CONFIG_ID, ...deps.feeds, orderId: h.orderId, closeQuantity }),
          "redeem",
        );
      } catch (e) {
        // The order is un-redeemable (liquidated / knocked out / already closed). Drop it so it
        // isn't re-selected every tick — which would spam identical aborts that look like bugs.
        const i = held.indexOf(h);
        if (i >= 0) held.splice(i, 1);
        throw e;
      }
      const idx = held.indexOf(h);
      const partial = closeQuantity < h.quantity;
      if (partial) {
        // Capture the replacement order id (LiveOrderRedeemed.replacement_order_id) so the
        // remaining position stays tracked.
        const ev = res.events?.find((e: any) => e.type?.includes("LiveOrderRedeemed"));
        const repl = ev?.parsedJson?.replacement_order_id;
        if (idx >= 0) {
          if (repl) held[idx] = { ...h, orderId: String(repl), quantity: h.quantity - closeQuantity };
          else held.splice(idx, 1);
        }
      } else if (idx >= 0) {
        held.splice(idx, 1);
      }
      ctx.trace({ type: "redeem", market: h.marketId.slice(0, 10), partial, gas: gasOf(res) });
      return "redeem";
    },

    async supply(amountDusdc) {
      const res = await deps.submit(
        requestSupplyFromCustodyTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, wrapperId: deps.wrapperId, amount: amountDusdc }),
        "supply",
      );
      ctx.trace({ type: "supply", amount: Number(amountDusdc) / 1e6, gas: gasOf(res) });
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

    rand,
    pick,
    leverageCap,
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
