// The keeper's settlement and flush lanes, written against a small chain interface so the
// ordering rules can be unit-tested without a localnet. `keeperService.ts` supplies the real
// chain; the tests supply a model of it.
//
// The rule both lanes keep: a market whose settlement payout walk is unfinished never leaves
// `plp::active_expiry_markets`. The keeper rebuilds its work list from that set every tick
// (and after a restart), so a settled market swept out of it with Open queue records still
// unpaid would never be revisited. Two things sweep a settled market: the settlement lane's
// `rebalance_expiry_cash`, and the flush snapshot, which sweeps every settled market it
// snapshots. So the settlement lane sweeps only after the walk completes, and the flush runs
// only once every expired market's walk has completed and settles nothing itself.
import { type QueueEvent, settlementComplete, settlementMadeProgress } from "./queueEvents.js";

export interface LaneMarket {
  id: string;
  expiryMs: number;
}

export interface SettlementProgress {
  settled: boolean;
  payoutCursor: bigint;
  nextId: bigint;
}

export interface KeeperChain {
  clockMs(): Promise<number>;
  // The chain's active expiry markets with their expiries: the keeper's only work list.
  activeMarkets(): Promise<LaneMarket[]>;
  settlementProgress(marketId: string): Promise<SettlementProgress>;
  // One PTB: insert the exact expiry spot, call try_settle once, and, with `sweep`, call
  // rebalance_expiry_cash. Returns the transaction's events.
  settlePhase(market: LaneMarket, sweep: boolean): Promise<QueueEvent[] | undefined>;
  // The staged flush (snapshot, one value_expiry per market, finish) over `marketIds`.
  flush(marketIds: string[]): Promise<unknown>;
}

// try_settle calls one market may take in one pass: refund batches (450 records), the
// settling call, then payout batches (900 records). Far above what a harness queue needs.
export const MAX_SETTLE_PHASES = 32;

// Drive one market's settlement to completion, one try_settle phase per PTB, then sweep it.
// Returns the number of phases it ran before the sweep. A throw (a failed PTB, a phase that
// made no progress, or the phase cap) leaves the market unswept, so it stays in the active set
// and the next pass resumes it from chain state.
export async function settleMarket(chain: KeeperChain, market: LaneMarket): Promise<number> {
  for (let phase = 0; phase < MAX_SETTLE_PHASES; phase++) {
    if (settlementComplete(await chain.settlementProgress(market.id))) {
      // try_settle on a complete market is a no-op returning true; the sweep is the point.
      await chain.settlePhase(market, true);
      return phase;
    }
    const events = await chain.settlePhase(market, false);
    if (!settlementMadeProgress(events)) {
      throw new Error(`settlement of ${market.id.slice(0, 10)} made no progress in phase ${phase}`);
    }
  }
  throw new Error(`settlement of ${market.id.slice(0, 10)} unfinished after ${MAX_SETTLE_PHASES} phases`);
}

export type SettleResult =
  | { market: LaneMarket; phases: number }
  | { market: LaneMarket; error: unknown };

export const settleFailed = (result: SettleResult): result is { market: LaneMarket; error: unknown } =>
  "error" in result;

// Settle every active market at or past expiry, each on its own so one failure stays local.
export async function settleExpired(chain: KeeperChain): Promise<SettleResult[]> {
  const now = await chain.clockMs();
  const results: SettleResult[] = [];
  for (const market of await chain.activeMarkets()) {
    if (market.expiryMs > now) continue;
    try {
      results.push({ market, phases: await settleMarket(chain, market) });
    } catch (error) {
      results.push({ market, error });
    }
  }
  return results;
}

export interface FlushLaneResult {
  // Markets that expired after the settlement lane ran, settled here before the snapshot.
  preFlush: SettleResult[];
  // True when a pre-flush settlement failed, so no flush was sent. That failure is in `preFlush`.
  skipped: boolean;
  marketIds: string[];
  flushed: unknown;
  error?: unknown;
}

// Settle what expired since the settlement lane, then flush. The flush is skipped while any
// expired market's walk is unfinished, because its snapshot would sweep that market. A market
// that expires between this pass and the snapshot makes the snapshot abort (expired and
// unsettled); the flush defers and the next tick's settlement lane settles that market.
export async function settleThenFlush(chain: KeeperChain): Promise<FlushLaneResult> {
  const preFlush = await settleExpired(chain);
  if (preFlush.some(settleFailed)) return { preFlush, skipped: true, marketIds: [], flushed: null };
  const marketIds = (await chain.activeMarkets()).map((market) => market.id);
  try {
    return { preFlush, skipped: false, marketIds, flushed: await chain.flush(marketIds) };
  } catch (error) {
    return { preFlush, skipped: false, marketIds, flushed: null, error };
  }
}

export interface SettlementTick {
  // The settlement lane's results for every market at or past expiry.
  settled: SettleResult[];
  // The flush lane, run only when something settled and nothing failed; null otherwise.
  flush: FlushLaneResult | null;
}

// One keeper tick's settlement and flush lanes. A failed settlement leaves its market unswept
// and active, and holds the flush back until a later tick finishes that market's walk.
export async function settleAndFlush(chain: KeeperChain): Promise<SettlementTick> {
  const settled = await settleExpired(chain);
  if (settled.length === 0 || settled.some(settleFailed)) return { settled, flush: null };
  return { settled, flush: await settleThenFlush(chain) };
}
