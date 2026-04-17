// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import type { SuiJsonRpcClient, CoinStruct } from "@mysten/sui/jsonRpc";
import type { Keypair } from "@mysten/sui/cryptography";
import { Transaction } from "@mysten/sui/transactions";
import type { Config } from "./config";
import type { CapId, Lane } from "./types";
import type { Logger } from "./logger";

const SUI_TO_MIST = 1_000_000_000n;

/// Ensure the signer owns exactly `laneCount` OracleSVICaps and has at least
/// `laneCount` SUI coins to pair with them. Creates caps via
/// registry::create_oracle_cap if under-provisioned, and splits the largest
/// coin into `laneCount` equal pieces if coin count is insufficient. Returns
/// the (cap, gas-coin) pairs as ready-to-use Lanes.
export async function ensureCapsAndCoins(
  client: SuiJsonRpcClient,
  signer: Keypair,
  config: Config,
  log: Logger,
): Promise<{ capIds: CapId[]; lanes: Lane[] }> {
  const address = signer.toSuiAddress();

  let caps = await getOwnedCaps(client, address, config.predictPackageId);
  if (caps.length < config.laneCount) {
    const missing = config.laneCount - caps.length;
    log.info({ event: "caps_created", missing });
    const newCaps = await createCaps(client, signer, config, missing);
    caps.push(...newCaps);
  }
  caps = caps.slice(0, config.laneCount);

  let coins = await getAllSuiCoins(client, address);
  const totalSui = Number(coins.reduce((s, c) => s + BigInt(c.balance), 0n)) / Number(SUI_TO_MIST);
  if (totalSui < config.gasPoolFloorSui) {
    throw new Error(
      `Gas pool underfunded: have ${totalSui.toFixed(2)} SUI, need >= ${config.gasPoolFloorSui}`,
    );
  }

  if (coins.length < config.laneCount) {
    const splitsNeeded = config.laneCount - coins.length;
    const amountPerSplit = Math.floor(totalSui / config.laneCount);
    await splitCoin(client, signer, splitsNeeded, amountPerSplit);
    coins = await getAllSuiCoins(client, address);
  }

  coins.sort((a, b) => Number(BigInt(b.balance) - BigInt(a.balance)));
  const chosen = coins.slice(0, config.laneCount);

  const lanes: Lane[] = chosen.map((coin, i) => ({
    id: i,
    gasCoinId: coin.coinObjectId,
    gasCoinVersion: coin.version,
    gasCoinDigest: coin.digest,
    capId: caps[i],
    available: true,
  }));

  log.info({ event: "lanes_ready", laneCount: lanes.length, totalSui });
  return { capIds: caps, lanes };
}

async function getOwnedCaps(
  client: SuiJsonRpcClient,
  address: string,
  packageId: string,
): Promise<CapId[]> {
  const capType = `${packageId}::oracle::OracleSVICap`;
  const out: CapId[] = [];
  let cursor: string | null | undefined = null;
  do {
    const resp = await client.getOwnedObjects({
      owner: address,
      filter: { StructType: capType },
      options: { showType: true },
      cursor,
    });
    for (const o of resp.data) {
      if (o.data?.objectId) out.push(o.data.objectId);
    }
    cursor = resp.hasNextPage ? resp.nextCursor : null;
  } while (cursor);
  return out;
}

async function getAllSuiCoins(client: SuiJsonRpcClient, address: string): Promise<CoinStruct[]> {
  const out: CoinStruct[] = [];
  let cursor: string | null | undefined = null;
  do {
    const resp = await client.getCoins({ owner: address, coinType: "0x2::sui::SUI", cursor });
    out.push(...resp.data);
    cursor = resp.hasNextPage ? resp.nextCursor : null;
  } while (cursor);
  return out;
}

async function createCaps(
  client: SuiJsonRpcClient,
  signer: Keypair,
  config: Config,
  count: number,
): Promise<CapId[]> {
  const tx = new Transaction();
  const signerAddr = signer.toSuiAddress();
  for (let i = 0; i < count; i++) {
    const cap = tx.moveCall({
      target: `${config.predictPackageId}::registry::create_oracle_cap`,
      arguments: [tx.object(config.adminCapId)],
    });
    tx.transferObjects([cap], tx.pure.address(signerAddr));
  }
  const resp = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true, showObjectChanges: true },
  });
  await client.waitForTransaction({ digest: resp.digest });
  const capType = `${config.predictPackageId}::oracle::OracleSVICap`;
  return (resp.objectChanges ?? [])
    .filter((c: any) => c.type === "created" && c.objectType === capType)
    .map((c: any) => c.objectId);
}

async function splitCoin(
  client: SuiJsonRpcClient,
  signer: Keypair,
  splits: number,
  amountSuiEach: number,
): Promise<void> {
  // Split from `tx.gas` (the auto-selected gas coin) rather than referencing
  // a specific coin. This way the source and gas payment are the same coin,
  // which works even when the signer has only one SUI coin — the tx takes
  // gas from the remainder after the split.
  const tx = new Transaction();
  const amount = BigInt(amountSuiEach) * SUI_TO_MIST;
  const amounts = Array(splits).fill(amount);
  const coins = tx.splitCoins(tx.gas, amounts.map((a) => tx.pure.u64(a)));
  tx.transferObjects(
    Array.from({ length: splits }, (_, i) => coins[i]),
    tx.pure.address(signer.toSuiAddress()),
  );
  const resp = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true },
  });
  await client.waitForTransaction({ digest: resp.digest });
}
