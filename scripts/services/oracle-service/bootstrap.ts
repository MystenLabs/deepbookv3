import type { SuiClient, CoinStruct } from "@mysten/sui/client";
import type { Keypair } from "@mysten/sui/cryptography";
import { Transaction } from "@mysten/sui/transactions";
import type { Config } from "./config";
import type { CapId, Lane, LaneState } from "./types";
import type { Logger } from "./logger";

const SUI_TO_MIST = 1_000_000_000n;

export async function ensureCapsAndCoins(
  client: SuiClient,
  signer: Keypair,
  config: Config,
  log: Logger,
): Promise<{ capIds: CapId[]; lanes: Lane[] }> {
  const address = signer.toSuiAddress();

  const caps = await getOwnedCaps(client, address, config.predictPackageId);
  if (caps.length < config.laneCount) {
    const missing = config.laneCount - caps.length;
    log.info({ event: "service_started", msg: "creating_caps", missing });
    const newCaps = await createCaps(client, signer, config, missing);
    caps.push(...newCaps);
  }
  caps.length = config.laneCount;

  let coins = await getAllSuiCoins(client, address);
  const totalSui = Number(coins.reduce((s, c) => s + BigInt(c.balance), 0n)) / 1_000_000_000;
  if (totalSui < config.gasPoolFloorSui) {
    throw new Error(
      `Gas pool underfunded: have ${totalSui.toFixed(2)} SUI, need >= ${config.gasPoolFloorSui}`,
    );
  }

  if (coins.length < config.laneCount) {
    const neededPerLane = Math.floor(totalSui / config.laneCount);
    await splitCoin(client, signer, coins[0], config.laneCount - coins.length, neededPerLane);
    coins = await getAllSuiCoins(client, address);
  }

  coins.sort((a, b) => Number(BigInt(b.balance) - BigInt(a.balance)));
  const chosenCoins = coins.slice(0, config.laneCount);

  const lanes: Lane[] = chosenCoins.map((coin, i) => ({
    id: i,
    gasCoinId: coin.coinObjectId,
    gasCoinBalanceApproxMist: Number(coin.balance),
    capId: caps[i],
    available: true,
    lastTxDigest: null,
  }));

  log.info({
    event: "service_started",
    msg: "lanes_ready",
    laneCount: lanes.length,
    totalSui,
  });

  return { capIds: caps, lanes };
}

async function getOwnedCaps(
  client: SuiClient,
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

async function getAllSuiCoins(client: SuiClient, address: string): Promise<CoinStruct[]> {
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
  client: SuiClient,
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
  client: SuiClient,
  signer: Keypair,
  sourceCoin: CoinStruct,
  splits: number,
  amountSuiEach: number,
): Promise<void> {
  const tx = new Transaction();
  const amount = BigInt(amountSuiEach) * SUI_TO_MIST;
  const amounts = Array(splits).fill(amount);
  const coins = tx.splitCoins(tx.object(sourceCoin.coinObjectId), amounts.map((a) => tx.pure.u64(a)));
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
