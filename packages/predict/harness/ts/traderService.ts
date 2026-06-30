// Fuzz trade generator. A dedicated trader address (the keeper funds it with DUSDC,
// since the publisher owns the cap) issues random FEASIBLE semantic mints + periodic
// live redeems against the keeper's live markets, pricing off the updater's shared
// snapshot. One stream (the updater's): the trader does no provider/WS work. Run one
// process per trader address.
import { readFileSync } from "node:fs";

import { getSignerForAddress } from "./env.js";
import { RESOLVER_MARKET } from "./predictConfig.js";
import { type Instruction, resolveMint } from "./resolver.js";
import { appendTrace, errorTag, gasOf } from "./trace.js";
import {
  DUSDC_TYPE,
  PROTOCOL_CONFIG_ID,
  client,
  createAccountTx,
  depositOwnedCoinTx,
  deriveAccountWrapperId,
  mintTx,
  redeemTx,
} from "./runtime.js";

const TRADER_ADDRESS = process.env.TRADER_ADDRESS ?? "";
const INSTANCE_DIR = process.env.INSTANCE_DIR ?? ".";
const DURATION_MS = Number(process.env.DURATION_MS ?? 0);
const TICK_MS = Number(process.env.TRADER_TICK_MS ?? 4000);
const LABEL = TRADER_ADDRESS.slice(0, 8);
const SCALE = 1_000_000_000n;
const GAS_BUDGET = 2_000_000_000;
const ADMISSION_K = 0.2;
const ADVERSARIAL_FRACTION = 0.2; // fraction of mints that probe the rejection paths

const signer = getSignerForAddress(TRADER_ADDRESS);
const wrapperId = deriveAccountWrapperId(TRADER_ADDRESS);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const rand = (lo: number, hi: number) => lo + Math.random() * (hi - lo);
const pick = <T>(a: T[]): T => a[Math.floor(Math.random() * a.length)];
const readJson = (p: string): any => {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};
// Admission cap (mirrors the contract): leverage <= 1 + (Lmax-1)*p(1+k)/(p+k). Fuzzing
// leverage in [1, cap] keeps every mint feasible by construction.
const leverageCap = (p: number) =>
  1 + (RESOLVER_MARKET.maxAdmissionLeverage - 1) * ((p * (1 + ADMISSION_K)) / (p + ADMISSION_K));

async function submit(tx: any, label: string): Promise<any> {
  tx.setSender(TRADER_ADDRESS);
  tx.setGasBudget(GAS_BUDGET);
  const r = await client.signAndExecuteTransaction({ transaction: tx, signer, options: { showEffects: true, showEvents: true } });
  if (r.effects?.status?.status !== "success") throw new Error(`${label}: ${JSON.stringify(r.effects?.status)}`);
  return r;
}

interface Held {
  orderId: string;
  marketId: string;
  quantity: bigint;
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

// Send a deliberately-rejectable mint to exercise a guard. Trace the abort (a guard firing
// = expected) or, if it wrongly succeeds, an "adversarial-accepted" finding (a guard gap).
async function adversarialProbe(feeds: any, market: { id: string }, env: any, direction: "UP" | "DN"): Promise<null> {
  const mode = pick(["over-cap-leverage", "tight-max-cost", "tight-max-probability"]);
  const p = rand(0.25, 0.7);
  const base: Instruction = { direction, leverage: rand(1, leverageCap(p)), targetProbability: p, spendUsd: rand(10, 200) };
  const r = resolveMint(base, env, RESOLVER_MARKET);
  if (!r.feasible) return null; // couldn't build a base order this tick
  let leverage = r.leverage1e9;
  let maxCost = r.maxCost;
  let maxProbability = r.maxProbability1e9;
  // Exceed the MAX possible admission cap (the cap tops out at maxAdmissionLeverage as
  // p->1), so the probe is always genuinely over-cap regardless of the resolved strike's p.
  if (mode === "over-cap-leverage") leverage = BigInt(Math.round(RESOLVER_MARKET.maxAdmissionLeverage * rand(1.5, 3) * 1e9));
  else if (mode === "tight-max-cost") maxCost = r.maxCost / 3n; // below net_premium
  else maxProbability = r.maxProbability1e9 / 3n; // below the quoted probability
  try {
    await submit(
      mintTx({
        expiryMarketId: market.id, wrapperId, protocolConfigId: PROTOCOL_CONFIG_ID, ...feeds,
        strike: BigInt(Math.round(r.strikeUsd)) * SCALE, isUp: direction === "UP",
        quantity: r.quantity, leverage, maxCost, maxProbability,
      }),
      "adv-mint",
    );
    appendTrace(LABEL, { type: "adversarial-accepted", mode, market: market.id.slice(0, 10) });
  } catch (e) {
    appendTrace(LABEL, { type: "fail", adversarial: mode, tag: errorTag(e) });
  }
  return null;
}

async function trade(feeds: any, held: Held[]): Promise<"mint" | "redeem" | null> {
  const markets = readJson(`${INSTANCE_DIR}/markets.json`);
  const snap = readJson(`${INSTANCE_DIR}/snapshot.json`);
  if (!markets?.length || !snap) return null;

  // 30% of the time, redeem a held order whose market is still live.
  if (held.length && Math.random() < 0.3) {
    const idx = Math.floor(Math.random() * held.length);
    const h = held[idx];
    if (!markets.some((m: any) => m.id === h.marketId)) {
      held.splice(idx, 1); // market settled; drop (the settled payout stays in escrow)
      return null;
    }
    const rr = await submit(redeemTx({ expiryMarketId: h.marketId, wrapperId, protocolConfigId: PROTOCOL_CONFIG_ID, ...feeds, orderId: h.orderId, closeQuantity: h.quantity }), "redeem");
    held.splice(idx, 1);
    appendTrace(LABEL, { type: "redeem", market: h.marketId.slice(0, 10), gas: gasOf(rr) });
    return "redeem";
  }

  // Otherwise mint a fuzzed position into a random live market.
  const market = pick(markets) as { id: string; expiryMs: number };
  const exp = snap.expiries?.[String(market.expiryMs)];
  if (!exp) return null; // updater has not warmed this expiry yet
  const spot = Number(snap.spot1e9) / 1e9;
  const svi = { a: exp.svi.alpha, b: exp.svi.beta, rho: exp.svi.rho, m: exp.svi.m, sigma: exp.svi.sigma };
  const env = { pythSpot: spot, bsSpot: spot, bsForward: Number(exp.forward), svi };
  const direction = pick(["UP", "DN"]) as "UP" | "DN";

  // A fraction of trades probe the REJECTION paths (admission + P6 slippage guards) with a
  // deliberately-invalid order. The guard firing (abort) is the expected healthy outcome.
  if (Math.random() < ADVERSARIAL_FRACTION) return adversarialProbe(feeds, market, env, direction);

  const targetProbability = rand(0.1, 0.9);
  const leverage = rand(1, leverageCap(targetProbability));
  const inst: Instruction = { direction, leverage, targetProbability, spendUsd: rand(10, 300) };
  const r = resolveMint(inst, env, RESOLVER_MARKET);
  if (!r.feasible) return null;
  const res = await submit(
    mintTx({
      expiryMarketId: market.id, wrapperId, protocolConfigId: PROTOCOL_CONFIG_ID, ...feeds,
      strike: BigInt(Math.round(r.strikeUsd)) * SCALE, isUp: direction === "UP", quantity: r.quantity, leverage: r.leverage1e9,
      maxCost: r.maxCost, maxProbability: r.maxProbability1e9,
    }),
    "mint",
  );
  const ev = res.events?.find((e: any) => e.type?.includes("OrderMinted"));
  if (ev) held.push({ orderId: ev.parsedJson.order_id, marketId: market.id, quantity: r.quantity });
  appendTrace(LABEL, {
    type: "mint", market: market.id.slice(0, 10), direction, moneyness: r.strikeUsd / spot,
    prob: r.predictedProbability, leverage: inst.leverage,
    netPremium: ev ? Number(ev.parsedJson.net_premium) / 1e6 : 0, gas: gasOf(res),
  });
  return "mint";
}

async function main() {
  console.log(`[trader ${LABEL}] starting (tick=${TICK_MS}ms)`);
  const feeds = await waitForFeeds();
  await fundAndSetup();
  console.log(`[trader ${LABEL}] account funded; trading...`);

  const held: Held[] = [];
  let mints = 0;
  let redeems = 0;
  let skips = 0;
  const deadline = DURATION_MS > 0 ? Date.now() + DURATION_MS : 0;
  for (;;) {
    try {
      const action = await trade(feeds, held);
      if (action === "mint") mints++;
      else if (action === "redeem") redeems++;
      else skips++;
      if ((mints + redeems) > 0 && (mints + redeems) % 10 === 0)
        console.log(`[trader ${LABEL}] ${mints} mints, ${redeems} redeems, ${held.length} open`);
    } catch (e) {
      skips++; // expired markets / transient races are expected
      appendTrace(LABEL, { type: "fail", tag: errorTag(e) });
      if (skips % 25 === 0) console.warn(`[trader ${LABEL}] skip: ${e instanceof Error ? e.message.slice(0, 90) : e}`);
    }
    if (deadline && Date.now() >= deadline) break;
    await sleep(TICK_MS);
  }
  console.log(`[trader ${LABEL}] done — ${mints} mints, ${redeems} redeems`);
}

main().then(() => process.exit(0)).catch((e) => { console.error(`[trader ${LABEL}] FAIL:`, e); process.exit(1); });
