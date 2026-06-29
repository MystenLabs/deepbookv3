// Predict lifecycle keeper. On an oracle-ready localnet, stand up the Predict layer
// then run a tick loop that rolls the cadence, flushes + settles + compacts expired
// markets, rebalances, and liquidates. The "conditional cron" is off-chain: each tick
// reads state (an in-memory market list + the on-chain clock) and assembles the due
// PTBs — the keeper is the sole market creator, so it tracks its own markets rather
// than parsing PoolVault.
//
// First cut is SELF-REFRESHING: it pushes the oracle for its own live markets before
// each flush (no separate updater). Folding onto the shared updater feed is the next
// step (so traders + keeper share one stream).
import { CADENCES } from "./predictConfig.js";
import {
  type Feeds,
  bootstrapPool,
  createAndSeedMarket,
  fetchPythSpot,
  fetchSnapshot,
  gridExpiry,
  isoSec,
  setupFeedsAndConfig,
  to1e9,
} from "./predictSetup.js";
import {
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
  clampedSourceTimestampMs,
  clockTimestampMs,
  executeAndWait,
  keeperFlushTx,
  keeperLiquidateTx,
  rebalanceExpiryCashTx,
} from "./runtime.js";

const CADENCE = Number(process.env.KEEPER_CADENCE ?? 0); // default 1m (fast roll)
const WINDOW = Number(CADENCES[CADENCE].windowSize); // markets to keep ahead of now
const TICK_MS = Number(process.env.KEEPER_TICK_MS ?? 20_000);
const DURATION_MS = Number(process.env.DURATION_MS ?? 0); // 0 = until killed
const LIQ_BUDGET = 24n; // trade_liquidation_budget

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

interface Market {
  id: string;
  expiryMs: number;
  settled: boolean;
}

async function tick(feeds: Feeds, lifecycleCapId: string, markets: Market[]) {
  const clock = Number(await clockTimestampMs());
  const active = markets.filter((m) => !m.settled);
  const expired = active.filter((m) => m.expiryMs <= clock);
  const live = active.filter((m) => m.expiryMs > clock);

  // Snapshot all live expiries once; these feed the in-PTB refresh that the flush and
  // liquidate each fold in, so their priced reads are fresh within their own atomic tx.
  const liveSnaps = await Promise.all(live.map((m) => fetchSnapshot(m.expiryMs)));
  const spot1e9 = live.length ? to1e9(liveSnaps[0].pythSpot) : 0n;
  const grid = live.map((m, i) => gridExpiry(m.expiryMs, liveSnaps[i]));
  const freshTs = async () => (await clampedSourceTimestampMs(BigInt(Date.now()))) ?? BigInt(clock - 1);

  // 1. Flush + settle (when a market has expired): the flush refreshes live expiries +
  //    inserts each expired market's terminal obs, then values EVERY active market —
  //    settled ones are swept (cash back to pool) and drop out of the active set.
  if (expired.length) {
    const settlePrice = live.length ? spot1e9 : to1e9(await fetchPythSpot());
    const settlements = expired.map((m) => ({ expiryMs: BigInt(m.expiryMs), price: settlePrice }));
    await executeAndWait(
      keeperFlushTx({ feeds, spot: settlePrice, grid, sourceTimestampMs: await freshTs(), marketIds: active.map((m) => m.id), settlements, poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId }),
      "flush+settle",
    );
    expired.forEach((m) => (m.settled = true));
    console.log(`[keeper] settled+compacted ${expired.length} market(s): ${expired.map((m) => isoSec(m.expiryMs)).join(", ")}`);
  }

  // 2. Liquidate live markets (refresh-in-PTB; a no-op without under-floor orders).
  if (live.length) {
    await executeAndWait(
      keeperLiquidateTx({ feeds, spot: spot1e9, grid, sourceTimestampMs: await freshTs(), markets: live.map((m) => m.id), protocolConfigId: PROTOCOL_CONFIG_ID, budget: LIQ_BUDGET }),
      "liquidate",
    );
  }

  // 3. Roll: keep WINDOW markets ahead of now, funding each as a separate tx right after
  //    creation (a just-created shared object can't be a later input in the SAME PTB, but
  //    a follow-up tx is fine).
  const liveCount = markets.filter((m) => !m.settled && m.expiryMs > clock).length;
  if (liveCount < WINDOW) {
    const { marketId, expiryMs } = await createAndSeedMarket(feeds, lifecycleCapId, CADENCE);
    markets.push({ id: marketId, expiryMs: Number(expiryMs), settled: false });
    await executeAndWait(
      rebalanceExpiryCashTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId: marketId, pythFeedId: feeds.pythFeedId }),
      "rebalance",
    );
    console.log(`[keeper] rolled: market ${marketId.slice(0, 10)} expiry=${isoSec(Number(expiryMs))} (live ${liveCount + 1}/${WINDOW})`);
  }
}

async function main() {
  console.log(`[keeper] cadence=${CADENCE} window=${WINDOW} tick=${TICK_MS}ms duration=${DURATION_MS || "∞"}ms`);
  const { feeds, lifecycleCapId } = await setupFeedsAndConfig([CADENCE]);
  await bootstrapPool(lifecycleCapId);
  console.log("[keeper] bootstrapped (PLP minted); rolling markets...");

  const markets: Market[] = [];

  const deadline = DURATION_MS > 0 ? Date.now() + DURATION_MS : 0;
  for (;;) {
    try {
      await tick(feeds, lifecycleCapId, markets);
    } catch (e) {
      console.error("[keeper] tick error:", e instanceof Error ? e.message : e);
    }
    if (deadline && Date.now() >= deadline) break;
    await sleep(TICK_MS);
  }
  const settled = markets.filter((m) => m.settled).length;
  console.log(`[keeper] done — ${markets.length} markets created, ${settled} settled+compacted`);
}

main().then(() => process.exit(0)).catch((e) => { console.error("[keeper] FAIL:", e); process.exit(1); });
