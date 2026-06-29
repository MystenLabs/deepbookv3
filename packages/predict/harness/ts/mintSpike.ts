// B1 spike: first end-to-end semantic trade, on the shared predictSetup bring-up.
//   feeds/config -> create+seed market -> bootstrap pool -> resolve "2x UP @ ~30c" -> mint.
// The mint PTB refreshes the oracle with the SAME snapshot the resolver priced against,
// so on-chain pricing matches the off-chain selection (only math drift).
import { RESOLVER_MARKET } from "./predictConfig.js";
import { bootstrapPool, createAndSeedMarket, eventField, isoSec, refreshParams, setupFeedsAndConfig } from "./predictSetup.js";
import { type Instruction, resolveMint } from "./resolver.js";
import { POOL_VAULT_ID, PROTOCOL_CONFIG_ID, depositToAccountTx, executeAndWait, rebalanceExpiryCashTx, refreshOracleAndMintTx } from "./runtime.js";

const SCALE = 1_000_000_000n;
const DUSDC = 1_000_000n;
const CADENCE_1H = 2;

async function main() {
  const { feeds, lifecycleCapId } = await setupFeedsAndConfig([CADENCE_1H]);
  const { wrapperId } = await bootstrapPool(lifecycleCapId);
  const { marketId, expiryMs, snap } = await createAndSeedMarket(feeds, lifecycleCapId, CADENCE_1H);
  await executeAndWait(
    rebalanceExpiryCashTx({ poolVaultId: POOL_VAULT_ID, protocolConfigId: PROTOCOL_CONFIG_ID, expiryMarketId: marketId, pythFeedId: feeds.pythFeedId }),
    "rebalance",
  );
  await executeAndWait(depositToAccountTx(wrapperId, 1_000_000n * DUSDC), "deposit");
  console.log(`[spike] market ${marketId.slice(0, 10)} expiry=${isoSec(Number(expiryMs))} spot=$${snap.pythSpot.toFixed(0)} forward=$${snap.bsForward.toFixed(0)} funded+mintable`);

  const inst: Instruction = { direction: "UP", leverage: 2, targetProbability: 0.3, spendUsd: 100 };
  const resolved = resolveMint(inst, { pythSpot: snap.pythSpot, bsSpot: snap.pythSpot, bsForward: snap.bsForward, svi: snap.svi }, RESOLVER_MARKET);
  console.log(`[spike] resolved 2x UP @ ~30c $100 -> strike=$${resolved.strikeUsd.toFixed(0)} p=${(resolved.predictedProbability * 100).toFixed(2)}c maxPayout=$${(Number(resolved.quantity) / 1e6).toFixed(2)} feasible=${resolved.feasible}${resolved.reason ? " (" + resolved.reason + ")" : ""}`);
  if (!resolved.feasible) throw new Error("instruction infeasible: " + resolved.reason);

  const mintTx = await refreshOracleAndMintTx({
    ...refreshParams(feeds, expiryMs, snap),
    expiryMarketId: marketId, protocolConfigId: PROTOCOL_CONFIG_ID, wrapperId,
    strike: BigInt(Math.round(resolved.strikeUsd)) * SCALE,
    isUp: inst.direction === "UP",
    quantity: resolved.quantity,
    leverage: resolved.leverage1e9,
  });
  const mintR = await executeAndWait(mintTx, "mint");
  console.log(`[spike] MINTED order=${eventField(mintR, "OrderMinted", "order_id")} net_premium=$${(Number(eventField(mintR, "OrderMinted", "net_premium")) / 1e6).toFixed(2)} digest=${mintR.digest}`);
  console.log("\n=== B1 PASS: semantic instruction resolved + minted against live data ===");
}

main().then(() => process.exit(0)).catch((e) => { console.error("[spike] FAIL:", e); process.exit(1); });
