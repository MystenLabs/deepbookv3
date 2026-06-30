// Strategy runner. A dedicated trader address (the keeper funds it with DUSDC, since the
// publisher owns the cap) runs ONE strategy module, selected by the STRATEGY env. The runner
// owns submit + account funding + the op counter; the strategy decides what to do each tick.
// It ticks on the strategy's pace until the strategy's maxOps (run-to-completion) or
// DURATION_MS. Run one process per trader address. Default strategy "fuzz" = the original
// behavior, so `up` / `up-many` are unchanged.
import { readFileSync } from "node:fs";

import { getSignerForAddress } from "./env.js";
import { makeContext } from "./strategy.js";
import { getStrategy } from "./strategies/index.js";
import { appendTrace, errorTag } from "./trace.js";
import {
  DUSDC_TYPE,
  client,
  createAccountTx,
  depositOwnedCoinTx,
  deriveAccountWrapperId,
  readPlpBalance,
} from "./runtime.js";

const TRADER_ADDRESS = process.env.TRADER_ADDRESS ?? "";
const INSTANCE_DIR = process.env.INSTANCE_DIR ?? ".";
const DURATION_MS = Number(process.env.DURATION_MS ?? 0);
const STRATEGY = process.env.STRATEGY ?? "fuzz";
const LABEL = TRADER_ADDRESS.slice(0, 8);
const GAS_BUDGET = 2_000_000_000;

const signer = getSignerForAddress(TRADER_ADDRESS);
const wrapperId = deriveAccountWrapperId(TRADER_ADDRESS);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const readJson = (p: string): any => {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};

async function submit(tx: any, label: string): Promise<any> {
  tx.setSender(TRADER_ADDRESS);
  tx.setGasBudget(GAS_BUDGET);
  const r = await client.signAndExecuteTransaction({ transaction: tx, signer, options: { showEffects: true, showEvents: true } });
  if (r.effects?.status?.status !== "success") throw new Error(`${label}: ${JSON.stringify(r.effects?.status)}`);
  return r;
}

async function waitForFeeds(): Promise<any> {
  for (let i = 0; i < 120; i++) {
    const f = readJson(`${INSTANCE_DIR}/feeds.json`);
    if (f) return f;
    await sleep(1000);
  }
  throw new Error("feeds.json not available within 120s");
}

async function fundAndSetup(): Promise<void> {
  await submit(createAccountTx(), "create-account");
  // Wait for the keeper to transfer DUSDC to this address, then deposit it.
  for (let i = 0; i < 120; i++) {
    const coins = await client.getCoins({ owner: TRADER_ADDRESS, coinType: DUSDC_TYPE });
    if (coins.data.length > 0) {
      await submit(depositOwnedCoinTx(wrapperId, coins.data[0].coinObjectId), "deposit");
      return;
    }
    await sleep(1000);
  }
  throw new Error("trader not funded with DUSDC by the keeper within 120s");
}

async function main() {
  const strategy = getStrategy(STRATEGY);
  console.log(`[trader ${LABEL}] strategy=${strategy.name} tick=${strategy.tickMs}ms maxOps=${strategy.maxOps || "∞"}`);
  const feeds = await waitForFeeds();
  await fundAndSetup();
  console.log(`[trader ${LABEL}] account funded; running ${strategy.name}...`);

  const ctx = makeContext({
    feeds, instanceDir: INSTANCE_DIR, wrapperId, label: LABEL, strategyName: strategy.name,
    submit, readPlpBalance, traderAddress: TRADER_ADDRESS,
  });
  let ops = 0;
  let skips = 0;
  const deadline = DURATION_MS > 0 ? Date.now() + DURATION_MS : 0;
  for (;;) {
    try {
      const action = await strategy.tick(ctx);
      if (action) {
        ops++;
        if (ops % 25 === 0) console.log(`[trader ${LABEL}] ${ops} ops (${strategy.name}), ${ctx.held.length} open`);
      } else {
        skips++;
      }
    } catch (e) {
      skips++; // expired markets / transient races are expected
      ctx.trace({ type: "fail", tag: errorTag(e) });
      if (skips % 25 === 0) console.warn(`[trader ${LABEL}] skip: ${e instanceof Error ? e.message.slice(0, 90) : e}`);
    }
    if (strategy.maxOps > 0 && ops >= strategy.maxOps) break; // run-to-completion
    if (deadline && Date.now() >= deadline) break;
    await sleep(strategy.tickMs);
  }
  console.log(`[trader ${LABEL}] done — ${ops} ops (${strategy.name})`);
}

main().then(() => process.exit(0)).catch((e) => {
  appendTrace(LABEL, { strategy: STRATEGY, type: "fail", tag: errorTag(e), fatal: true });
  console.error(`[trader ${LABEL}] FAIL:`, e);
  process.exit(1);
});
