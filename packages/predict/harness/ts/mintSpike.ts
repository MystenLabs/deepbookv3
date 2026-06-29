// B1 spike: first end-to-end semantic trade.
//
// Against an oracle-ready localnet (harness `oracle_ready_localnet` brought it up),
// stand up the Predict layer for one market and execute a resolver-driven mint:
//   feeds + trusted signer -> protocol/cadence config -> create market + seed
//   -> trader account + pool funding + rebalance -> resolve "2x UP @ ~30c" -> mint.
//
// The mint PTB refreshes the oracle with the SAME snapshot the resolver priced
// against, so on-chain pricing matches the off-chain selection (only math drift).
import { PythLazerClient } from "@pythnetwork/pyth-lazer-sdk";
import WebSocket from "ws";

import { readFileSync } from "node:fs";

import { type Svi } from "./pricer.js";
import { type Instruction, resolveMint } from "./resolver.js";
import { BOOTSTRAP_SUPPLY, CADENCES, FRESHNESS, RESOLVER_MARKET } from "./predictConfig.js";
import {
  PROTOCOL_CONFIG_ID,
  POOL_VAULT_ID,
  address,
  bindBlockScholesSurfaceToUnderlyingTx,
  bindFeedsToUnderlyingTx,
  createAccountTx,
  createBlockScholesSurfaceFeedsTx,
  createExpiryMarketTx,
  deriveAccountWrapperId,
  depositToAccountTx,
  executeAndWait,
  lockCapitalTx,
  mintLifecycleCapTx,
  rebalanceExpiryCashTx,
  refreshOracleAndFlushTx,
  refreshOracleAndMintTx,
  registerUnderlyingAndCreateFeedsTx,
  requestSupplyTx,
  seedOracleTx,
  setOracleFreshnessTx,
  setCadenceConfigTx,
  updatePythTrustedSignerTx,
} from "./runtime.js";

const HARNESS_ENV = "/Users/aslantashtanov/Desktop/Projects/deepbookv3/packages/predict/harness/.env";
const key = (name: string): string => {
  for (const line of readFileSync(HARNESS_ENV, "utf8").split("\n")) {
    const m = line.match(new RegExp(`^${name}=(.*)$`));
    if (m) return m[1].trim().replace(/^["']|["']$/g, "");
  }
  throw new Error(`missing ${name}`);
};
const PYTH_TOKEN = key("PYTH_PRO_API_KEY");
const BS_KEY = key("BLOCK_SCHOLES_API_KEY");

const SCALE = 1_000_000_000n;
const DUSDC = 1_000_000n; // DUSDC decimals (1e6)
const CADENCE_1H = 2;
const to1e9 = (x: number) => BigInt(Math.round(x * 1e9));
const isoSec = (ms: number) => new Date(ms).toISOString().slice(0, 19) + "Z";
const found = (b: any, t: string) => {
  const c = b.objectChanges?.find((ch: any) => ch.type === "created" && ch.objectType?.includes(t));
  if (!c) throw new Error(`no created ${t}`);
  return c.objectId as string;
};
const eventField = (b: any, name: string, field: string): string => {
  const ev = b.events?.find((e: any) => e.type?.includes(name));
  if (!ev) throw new Error(`no ${name} event`);
  return ev.parsedJson[field];
};

interface Snap { pythSpot: number; bsForward: number; svi: Svi }

// One-shot: fetch real Pyth spot + BS forward/SVI for `expiryMs`.
function fetchSnapshot(expiryMs: number, timeoutMs = 70_000): Promise<Snap> {
  return new Promise((resolve, reject) => {
    const out: Partial<Snap> = {};
    const timer = setTimeout(() => reject(new Error("snapshot timeout (cold expiry?)")), timeoutMs);
    const tryDone = () => {
      if (out.pythSpot != null && out.bsForward != null && out.svi) {
        clearTimeout(timer);
        ws.close();
        pyth.then((c) => c.shutdown());
        resolve(out as Snap);
      }
    };
    const pyth = PythLazerClient.create({
      token: PYTH_TOKEN,
      webSocketPoolConfig: { urls: ["wss://pyth-lazer.dourolabs.app/v1/stream"], numConnections: 1 },
    });
    pyth.then((c) => {
      c.addMessageListener((ev: any) => {
        if (ev.type !== "binary" || !ev.value.parsed) return;
        const f = ev.value.parsed.priceFeeds?.[0];
        if (f?.price == null) return;
        out.pythSpot = Number(f.price) * 10 ** (Number(f.exponent ?? -8));
        tryDone();
      });
      c.subscribe({
        type: "subscribe", subscriptionId: 1, priceFeedIds: [1],
        properties: ["price", "exponent"], formats: ["leEcdsa"], deliveryFormat: "binary",
        parsed: true, channel: "fixed_rate@200ms",
      });
    }).catch(reject);

    const ws = new WebSocket("wss://prod-websocket-api.blockscholes.com/");
    const fmt = { timestamp: "ms", hexify: false, decimals: 9 };
    const expiry = isoSec(expiryMs);
    ws.on("open", () => ws.send(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "authenticate", params: { api_key: BS_KEY } })));
    ws.on("message", (raw) => {
      let f: any; try { f = JSON.parse(String(raw)); } catch { return; }
      if (f.result === "ok") {
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: 2, method: "subscribe", params: [{ frequency: "1000ms", client_id: "fwd", batch: [{ sid: "fwd", feed: "mark.px", asset: "future", base_asset: "BTC", expiry }], options: { format: fmt } }] }));
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: 3, method: "subscribe", params: [{ frequency: "1000ms", retransmit_frequency: "1000ms", client_id: "svi", batch: [{ sid: "svi", feed: "model.params", exchange: "composite", asset: "option", base_asset: "BTC", model: "SVI", expiry }], options: { format: fmt } }] }));
        return;
      }
      if (f.method !== "subscription") return;
      for (const entry of (Array.isArray(f.params) ? f.params : [f.params])) for (const v of entry?.data?.values || []) {
        if (v.sid === "fwd" && Number.isFinite(Number(v.v))) out.bsForward = Number(v.v);
        else if (v.sid === "svi") out.svi = { a: +v.alpha || 0, b: +v.beta || 0, rho: +v.rho || 0, m: +v.m || 0, sigma: +v.sigma || 0 };
      }
      tryDone();
    });
    ws.on("error", reject);
  });
}

function refreshParams(feeds: any, expiryMs: bigint, snap: Snap) {
  return {
    ...feeds,
    expiry: expiryMs,
    spot: to1e9(snap.pythSpot),
    forward: to1e9(snap.bsForward),
    svi: {
      a: to1e9(snap.svi.a), b: to1e9(snap.svi.b), sigma: to1e9(snap.svi.sigma),
      rho: to1e9(Math.abs(snap.svi.rho)), rhoNegative: snap.svi.rho < 0,
      m: to1e9(Math.abs(snap.svi.m)), mNegative: snap.svi.m < 0,
    },
  };
}

async function main() {
  // 1. Oracle feeds + trusted signer.
  await executeAndWait(updatePythTrustedSignerTx(), "trusted-signer");
  const feedsR = await executeAndWait(registerUnderlyingAndCreateFeedsTx(1), "feeds");
  const pythFeedId = found(feedsR, "pyth_feed::PythFeed");
  const bsSpotFeedId = found(feedsR, "block_scholes_spot_feed::BlockScholesSpotFeed");
  await executeAndWait(bindFeedsToUnderlyingTx({ pythFeedId, bsSpotFeedId }), "bind-spot");
  const surfR = await executeAndWait(createBlockScholesSurfaceFeedsTx(), "surface");
  const bsForwardFeedId = found(surfR, "block_scholes_forward_feed::BlockScholesForwardFeed");
  const bsSviFeedId = found(surfR, "block_scholes_svi_feed::BlockScholesSVIFeed");
  await executeAndWait(bindBlockScholesSurfaceToUnderlyingTx({ bsForwardFeedId, bsSviFeedId }), "bind-surface");
  const feeds = { pythFeedId, bsSpotFeedId, bsForwardFeedId, bsSviFeedId };

  // 2. Predict-layer config from the testnet-aligned map. Cadence has no default (must
  // set); freshness is the one knob testnet loosened from default; everything else (fees,
  // ltv, max leverage) matches the contract default the market snapshots on creation.
  const cap = await executeAndWait(mintLifecycleCapTx(address), "lifecycle-cap");
  const lifecycleCapId = found(cap, "MarketLifecycleCap");
  await executeAndWait(setCadenceConfigTx({ cadenceId: CADENCE_1H, ...CADENCES[CADENCE_1H] }), "cadence");
  await executeAndWait(
    setOracleFreshnessTx(PROTOCOL_CONFIG_ID, FRESHNESS.pythSpotMs, FRESHNESS.blockScholesPriceMs, FRESHNESS.blockScholesSviMs),
    "freshness",
  );

  // 3. Create the 1h market (its expiry lands on the updater's warm grid).
  const mkR = await executeAndWait(createExpiryMarketTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId, cadenceId: CADENCE_1H }), "create-market");
  const expiryMarketId = found(mkR, "ExpiryMarket");
  const expiryMs = BigInt(eventField(mkR, "MarketCreated", "expiry"));
  console.log(`[spike] market ${expiryMarketId.slice(0, 10)} expiry=${isoSec(Number(expiryMs))}`);

  // 4. Live snapshot for that expiry.
  console.log("[spike] fetching live snapshot...");
  const snap = await fetchSnapshot(Number(expiryMs));
  console.log(`[spike] snapshot: spot=$${snap.pythSpot.toFixed(0)} forward=$${snap.bsForward.toFixed(0)} svi.b=${snap.svi.b}`);
  await executeAndWait(await seedOracleTx(refreshParams(feeds, expiryMs, snap)), "seed");

  // 5. Trader account + pool funding + rebalance (market mintable).
  const wrapperId = deriveAccountWrapperId(address);
  await executeAndWait(createAccountTx(), "create-account");
  await executeAndWait(depositToAccountTx(wrapperId, 1_000_000n * DUSDC), "deposit");
  await executeAndWait(lockCapitalTx(POOL_VAULT_ID), "lock-capital");
  await executeAndWait(requestSupplyTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, wrapperId, amount: BOOTSTRAP_SUPPLY }), "supply");
  await executeAndWait(await refreshOracleAndFlushTx({ ...refreshParams(feeds, expiryMs, snap), poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId, lifecycleCapId }), "flush");
  await executeAndWait(rebalanceExpiryCashTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId, pythFeedId }), "rebalance");
  console.log("[spike] market funded + mintable");

  // 6. Resolve a semantic instruction (on-chain forward == bsForward, so resolver uses bsSpot=pythSpot).
  const mkt = RESOLVER_MARKET;
  const inst: Instruction = { direction: "UP", leverage: 2, targetProbability: 0.3, spendUsd: 100 };
  const resolved = resolveMint(inst, { pythSpot: snap.pythSpot, bsSpot: snap.pythSpot, bsForward: snap.bsForward, svi: snap.svi }, mkt);
  console.log(`[spike] resolved 2x UP @ ~30c $100 -> strike=$${resolved.strikeUsd.toFixed(0)} p=${(resolved.predictedProbability * 100).toFixed(2)}c maxPayout=$${(Number(resolved.quantity) / 1e6).toFixed(2)} feasible=${resolved.feasible}${resolved.reason ? " (" + resolved.reason + ")" : ""}`);
  if (!resolved.feasible) throw new Error("instruction infeasible: " + resolved.reason);

  // 7. Execute the mint (oracle refresh with the same snapshot + mint).
  const mintTx = await refreshOracleAndMintTx({
    ...refreshParams(feeds, expiryMs, snap),
    expiryMarketId, protocolConfigId: PROTOCOL_CONFIG_ID, wrapperId,
    strike: BigInt(Math.round(resolved.strikeUsd)) * SCALE,
    isUp: inst.direction === "UP",
    quantity: resolved.quantity,
    leverage: resolved.leverage1e9,
  });
  const mintR = await executeAndWait(mintTx, "mint");
  const orderId = eventField(mintR, "OrderMinted", "order_id");
  const netPremium = eventField(mintR, "OrderMinted", "net_premium");
  console.log(`[spike] MINTED order=${orderId} net_premium=$${(Number(netPremium) / 1e6).toFixed(2)} digest=${mintR.digest}`);
  console.log("\n=== B1 PASS: semantic instruction resolved + minted against live data ===");
}

main().then(() => process.exit(0)).catch((e) => { console.error("[spike] FAIL:", e); process.exit(1); });
