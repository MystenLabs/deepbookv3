// Shared Predict-layer bring-up on an oracle-ready localnet: oracle feeds + trusted
// signer + cadence config + the lifecycle and pool-valuation caps, then create markets
// and bootstrap the pool.

import { existsSync, readFileSync } from "node:fs";

import { atomicWriteFile } from "./io.js";
import { BOOTSTRAP_SUPPLY, CADENCES } from "./predictConfig.js";
import { requiredEnv } from "./runnerConfig.js";
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
  mintPoolValuationCapTx,
  objectExists,
  type OracleFeedIds,
  readPlpTotalSupply,
  readSupplyRequestsPending,
  registerUnderlyingAndCreateFeedsTx,
  requestSupplyTx,
  setBlockScholesSignerTx,
  setCadenceConfigTx,
  updatePythTrustedSignerTx,
} from "../../devtools/ts/runtime.js";

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

export type Feeds = OracleFeedIds;

// Trusted signer + Pyth/BS feeds + bound underlying + per-cadence config + the two
// operator caps. Returns the feed ids, the lifecycle cap that creates markets, and the
// pool-valuation cap that starts flushes.
export async function setupFeedsAndConfig(
  cadenceIds: number[],
): Promise<{ feeds: Feeds; lifecycleCapId: string; poolValuationCapId: string }> {
  const instanceDir = requiredEnv("INSTANCE_DIR");
  const feedsPath = `${instanceDir}/feeds.json`;
  let feeds: Feeds;
  if (existsSync(feedsPath)) {
    // Restart re-attach: reuse the already-created feeds instead of minting new feed
    // objects (which would overwrite feeds.json while the updater streams the old ids).
    feeds = JSON.parse(readFileSync(feedsPath, "utf8"));
    console.log("[setup] re-attaching to existing feeds.json");
  } else {
    await executeAndWait(updatePythTrustedSignerTx(), "trusted-signer");
    await executeAndWait(setBlockScholesSignerTx(), "bs-signer");
    const feedsR = await executeAndWait(registerUnderlyingAndCreateFeedsTx(), "feeds");
    const pythFeedId = found(feedsR, "pyth_feed::PythFeed");
    const bsValueStoreId = found(feedsR, "block_scholes_store::BlockScholesValueStore");
    const bsSviStoreId = found(feedsR, "block_scholes_store::BlockScholesSVIStore");
    await executeAndWait(bindFeedsToUnderlyingTx({ pythFeedId }), "bind-spot");
    feeds = { pythFeedId, bsValueStoreId, bsSviStoreId };
    // Publish the feed ids so the updater (a separate process) can stream onto them.
    atomicWriteFile(feedsPath, JSON.stringify(feeds));
  }

  // Config setters are idempotent — (re-)run either way so a re-attach re-asserts policy.
  const cap = await executeAndWait(mintLifecycleCapTx(address), "lifecycle-cap");
  const lifecycleCapId = found(cap, "MarketLifecycleCap");
  const valuationCap = await executeAndWait(mintPoolValuationCapTx(address), "pool-valuation-cap");
  const poolValuationCapId = found(valuationCap, "PoolValuationCap");
  for (const cadenceId of cadenceIds) {
    await executeAndWait(setCadenceConfigTx({ cadenceId, ...CADENCES[cadenceId] }), `cadence-${cadenceId}`);
  }
  return { feeds, lifecycleCapId, poolValuationCapId };
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

// Genesis: operator account + lock min-bootstrap + supply 10M + a bare flush that mints
// PLP 1:1. No market needed (and none should exist yet); markets are created + funded
// afterward, so a fast cadence's first expiry can't race the bootstrap.
export async function bootstrapPool(poolValuationCapId: string): Promise<{ wrapperId: string }> {
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
  await executeAndWait(bareFlushTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, poolValuationCapId }), "bootstrap-flush");
  return { wrapperId };
}
