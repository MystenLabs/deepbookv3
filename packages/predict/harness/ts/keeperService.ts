// Predict lifecycle keeper. On an oracle-ready localnet WITH the updater streaming, run
// a tick loop that rolls the cadence, flushes + settles + compacts expired markets,
// rebalances, and liquidates. The "conditional cron" is off-chain: each tick reads state
// (an in-memory market list + the on-chain clock) and assembles the due PTBs.
//
// The keeper is the sole market creator (tracks its own markets) and the single setup
// owner (setupFeedsAndConfig publishes feeds.json). It does NO provider/WS work: live
// valuation reads the updater-maintained fresh on-chain feed, and the settlement price
// comes from the updater's shared snapshot.json. One stream, the updater's.
import { readFileSync } from "node:fs";

import { CADENCES } from "./predictConfig.js";
import { type Feeds, bootstrapPool, createMarket, isoSec, setupFeedsAndConfig } from "./predictSetup.js";
import {
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
  clockTimestampMs,
  executeAndWait,
  keeperFlushTx,
  keeperLiquidateTx,
  rebalanceExpiryCashTx,
} from "./runtime.js";

const CADENCE = Number(process.env.KEEPER_CADENCE ?? 0); // default 1m (fast roll)
const WINDOW = Number(CADENCES[CADENCE].windowSize); // markets to keep ahead of now
const TICK_MS = Number(process.env.KEEPER_TICK_MS ?? 15_000);
const DURATION_MS = Number(process.env.DURATION_MS ?? 0); // 0 = until killed
const SNAPSHOT_PATH = `${process.env.INSTANCE_DIR}/snapshot.json`;
const LIQ_BUDGET = 24n; // trade_liquidation_budget

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

interface Market {
  id: string;
  expiryMs: number;
  settled: boolean;
}

// Latest spot the updater pushed (1e9), from the shared snapshot. Used as the settlement
// price for a just-expired market (≈ price at expiry, within one tick).
function settlementSpot1e9(): bigint | null {
  try {
    return BigInt(JSON.parse(readFileSync(SNAPSHOT_PATH, "utf8")).spot1e9);
  } catch {
    return null;
  }
}

async function tick(feeds: Feeds, lifecycleCapId: string, markets: Market[]) {
  const clock = Number(await clockTimestampMs());
  const active = markets.filter((m) => !m.settled);
  const expired = active.filter((m) => m.expiryMs <= clock);
  const live = active.filter((m) => m.expiryMs > clock);

  // 1. Flush + settle (when a market has expired): insert each terminal obs so the flush
  //    settles + sweeps it (cash back to pool); live markets are valued on the updater
  //    feed. One flush values EVERY active market.
  if (expired.length) {
    const spot = settlementSpot1e9();
    if (spot == null) {
      console.warn("[keeper] no updater snapshot yet; deferring settlement one tick");
    } else {
      const settlements = expired.map((m) => ({ expiryMs: BigInt(m.expiryMs), price: spot }));
      await executeAndWait(
        keeperFlushTx({ feeds, marketIds: active.map((m) => m.id), settlements, poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId }),
        "flush+settle",
      );
      expired.forEach((m) => (m.settled = true));
      console.log(`[keeper] settled+compacted ${expired.length} market(s): ${expired.map((m) => isoSec(m.expiryMs)).join(", ")}`);
    }
  }

  // 2. Liquidate live markets (bounded; a no-op without under-floor leveraged orders).
  if (live.length) {
    await executeAndWait(
      keeperLiquidateTx({ feeds, markets: live.map((m) => m.id), protocolConfigId: PROTOCOL_CONFIG_ID, budget: LIQ_BUDGET }),
      "liquidate",
    );
  }

  // 3. Roll: keep WINDOW markets ahead of now, funding each as a separate tx right after
  //    creation (a just-created shared object can't be a later input in the SAME PTB).
  const liveCount = markets.filter((m) => !m.settled && m.expiryMs > clock).length;
  if (liveCount < WINDOW) {
    const { marketId, expiryMs } = await createMarket(lifecycleCapId, CADENCE);
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
  console.log("[keeper] bootstrapped (PLP minted, feeds.json published); rolling markets...");

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
