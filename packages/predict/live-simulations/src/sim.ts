// Live random-trade simulation against the deployed testnet predict stack.
//
// Acts as the deployer's canonical account: it mints/redeems binary positions and
// supplies LP at randomized parameters around the live Pyth spot, recording per-action
// gas. Serves as an end-to-end integration test (it touches the real oracle, account,
// and pool flows). Withdraw is intentionally out of scope: PLP is delivered to the
// account only at a privileged pool flush (cron), which this sim does not drive.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import {
  client,
  getSigner,
  PYTH_FEED_ID,
  BLOCK_SCHOLES_FEED_ID,
  DUSDC_TYPE,
  TICK_SIZE,
  POS_INF_TICK,
  POSITION_LOT_SIZE,
  FLOAT_SCALING,
  MARKETS,
} from "./config";
import { createAccountTx, depositTx, mintTx, redeemTx, requestSupplyTx } from "./actions";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ITERATIONS = Number(process.env.ITERATIONS ?? 16);
const STATE_FILE = path.resolve(HERE, "..", "state.testnet.json");
const RESULTS_FILE = path.resolve(HERE, "..", "results.testnet.json");
const DUSDC = (n: number) => BigInt(Math.round(n * 1_000_000)); // 6 decimals
const ACCOUNT_FUNDING = DUSDC(50_000); // one-time deposit into the trader account

const { keypair, address } = getSigner();

type State = { wrapperId?: string; funded?: boolean };
const loadState = (): State => (existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, "utf8")) : {});
const saveState = (s: State) => writeFileSync(STATE_FILE, JSON.stringify(s, null, 2) + "\n");

interface ExecResult {
  ok: boolean;
  status: string;
  digest: string;
  gas: { computation: bigint; storage: bigint; rebate: bigint; net: bigint };
  events: any[];
  objectChanges: any[];
  error?: string;
}

const ZERO_GAS = { computation: 0n, storage: 0n, rebate: 0n, net: 0n };

async function exec(tx: any): Promise<ExecResult> {
  try {
    const r = await client.signAndExecuteTransaction({
      signer: keypair,
      transaction: tx,
      options: { showEffects: true, showEvents: true, showObjectChanges: true },
    });
    const g = (r.effects?.gasUsed ?? {}) as any;
    const computation = BigInt(g.computationCost ?? 0);
    const storage = BigInt(g.storageCost ?? 0);
    const rebate = BigInt(g.storageRebate ?? 0);
    const status = r.effects?.status?.status ?? "unknown";
    return {
      ok: status === "success",
      status,
      digest: r.digest,
      gas: { computation, storage, rebate, net: computation + storage - rebate },
      events: r.events ?? [],
      objectChanges: r.objectChanges ?? [],
      error: r.effects?.status?.error,
    };
  } catch (e: any) {
    return { ok: false, status: "error", digest: "", gas: ZERO_GAS, events: [], objectChanges: [], error: String(e?.message ?? e) };
  }
}

// Pre-validate a tx without committing. Returns true if it would succeed on-chain.
async function dryOk(tx: any): Promise<boolean> {
  try {
    const r = await client.devInspectTransactionBlock({ sender: address, transactionBlock: tx });
    return (r.effects?.status?.status ?? "failure") === "success";
  } catch {
    return false;
  }
}

async function largestDusdcCoin(): Promise<string> {
  const { data } = await client.getCoins({ owner: address, coinType: DUSDC_TYPE });
  if (!data.length) throw new Error("deployer holds no DUSDC");
  return data.sort((a, b) => Number(BigInt(b.balance) - BigInt(a.balance)))[0].coinObjectId;
}

/** Read the live Pyth spot, normalized to 1e9 scaling, then the ATM strike tick. */
async function atmTick(): Promise<bigint> {
  const obj = await client.getObject({ id: PYTH_FEED_ID, options: { showContent: true } });
  const v = (obj.data?.content as any).fields.lane.fields.latest.fields.value.fields;
  const mag = BigInt(v.price_magnitude);
  const exp = Number(v.exponent_magnitude) * (v.exponent_is_negative ? -1 : 1);
  const scale = 9 + exp; // normalize to 1e9: mag * 10^(9 - exponent_magnitude) for negative exp
  const normalized = scale >= 0 ? mag * 10n ** BigInt(scale) : mag / 10n ** BigInt(-scale);
  return normalized / TICK_SIZE;
}

function findEvent(events: any[], suffix: string): any | undefined {
  return events.find((e) => String(e.type).endsWith(suffix))?.parsedJson;
}
function optionValue(v: any): string | undefined {
  if (v == null) return undefined;
  if (typeof v === "string") return v;
  if (Array.isArray(v)) return v[0];
  if (v.vec) return v.vec[0];
  return undefined;
}

const rand = (n: number) => Math.floor(Math.random() * n);

interface OpenOrder { orderId: string; marketId: string; remaining: bigint }

async function setup(state: State): Promise<string> {
  if (!state.wrapperId) {
    console.log("setup: creating account wrapper ...");
    const r = await exec(createAccountTx());
    if (!r.ok) throw new Error(`createAccount failed: ${r.error}`);
    const created = r.objectChanges.find((c) => c.type === "created" && String(c.objectType).includes("::account::AccountWrapper"));
    if (!created) throw new Error("AccountWrapper not found in objectChanges");
    state.wrapperId = (created as any).objectId;
    saveState(state);
    console.log(`  wrapper = ${state.wrapperId}`);
  } else {
    console.log(`setup: reusing wrapper ${state.wrapperId}`);
  }
  const wrapperId = state.wrapperId!;
  if (!state.funded) {
    console.log(`setup: depositing ${ACCOUNT_FUNDING} DUSDC units into account ...`);
    const coin = await largestDusdcCoin();
    const r = await exec(depositTx(wrapperId, coin, ACCOUNT_FUNDING));
    if (!r.ok) throw new Error(`deposit failed: ${r.error}`);
    state.funded = true;
    saveState(state);
    console.log(`  funded (gas net ${r.gas.net})`);
  }
  return wrapperId;
}

interface Stat { count: number; ok: number; fail: number; nets: bigint[]; errors: string[] }
const stats: Record<string, Stat> = {};
function record(action: string, r: ExecResult) {
  const s = (stats[action] ??= { count: 0, ok: 0, fail: 0, nets: [], errors: [] });
  s.count++;
  if (r.ok) {
    s.ok++;
    s.nets.push(r.gas.net);
  } else {
    s.fail++;
    if (r.error && s.errors.length < 3) s.errors.push(r.error.slice(0, 140));
  }
}

async function main() {
  console.log(`live-sim: deployer ${address}, ${ITERATIONS} iterations`);
  if (!MARKETS.length) throw new Error("no markets in deployment.testnet.json");
  // Pick the soonest FUTURE market: only markets whose expiry the price-pusher still keeps a
  // fresh Block Scholes surface for are mintable, and the nearest future one is in that window.
  const nowMs = BigInt(Date.now());
  const tradeable = MARKETS.filter((m) => m.expiry > nowMs).sort((a, b) => (a.expiry < b.expiry ? -1 : 1));
  if (!tradeable.length) throw new Error("no future market in deployment.testnet.json");
  const market = tradeable[0];
  console.log(`market ${market.id} (expiry ${market.expiry}, ~${Number((market.expiry - nowMs) / 60000n)}min out)`);

  const state = loadState();
  const wrapperId = await setup(state);
  const open: OpenOrder[] = [];

  for (let i = 0; i < ITERATIONS; i++) {
    // Weighted action choice: favor minting, redeem when we hold positions.
    const roll = rand(10);
    let action: string;
    if (open.length > 0 && roll < 4) action = "redeem";
    else if (roll < 8) action = "mint";
    else action = "supply";

    if (action === "mint") {
      const atm = await atmTick();
      const isUp = rand(2) === 0;
      const sign = rand(2) === 0 ? 1n : -1n;
      // Quantity must clear min_net_premium (1 DUSDC): net_premium = entry_prob * qty / leverage,
      // so at ~0.3 prob and 1x we need qty >= ~3.3e6. Use hundreds of lots.
      const quantity = BigInt(200 + rand(800)) * POSITION_LOT_SIZE; // 2e6 .. 1e7
      // Strikes near ATM keep entry_probability inside [min_ask, max_ask]. For a short expiry the
      // band is tight, so start within ~200 ticks and shrink toward ATM until devInspect prices it.
      let offset = BigInt(5 + rand(195));
      let tx: any = null;
      let strikeTick = atm;
      for (let attempt = 0; attempt < 8; attempt++) {
        strikeTick = atm + sign * offset;
        if (strikeTick < 1n) strikeTick = 1n;
        if (strikeTick >= POS_INF_TICK) strikeTick = POS_INF_TICK - 1n;
        const candidate = mintTx({
          marketId: market.id, wrapperId, pythFeedId: PYTH_FEED_ID, bsFeedId: BLOCK_SCHOLES_FEED_ID,
          lowerTick: isUp ? strikeTick : 0n, higherTick: isUp ? POS_INF_TICK : strikeTick, quantity, leverage: FLOAT_SCALING,
        });
        if (await dryOk(candidate)) { tx = candidate; break; }
        offset = offset / 2n;
        if (offset === 0n) { offset = 0n; }
      }
      const r = tx ? await exec(tx) : { ok: false, status: "skipped", digest: "", gas: ZERO_GAS, events: [], objectChanges: [], error: "no in-band strike found (devInspect)" };
      record("mint", r);
      const m = r.ok ? findEvent(r.events, "::order_events::OrderMinted") : undefined;
      if (m) open.push({ orderId: m.order_id, marketId: market.id, remaining: BigInt(m.quantity) });
      console.log(`[${i}] mint ${isUp ? "UP" : "DOWN"} strike_tick=${strikeTick} qty=${quantity} -> ${r.ok ? "ok" : "FAIL"} gas=${r.gas.net}${r.ok ? "" : " " + r.error}`);
    } else if (action === "redeem") {
      const idx = rand(open.length);
      const o = open[idx];
      const closeFull = rand(2) === 0 || o.remaining <= POSITION_LOT_SIZE;
      const closeQty = closeFull ? o.remaining : BigInt(1 + rand(Number(o.remaining / POSITION_LOT_SIZE) - 1 || 1)) * POSITION_LOT_SIZE;
      const r = await exec(redeemTx({ marketId: o.marketId, wrapperId, pythFeedId: PYTH_FEED_ID, bsFeedId: BLOCK_SCHOLES_FEED_ID, orderId: o.orderId, closeQuantity: closeQty }));
      record("redeem", r);
      if (r.ok) {
        const ev = findEvent(r.events, "::order_events::LiveOrderRedeemed");
        const remaining = ev ? BigInt(ev.remaining_quantity) : 0n;
        const replacement = ev ? optionValue(ev.replacement_order_id) : undefined;
        if (remaining === 0n) open.splice(idx, 1);
        else open[idx] = { ...o, remaining, orderId: replacement ?? o.orderId };
      }
      console.log(`[${i}] redeem order=${o.orderId.slice(0, 10)} qty=${closeQty} -> ${r.ok ? "ok" : "FAIL"} gas=${r.gas.net}${r.ok ? "" : " " + r.error}`);
    } else {
      const amount = DUSDC(100 + rand(900));
      const r = await exec(requestSupplyTx(wrapperId, amount));
      record("supply", r);
      console.log(`[${i}] supply ${amount} -> ${r.ok ? "ok" : "FAIL"} gas=${r.gas.net}${r.ok ? "" : " " + r.error}`);
    }
  }

  // === Summary ===
  console.log("\n=== gas summary (net MIST) ===");
  const summary: any = { network: "testnet", iterations: ITERATIONS, market: market.id, perAction: {} };
  for (const [action, s] of Object.entries(stats)) {
    const nets = s.nets.slice().sort((a, b) => Number(a - b));
    const avg = nets.length ? nets.reduce((a, b) => a + b, 0n) / BigInt(nets.length) : 0n;
    const row = { count: s.count, ok: s.ok, fail: s.fail, gasMin: nets[0]?.toString() ?? null, gasAvg: avg.toString(), gasMax: nets[nets.length - 1]?.toString() ?? null, sampleErrors: s.errors };
    summary.perAction[action] = row;
    console.log(`  ${action.padEnd(8)} n=${s.count} ok=${s.ok} fail=${s.fail} gas[min/avg/max]=${row.gasMin}/${row.gasAvg}/${row.gasMax}`);
    if (s.errors.length) console.log(`           e.g. ${s.errors[0]}`);
  }
  writeFileSync(RESULTS_FILE, JSON.stringify(summary, null, 2) + "\n");
  console.log(`\nresults -> ${RESULTS_FILE}`);
  console.log(`open positions left: ${open.length}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
