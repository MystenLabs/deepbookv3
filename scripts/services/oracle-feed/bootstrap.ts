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

  await assertSignerOwnsAdminCap(client, address, config.adminCapId);

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

  await refreshGasLanesIfNeeded(client, signer, config, undefined, log);
  coins = await getAllSuiCoins(client, address);

  coins = sortCoinsByBalanceDesc(coins);
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

export async function refreshGasLanesIfNeeded(
  client: SuiJsonRpcClient,
  signer: Keypair,
  config: Config,
  lanes: Lane[] | undefined,
  log: Logger,
): Promise<boolean> {
  if (lanes && lanes.length !== config.laneCount) {
    throw new Error(`expected ${config.laneCount} gas lanes, found ${lanes.length}`);
  }
  if (lanes?.some((lane) => !lane.available)) {
    throw new Error("cannot refresh gas lanes while any lane is active");
  }

  const address = signer.toSuiAddress();
  const coins = await getAllSuiCoins(client, address);
  const sortedCoins = sortCoinsByBalanceDesc(coins);
  const totalMist = sumCoinBalances(coins);
  const effectiveMinMist = minBigInt(suiToMist(config.gasLaneMinSui), totalMist / BigInt(config.laneCount));
  const selectedCoins = lanes
    ? lanes.map((lane) => coins.find((coin) => coin.coinObjectId === lane.gasCoinId))
    : sortedCoins.slice(0, config.laneCount);
  const selectedBalances = selectedCoins.map((coin) => coin ? BigInt(coin.balance) : null);
  const needsRefresh =
    coins.length < config.laneCount ||
    selectedCoins.length < config.laneCount ||
    selectedBalances.some((balance) => balance === null || balance < effectiveMinMist);

  if (!needsRefresh) {
    log.info({
      event: "gas_refresh_noop",
      coinCount: coins.length,
      laneCount: config.laneCount,
      totalSui: mistToSui(totalMist),
      minSui: config.gasLaneMinSui,
      effectiveMinSui: mistToSui(effectiveMinMist),
    });
    return false;
  }

  const primary = sortedCoins[0];
  if (!primary) {
    throw new Error("cannot refresh gas lanes without a SUI gas coin");
  }

  log.info({
    event: "gas_refresh_started",
    coinCount: coins.length,
    laneCount: config.laneCount,
    totalSui: mistToSui(totalMist),
    minSui: config.gasLaneMinSui,
    effectiveMinSui: mistToSui(effectiveMinMist),
    primaryGasCoinId: primary.coinObjectId,
  });

  const tx = new Transaction();
  tx.setSender(address);
  tx.setGasPayment([coinRef(primary)]);

  const mergeSources = sortedCoins.slice(1).map((coin) => tx.objectRef(coinRef(coin)));
  if (mergeSources.length > 0) {
    tx.mergeCoins(tx.gas, mergeSources);
  }

  const splitCount = config.laneCount - 1;
  if (splitCount > 0) {
    const amountPerLane = totalMist / BigInt(config.laneCount);
    if (amountPerLane <= 0n) {
      throw new Error("cannot refresh gas lanes with zero split amount");
    }
    const splitCoins = tx.splitCoins(
      tx.gas,
      Array.from({ length: splitCount }, () => tx.pure.u64(amountPerLane)),
    );
    tx.transferObjects(
      Array.from({ length: splitCount }, (_, i) => splitCoins[i]),
      tx.pure.address(address),
    );
  }

  const resp = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true },
  });
  if (resp.effects?.status.status !== "success") {
    throw new Error(`gas lane refresh failed: ${JSON.stringify(resp.effects?.status)}`);
  }
  await client.waitForTransaction({ digest: resp.digest });

  const refreshedCoins = sortCoinsByBalanceDesc(await getAllSuiCoins(client, address));
  const refreshedLaneCoins = refreshedCoins.slice(0, config.laneCount);
  if (refreshedLaneCoins.length < config.laneCount) {
    throw new Error(
      `gas lane refresh produced ${refreshedLaneCoins.length} SUI coins, need ${config.laneCount}`,
    );
  }

  if (lanes) {
    for (let i = 0; i < lanes.length; i++) {
      const coin = refreshedLaneCoins[i]!;
      lanes[i]!.gasCoinId = coin.coinObjectId;
      lanes[i]!.gasCoinVersion = coin.version;
      lanes[i]!.gasCoinDigest = coin.digest;
    }
  }

  log.info({
    event: "gas_refresh_completed",
    txDigest: resp.digest,
    laneCount: config.laneCount,
    refreshedCoinIds: refreshedLaneCoins.map((coin) => coin.coinObjectId),
  });
  return true;
}

export async function assertSignerOwnsAdminCap(
  client: SuiJsonRpcClient,
  signerAddress: string,
  adminCapId: string,
): Promise<void> {
  const resp = await client.getObject({
    id: adminCapId,
    options: { showOwner: true },
  });
  const owner = resp.data?.owner;
  const addressOwner =
    owner && typeof owner === "object" && "AddressOwner" in owner
      ? owner.AddressOwner
      : null;

  if (addressOwner !== signerAddress) {
    throw new Error(
      `oracle-feed signer ${signerAddress} must own AdminCap ${adminCapId}, but current owner is ${addressOwner ?? "non-address owner"}`,
    );
  }
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

function coinRef(coin: CoinStruct) {
  return {
    objectId: coin.coinObjectId,
    version: coin.version,
    digest: coin.digest,
  };
}

function sortCoinsByBalanceDesc(coins: CoinStruct[]): CoinStruct[] {
  return [...coins].sort((a, b) => {
    const aBalance = BigInt(a.balance);
    const bBalance = BigInt(b.balance);
    if (aBalance === bBalance) return a.coinObjectId.localeCompare(b.coinObjectId);
    return aBalance > bBalance ? -1 : 1;
  });
}

function sumCoinBalances(coins: CoinStruct[]): bigint {
  return coins.reduce((sum, coin) => sum + BigInt(coin.balance), 0n);
}

function suiToMist(sui: number): bigint {
  if (!Number.isFinite(sui) || sui <= 0) return 0n;
  return BigInt(Math.floor(sui * Number(SUI_TO_MIST)));
}

function mistToSui(mist: bigint): number {
  return Number(mist) / Number(SUI_TO_MIST);
}

function minBigInt(a: bigint, b: bigint): bigint {
  return a < b ? a : b;
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
