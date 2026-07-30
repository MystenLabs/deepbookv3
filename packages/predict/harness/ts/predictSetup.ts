// Shared Predict-layer bring-up on an oracle-ready localnet: oracle feeds + trusted
// signer + cadence/freshness config + lifecycle cap, then create+seed a market and
// bootstrap the pool. Used by the B1 mint spike and the keeper so the multi-step
// operator sequence lives in one place.

import { existsSync, readFileSync } from "node:fs";

import { atomicWriteFile } from "./io.js";
import { DirectWsSource, type FixedSvi } from "./marketSource.js";
import { type Svi } from "./pricer.js";
import { BOOTSTRAP_SUPPLY, CADENCES, FRESHNESS } from "./predictConfig.js";
import {
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
  address,
  bareFlushTx,
  bindFeedsToUnderlyingTx,
  createAccountTx,
  createExpiryMarketTx,
  deriveAccountWrapperId,
  executeAndWait,
  lockCapitalTx,
  mintLifecycleCapTx,
  objectExists,
  readPlpTotalSupply,
  readSupplyRequestsPending,
  registerUnderlyingAndCreateFeedsTx,
  requestSupplyTx,
  seedOracleTx,
  setBlockScholesSignerTx,
  setCadenceConfigTx,
  setOracleFreshnessTx,
  updatePythTrustedSignerTx,
} from "./runtime.js";

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
  bsValueStoreId: string;
  bsSviStoreId: string;
}
export interface Snap {
  pythSpot: number;
  pythSpot1e9: bigint;
  bsForward: number;
  bsForward1e9: bigint;
  svi: Svi;
  svi1e9: FixedSvi;
}

// One-shot: fetch the same signature-verified source the continuous updater
// uses, rather than maintaining a second unsigned subscription implementation.
export async function fetchSnapshot(expiryMs: number, timeoutMs = 70_000): Promise<Snap> {
  const source = new DirectWsSource();
  await source.start([expiryMs]);
  const deadline = Date.now() + timeoutMs;
  try {
    while (Date.now() < deadline) {
      const snapshot = source.latest();
      const expiry = snapshot?.expiries.get(expiryMs);
      if (snapshot && expiry) {
        return {
          pythSpot: Number(snapshot.spot1e9) / 1e9,
          pythSpot1e9: snapshot.spot1e9,
          bsForward: expiry.forward,
          bsForward1e9: expiry.forward1e9,
          svi: {
            a: expiry.svi.alpha,
            b: expiry.svi.beta,
            rho: expiry.svi.rho,
            m: expiry.svi.m,
            sigma: expiry.svi.sigma,
          },
          svi1e9: expiry.svi1e9,
        };
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error("snapshot timeout (cold expiry?)");
  } finally {
    source.stop();
  }
}

// OracleRefreshParams shape from a snapshot (1e9-scaled, signed-magnitude SVI).
export function refreshParams(feeds: Feeds, expiryMs: bigint, snap: Snap) {
  return {
    ...feeds,
    expiry: expiryMs,
    spot: snap.pythSpot1e9,
    forward: snap.bsForward1e9,
    svi: {
      a: snap.svi1e9.a,
      aNegative: snap.svi1e9.aNegative,
      b: snap.svi1e9.b,
      sigma: snap.svi1e9.sigma,
      rho: snap.svi1e9.rho,
      rhoNegative: snap.svi1e9.rhoNegative,
      m: snap.svi1e9.m,
      mNegative: snap.svi1e9.mNegative,
    },
  };
}

// Trusted signer + Pyth/BS feeds + bound underlying + per-cadence config + freshness
// + a lifecycle cap. Returns the feed ids and the cap needed to create/flush markets.
export async function setupFeedsAndConfig(cadenceIds: number[]): Promise<{ feeds: Feeds; lifecycleCapId: string }> {
  const instanceDir = process.env.INSTANCE_DIR;
  const feedsPath = instanceDir ? `${instanceDir}/feeds.json` : undefined;
  let feeds: Feeds;
  if (feedsPath && existsSync(feedsPath)) {
    // Restart re-attach: reuse the already-created feeds instead of minting new feed
    // objects (which would overwrite feeds.json while the updater streams the old ids).
    feeds = JSON.parse(readFileSync(feedsPath, "utf8"));
    console.log("[setup] re-attaching to existing feeds.json");
  } else {
    await executeAndWait(updatePythTrustedSignerTx(), "trusted-signer");
    await executeAndWait(setBlockScholesSignerTx(), "bs-signer");
    const feedsR = await executeAndWait(registerUnderlyingAndCreateFeedsTx(1), "feeds");
    const pythFeedId = found(feedsR, "pyth_feed::PythFeed");
    const bsValueStoreId = found(feedsR, "block_scholes_store::BlockScholesValueStore");
    const bsSviStoreId = found(feedsR, "block_scholes_store::BlockScholesSVIStore");
    await executeAndWait(bindFeedsToUnderlyingTx({ pythFeedId }), "bind-spot");
    feeds = { pythFeedId, bsValueStoreId, bsSviStoreId };
    // Publish the feed ids so the updater (a separate process) can stream onto them.
    if (feedsPath) atomicWriteFile(feedsPath, JSON.stringify(feeds));
  }

  // Config setters are idempotent — (re-)run either way so a re-attach re-asserts policy.
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
  // Fully bootstrapped: the $10M supply has landed. The min-liquidity lock alone is
  // << BOOTSTRAP_SUPPLY, so this only trips AFTER the final flush — never mid-genesis.
  if ((await readPlpTotalSupply()) >= BOOTSTRAP_SUPPLY) {
    console.log("[setup] pool already bootstrapped (supply >= bootstrap); skipping");
    return { wrapperId };
  }
  // Resume-safe genesis (create -> lock -> request -> flush): each step skips if already
  // done, so a crash mid-bootstrap re-attaches without double-creating the account or
  // double-queueing the supply. (lock_capital mints the min-liquidity lock, flipping
  // supply>0 at step 2 — which is why a single supply>0 key would falsely skip steps 3-4
  // and silently run an under-capitalized pool.)
  if (!(await objectExists(wrapperId))) await executeAndWait(createAccountTx(), "create-account");
  if ((await readPlpTotalSupply()) === 0n) await executeAndWait(lockCapitalTx(POOL_VAULT_ID), "lock-capital");
  if ((await readSupplyRequestsPending()) === 0n && (await readPlpTotalSupply()) < BOOTSTRAP_SUPPLY) {
    await executeAndWait(
      requestSupplyTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, wrapperId, amount: BOOTSTRAP_SUPPLY }),
      "supply",
    );
  }
  await executeAndWait(bareFlushTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId }), "bootstrap-flush");
  return { wrapperId };
}
