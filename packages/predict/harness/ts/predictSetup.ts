// Shared Predict-layer bring-up on an oracle-ready localnet: oracle feeds + trusted
// signer + cadence/freshness config + lifecycle cap, then create+seed a market and
// bootstrap the pool. Used by the B1 mint spike and the keeper so the multi-step
// operator sequence lives in one place.
import { PythLazerClient } from "@pythnetwork/pyth-lazer-sdk";
import WebSocket from "ws";

import { readFileSync, writeFileSync } from "node:fs";

import { type Svi } from "./pricer.js";
import { BOOTSTRAP_SUPPLY, CADENCES, FRESHNESS } from "./predictConfig.js";
import {
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
  address,
  bareFlushTx,
  bindBlockScholesSurfaceToUnderlyingTx,
  bindFeedsToUnderlyingTx,
  createAccountTx,
  createBlockScholesSurfaceFeedsTx,
  createExpiryMarketTx,
  deriveAccountWrapperId,
  executeAndWait,
  lockCapitalTx,
  mintLifecycleCapTx,
  registerUnderlyingAndCreateFeedsTx,
  requestSupplyTx,
  seedOracleTx,
  setCadenceConfigTx,
  setOracleFreshnessTx,
  updatePythTrustedSignerTx,
} from "./runtime.js";

const HARNESS_ENV = "/Users/aslantashtanov/Desktop/Projects/deepbookv3/packages/predict/harness/.env";
const readKey = (name: string): string => {
  for (const line of readFileSync(HARNESS_ENV, "utf8").split("\n")) {
    const m = line.match(new RegExp(`^${name}=(.*)$`));
    if (m) return m[1].trim().replace(/^["']|["']$/g, "");
  }
  throw new Error(`missing ${name}`);
};
const PYTH_TOKEN = readKey("PYTH_PRO_API_KEY");
const BS_KEY = readKey("BLOCK_SCHOLES_API_KEY");

export const to1e9 = (x: number) => BigInt(Math.round(x * 1e9));
export const isoSec = (ms: number) => new Date(ms).toISOString().slice(0, 19) + "Z";
export const found = (b: any, t: string): string => {
  const c = b.objectChanges?.find((ch: any) => ch.type === "created" && ch.objectType?.includes(t));
  if (!c) throw new Error(`no created ${t}`);
  return c.objectId as string;
};
export const eventField = (b: any, name: string, field: string): string => {
  const ev = b.events?.find((e: any) => e.type?.includes(name));
  if (!ev) throw new Error(`no ${name} event`);
  return ev.parsedJson[field];
};

export interface Feeds {
  pythFeedId: string;
  bsSpotFeedId: string;
  bsForwardFeedId: string;
  bsSviFeedId: string;
}
export interface Snap {
  pythSpot: number;
  bsForward: number;
  svi: Svi;
}

// One-shot: fetch real Pyth spot + BS forward/SVI for `expiryMs` (warm boundary ~1s).
export function fetchSnapshot(expiryMs: number, timeoutMs = 70_000): Promise<Snap> {
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
    pyth
      .then((c) => {
        c.addMessageListener((ev: any) => {
          if (ev.type !== "binary" || !ev.value.parsed) return;
          const f = ev.value.parsed.priceFeeds?.[0];
          if (f?.price == null) return;
          out.pythSpot = Number(f.price) * 10 ** Number(f.exponent ?? -8);
          tryDone();
        });
        c.subscribe({
          type: "subscribe", subscriptionId: 1, priceFeedIds: [1],
          properties: ["price", "exponent"], formats: ["leEcdsa"], deliveryFormat: "binary",
          parsed: true, channel: "fixed_rate@200ms",
        });
      })
      .catch(reject);

    const ws = new WebSocket("wss://prod-websocket-api.blockscholes.com/");
    const fmt = { timestamp: "ms", hexify: false, decimals: 9 };
    const expiry = isoSec(expiryMs);
    ws.on("open", () => ws.send(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "authenticate", params: { api_key: BS_KEY } })));
    ws.on("message", (raw) => {
      let f: any;
      try { f = JSON.parse(String(raw)); } catch { return; }
      if (f.result === "ok") {
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: 2, method: "subscribe", params: [{ frequency: "1000ms", client_id: "fwd", batch: [{ sid: "fwd", feed: "mark.px", asset: "future", base_asset: "BTC", expiry }], options: { format: fmt } }] }));
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: 3, method: "subscribe", params: [{ frequency: "1000ms", retransmit_frequency: "1000ms", client_id: "svi", batch: [{ sid: "svi", feed: "model.params", exchange: "composite", asset: "option", base_asset: "BTC", model: "SVI", expiry }], options: { format: fmt } }] }));
        return;
      }
      if (f.method !== "subscription") return;
      for (const entry of Array.isArray(f.params) ? f.params : [f.params])
        for (const v of entry?.data?.values || []) {
          if (v.sid === "fwd" && Number.isFinite(Number(v.v))) out.bsForward = Number(v.v);
          else if (v.sid === "svi") out.svi = { a: +v.alpha || 0, b: +v.beta || 0, rho: +v.rho || 0, m: +v.m || 0, sigma: +v.sigma || 0 };
        }
      tryDone();
    });
    ws.on("error", reject);
  });
}

// OracleRefreshParams shape from a snapshot (1e9-scaled, signed-magnitude SVI).
export function refreshParams(feeds: Feeds, expiryMs: bigint, snap: Snap) {
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

// Fast current Pyth spot only (resolves on first message) — for the settlement
// observation, where BS won't serve a past expiry's surface.
export function fetchPythSpot(timeoutMs = 15_000): Promise<number> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("pyth spot timeout")), timeoutMs);
    const pyth = PythLazerClient.create({
      token: PYTH_TOKEN,
      webSocketPoolConfig: { urls: ["wss://pyth-lazer.dourolabs.app/v1/stream"], numConnections: 1 },
    });
    pyth
      .then((c) => {
        c.addMessageListener((ev: any) => {
          if (ev.type !== "binary" || !ev.value.parsed) return;
          const f = ev.value.parsed.priceFeeds?.[0];
          if (f?.price == null) return;
          clearTimeout(timer);
          c.shutdown();
          resolve(Number(f.price) * 10 ** Number(f.exponent ?? -8));
        });
        c.subscribe({
          type: "subscribe", subscriptionId: 1, priceFeedIds: [1],
          properties: ["price", "exponent"], formats: ["leEcdsa"], deliveryFormat: "binary",
          parsed: true, channel: "fixed_rate@200ms",
        });
      })
      .catch(reject);
  });
}

// One grid entry (forward + signed-magnitude SVI in 1e9) for buildOracleRefreshGridTx.
export function gridExpiry(expiryMs: number, snap: Snap) {
  return {
    expiry: BigInt(expiryMs),
    forward: to1e9(snap.bsForward),
    svi: {
      a: to1e9(snap.svi.a), b: to1e9(snap.svi.b), sigma: to1e9(snap.svi.sigma),
      rho: to1e9(Math.abs(snap.svi.rho)), rhoNegative: snap.svi.rho < 0,
      m: to1e9(Math.abs(snap.svi.m)), mNegative: snap.svi.m < 0,
    },
  };
}

// Trusted signer + Pyth/BS feeds + bound underlying + per-cadence config + freshness
// + a lifecycle cap. Returns the feed ids and the cap needed to create/flush markets.
export async function setupFeedsAndConfig(cadenceIds: number[]): Promise<{ feeds: Feeds; lifecycleCapId: string }> {
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

  // Publish the feed ids so the updater (a separate process) can stream onto them
  // without re-running setup. The keeper is the single setup owner; the updater reads.
  const instanceDir = process.env.INSTANCE_DIR;
  if (instanceDir) writeFileSync(`${instanceDir}/feeds.json`, JSON.stringify(feeds));

  const cap = await executeAndWait(mintLifecycleCapTx(address), "lifecycle-cap");
  const lifecycleCapId = found(cap, "MarketLifecycleCap");
  for (const cadenceId of cadenceIds) {
    await executeAndWait(setCadenceConfigTx({ cadenceId, ...CADENCES[cadenceId] }), `cadence-${cadenceId}`);
  }
  await executeAndWait(
    setOracleFreshnessTx(PROTOCOL_CONFIG_ID, FRESHNESS.pythSpotMs, FRESHNESS.blockScholesPriceMs, FRESHNESS.blockScholesSviMs),
    "freshness",
  );
  return { feeds, lifecycleCapId };
}

// Create one cadence market. Reads NO oracle (absolute ticks need no grid centering),
// so a keeper with a live updater needs no per-market seed — the updater warms the feed.
export async function createMarket(
  lifecycleCapId: string,
  cadenceId: number,
): Promise<{ marketId: string; expiryMs: bigint }> {
  const mkR = await executeAndWait(
    createExpiryMarketTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId, cadenceId }),
    "create-market",
  );
  return { marketId: found(mkR, "ExpiryMarket"), expiryMs: BigInt(eventField(mkR, "MarketCreated", "expiry")) };
}

// Create + seed a market's feeds, for the standalone mint spike (no updater running).
export async function createAndSeedMarket(
  feeds: Feeds,
  lifecycleCapId: string,
  cadenceId: number,
): Promise<{ marketId: string; expiryMs: bigint; snap: Snap }> {
  const { marketId, expiryMs } = await createMarket(lifecycleCapId, cadenceId);
  const snap = await fetchSnapshot(Number(expiryMs));
  await executeAndWait(await seedOracleTx(refreshParams(feeds, expiryMs, snap)), "seed");
  return { marketId, expiryMs, snap };
}

// Genesis: operator account + lock min-bootstrap + supply 10M + a bare flush that mints
// PLP 1:1. No market needed (and none should exist yet); markets are created + funded
// afterward, so a fast cadence's first expiry can't race the bootstrap.
export async function bootstrapPool(lifecycleCapId: string): Promise<{ wrapperId: string }> {
  const wrapperId = deriveAccountWrapperId(address);
  await executeAndWait(createAccountTx(), "create-account");
  await executeAndWait(lockCapitalTx(POOL_VAULT_ID), "lock-capital");
  await executeAndWait(
    requestSupplyTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, wrapperId, amount: BOOTSTRAP_SUPPLY }),
    "supply",
  );
  await executeAndWait(bareFlushTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId }), "bootstrap-flush");
  return { wrapperId };
}
