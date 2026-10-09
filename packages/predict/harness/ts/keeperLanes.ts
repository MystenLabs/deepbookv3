// The keeper's settlement and flush lanes, written against a small chain interface so the
// ordering rules can be unit-tested without a localnet. `keeperService.ts` supplies the real
// chain; the tests supply a model of it.
//
// The rule both lanes keep: a market whose queue's settlement is unfinished stays on the
// keeper's work list until its payout walk completes, its records are cleaned up, and it has left
// `plp::active_expiry_markets`. The work list is the active set plus a durable list of every
// market with a queue whose settlement has not finished, because the active set alone is not
// enough: `rebalance_expiry_cash` is permissionless, so anyone can sweep a settled market out of
// it with Open queue records still unpaid, and the flush snapshot sweeps every settled market it
// snapshots. The keeper's own lanes still sweep only after the walk completes, and the flush runs
// only once every expired market's walk has completed and settles nothing itself.
import { type QueueEvent, marketSettledIn } from "./queueEvents.js";

export interface LaneMarket {
  id: string;
  expiryMs: number;
}

export interface SettlementProgress {
  settled: boolean;
  // `queue::payout_progress`'s `payouts_completed`, true for a market without a queue.
  payoutsCompleted: boolean;
  // The queue's `next_id`: every record ID below it may be cleaned up once the walk completes.
  nextId: bigint;
}

export interface KeeperChain {
  clockMs(): Promise<number>;
  // The chain's active expiry markets with their expiries.
  activeMarkets(): Promise<LaneMarket[]>;
  // The durable list of markets with a queue whose settlement has not finished, active or not.
  pendingMarkets(): Promise<LaneMarket[]>;
  // Drop a market from the durable list once its settlement has finished.
  retire(marketId: string): Promise<void>;
  settlementProgress(marketId: string): Promise<SettlementProgress>;
  // One PTB: insert the exact expiry spot and call Predict's try_settle. Returns its events.
  trySettle(market: LaneMarket): Promise<QueueEvent[] | undefined>;
  // One PTB with one `queue::settle_step` call.
  settleStep(market: LaneMarket): Promise<unknown>;
  // `queue::cleanup` of every record ID below `nextId`, in bounded batches.
  cleanup(market: LaneMarket, nextId: bigint): Promise<unknown>;
  // `rebalance_expiry_cash`, which sweeps the settled market out of the active set.
  sweep(market: LaneMarket): Promise<unknown>;
  // The staged flush (snapshot, one value_expiry per market, finish) over `marketIds`.
  flush(marketIds: string[]): Promise<unknown>;
}

// Settlement transactions one market may take in one pass: try_settle, then queue settle_step
// calls (refund batches of 450 records, then payout batches of 900). Far above what a harness
// queue needs.
export const MAX_SETTLE_PHASES = 32;

// Drive one market's settlement to completion, one call per PTB, then clean up and sweep it:
// Predict's try_settle until the market is settled, the queue's settle_step until its payout
// walk completes, cleanup of its finished records, and the sweep. A market someone else already
// swept out of the active set (`active` false) skips the sweep, which would abort. The market
// then leaves the durable list. Returns the number of settle transactions it sent before the
// cleanup. A throw (a failed PTB, a try_settle that did not settle, or the phase cap) leaves the
// market unswept and listed, so the next pass resumes it from chain state.
export async function settleMarket(chain: KeeperChain, market: LaneMarket, active = true): Promise<number> {
  let phases = 0;
  let progress = await chain.settlementProgress(market.id);
  if (!progress.settled) {
    phases += 1;
    const events = await chain.trySettle(market);
    progress = await chain.settlementProgress(market.id);
    if (!progress.settled || !marketSettledIn(events)) {
      throw new Error(`settlement of ${market.id.slice(0, 10)} made no progress: try_settle did not settle`);
    }
  }
  while (!progress.payoutsCompleted) {
    if (phases >= MAX_SETTLE_PHASES) {
      throw new Error(`settlement of ${market.id.slice(0, 10)} unfinished after ${MAX_SETTLE_PHASES} phases`);
    }
    phases += 1;
    await chain.settleStep(market);
    progress = await chain.settlementProgress(market.id);
  }
  if (progress.nextId > 0n) await chain.cleanup(market, progress.nextId);
  if (active) await chain.sweep(market);
  await chain.retire(market.id);
  return phases;
}

export type SettleResult =
  | { market: LaneMarket; phases: number }
  | { market: LaneMarket; error: unknown };

export const settleFailed = (result: SettleResult): result is { market: LaneMarket; error: unknown } =>
  "error" in result;

// Settle every market at or past expiry on the work list (the active set, then the listed
// markets that already left it), each on its own so one failure stays local.
export async function settleExpired(chain: KeeperChain): Promise<SettleResult[]> {
  const now = await chain.clockMs();
  const active = await chain.activeMarkets();
  const activeIds = new Set(active.map((market) => market.id));
  const swept = (await chain.pendingMarkets()).filter((market) => !activeIds.has(market.id));
  const results: SettleResult[] = [];
  for (const market of [...active, ...swept]) {
    if (market.expiryMs > now) continue;
    try {
      results.push({ market, phases: await settleMarket(chain, market, activeIds.has(market.id)) });
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
