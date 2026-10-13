// Shared Predict-layer bring-up on an oracle-ready localnet: oracle feeds + trusted
// signer + cadence config + the lifecycle and pool-valuation caps + the order-flow allowlist
// and flush-operator grant, then create markets (each with its queue) and bootstrap the pool.

import { existsSync, readFileSync } from "node:fs";

import { atomicWriteFile } from "./io.js";
import { BOOTSTRAP_SUPPLY, CADENCES } from "./predictConfig.js";
import { requiredEnv } from "./runnerConfig.js";
import {
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
  addFlushOperatorTx,
  addSettledRedeemKeeperTx,
  address,
  bareFlushTx,
  bindFeedsToUnderlyingTx,
  createAccountTx,
  createExpiryMarketTx,
  createMarketQueueTx,
  deriveAccountWrapperId,
  deriveMarketQueueId,
  enableOrderFlowTx,
  executeAndWait,
  lockCapitalTx,
  mintLifecycleCapTx,
  mintPoolValuationCapTx,
  objectExists,
  type OracleFeedIds,
  readIsFlushOperator,
  readOrderFlowEnabled,
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
  settledRedeemKeepers: string[],
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
    // Re-adding a listed keeper aborts, so this runs only on first setup, not on re-attach.
    for (const keeper of settledRedeemKeepers) {
      await executeAndWait(addSettledRedeemKeeperTx(keeper), `settled-redeem-keeper-${keeper.slice(0, 8)}`);
    }
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
  await ensureDelayedExecution();
  return { feeds, lifecycleCapId, poolValuationCapId };
}

// Traders can only enqueue, through the order-flow companion, and Predict refuses its
// admissions, commits, and fills until the admin allowlists its witness. The companion's publish
// already shared the desk with the launch policy. `finish_flush` admits only allowlisted flush
// operators, and this signer sends every flush (bootstrap included). Each is read first, so setup
// stays idempotent across a re-attach.
export async function ensureDelayedExecution(): Promise<void> {
  if (!(await readOrderFlowEnabled())) {
    await executeAndWait(enableOrderFlowTx(), "enable-order-flow");
  }
  if (!(await readIsFlushOperator(address))) {
    await executeAndWait(addFlushOperatorTx(address), "flush-operator");
  }
}

// Create one cadence market and its queue. Reads NO oracle (absolute ticks need no grid
// centering), so a keeper with a live updater needs no per-market seed — the updater warms the
// feed.
export async function createMarket(
  lifecycleCapId: string,
  cadenceId: number,
): Promise<{ marketId: string; expiryMs: bigint }> {
  const mkR = await executeAndWait(
    createExpiryMarketTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, lifecycleCapId, cadenceId }),
    "create-market",
  );
  const marketId = found(mkR, "ExpiryMarket");
  await ensureMarketQueue(marketId);
  return { marketId, expiryMs: BigInt(eventField(mkR, "MarketCreated", "expiry")) };
}

// Every market needs its queue before anyone can place on it. Creation is permissionless and
// once per market at a derived ID, so this reads first: a keeper restarted between creating a
// market and its queue creates the queue on its next pass.
export async function ensureMarketQueue(marketId: string): Promise<void> {
  if (await objectExists(deriveMarketQueueId(marketId))) return;
  const r = await executeAndWait(createMarketQueueTx(marketId), "create-queue");
  if (found(r, "queue::MarketQueue") !== deriveMarketQueueId(marketId)) {
    throw new Error(`queue for ${marketId.slice(0, 10)} was not created at its derived ID`);
  }
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
