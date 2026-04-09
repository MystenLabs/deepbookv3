#!/usr/bin/env tsx
/**
 * Swap SUI for DEEP on the testnet DEEP_SUI DeepBook pool.
 * Uses pool::swap_exact_quote_for_base (no balance manager needed).
 *
 * Usage:
 *   npx tsx swap-sui-for-deep.ts --amount 10      # swap 10 SUI for DEEP
 *   npx tsx swap-sui-for-deep.ts --amount 10 --network mainnet
 */

import { parseArgs } from "util";
import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner, getActiveAddress } from "../lib/sui-helpers.js";

const { values: args } = parseArgs({
  options: {
    amount: { type: "string", default: "10" },
    network: { type: "string", short: "n", default: "testnet" },
  },
  strict: false,
  allowPositionals: true,
});

const NETWORK = args.network as "mainnet" | "testnet";
const SUI_AMOUNT = Number(args.amount);

const COINS: Record<string, { deepType: string; poolId: string }> = {
  testnet: {
    deepType:
      "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP",
    poolId:
      "0x48c95963e9eac37a316b7ae04a0deb761bcdcc2b67912374d6036e7f0e9bae9f",
  },
  mainnet: {
    deepType:
      "0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP",
    poolId:
      "0xb663828d6217467c8a1838a03793da896cbe745b150ebd57d82f814ca579fc22",
  },
};

const DEEPBOOK_PACKAGE: Record<string, string> = {
  testnet:
    "0x22be4cade64bf2d02412c7e8d0e8beea2f78828b948118d46735315409371a3c",
  mainnet:
    "0x337f4f4f6567fcd778d5454f27c16c70e2f274cc6377ea6249ddf491482ef497",
};

const SUI_TYPE =
  "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI";
const CLOCK_ID = "0x6";

async function main() {
  const address = getActiveAddress();
  const client = getClient(NETWORK);
  const signer = getSigner();

  const { deepType, poolId } = COINS[NETWORK];
  const dbPkg = DEEPBOOK_PACKAGE[NETWORK];

  console.log(`\nSwapping ${SUI_AMOUNT} SUI for DEEP on ${NETWORK}`);
  console.log(`  Address: ${address}`);
  console.log(`  Pool:    ${poolId.slice(0, 20)}...`);

  const tx = new Transaction();

  const suiAmountMist = BigInt(Math.floor(SUI_AMOUNT * 1e9));
  const [suiCoin] = tx.splitCoins(tx.gas, [tx.pure.u64(suiAmountMist)]);

  const [zeroDeep] = tx.moveCall({
    target: "0x2::coin::zero",
    typeArguments: [deepType],
  });

  const [baseCoinResult, quoteCoinResult, deepCoinResult] = tx.moveCall({
    target: `${dbPkg}::pool::swap_exact_quote_for_base`,
    arguments: [
      tx.object(poolId),
      suiCoin,
      zeroDeep,
      tx.pure.u64(0),
      tx.object(CLOCK_ID),
    ],
    typeArguments: [deepType, SUI_TYPE],
  });

  tx.transferObjects([baseCoinResult, quoteCoinResult, deepCoinResult], address);
  tx.setGasBudget(50_000_000);

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true, showEvents: true, showBalanceChanges: true },
  });

  const status = result.effects?.status?.status;
  if (status !== "success") {
    console.error("Swap failed:", result.effects?.status?.error);
    process.exit(1);
  }

  console.log(`  Tx: ${result.digest}`);

  for (const bc of (result as any).balanceChanges ?? []) {
    const symbol = bc.coinType.split("::").pop();
    const amount = Number(bc.amount);
    const decimals = symbol === "SUI" ? 9 : 6;
    const human = amount / 10 ** decimals;
    const sign = amount > 0 ? "+" : "";
    console.log(`  ${sign}${human.toFixed(4)} ${symbol}`);
  }
}

main().catch((err) => {
  console.error("Failed:", err.message);
  process.exit(1);
});
