import type { SuiClient } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import type { Config } from "./config";
import type { CapId, OracleId, OracleRegistry, OracleState, OracleStatus, Tier } from "./types";
import type { Logger } from "./logger";

export function newRegistry(): OracleRegistry {
  return { byId: new Map(), byExpiry: new Map() };
}

function classifyStatus(args: {
  active: boolean;
  expiryMs: number;
  settlementPriceOpt: number | null;
  nowMs: number;
}): OracleStatus {
  if (args.settlementPriceOpt !== null) return "settled";
  if (args.nowMs >= args.expiryMs) return "pending_settlement";
  if (!args.active) return "inactive";
  return "active";
}

function inferTier(expiryMs: number, nowMs: number, enabledTiers: Tier[]): Tier | undefined {
  const d = new Date(expiryMs);
  const dow = d.getUTCDay();
  const sec = d.getUTCSeconds();
  const ms = d.getUTCMilliseconds();
  if (sec !== 0 || ms !== 0) return undefined;

  if (enabledTiers.includes("1w") && dow === 5 && d.getUTCHours() === 8 && d.getUTCMinutes() === 0) {
    return "1w";
  }
  if (enabledTiers.includes("1d") && d.getUTCHours() === 8 && d.getUTCMinutes() === 0) {
    return "1d";
  }
  if (enabledTiers.includes("1h") && d.getUTCMinutes() === 0) {
    return "1h";
  }
  if (enabledTiers.includes("15m") && d.getUTCMinutes() % 15 === 0) {
    return "15m";
  }
  return undefined;
}

export async function discoverOracles(
  client: SuiClient,
  config: Config,
  capIds: CapId[],
  nowMs: number,
  log: Logger,
): Promise<Map<OracleId, OracleState>> {
  const oracleIdSet = new Set<OracleId>();
  for (const capId of capIds) {
    const idsForCap = await oracleIdsForCap(client, config, capId);
    for (const id of idsForCap) oracleIdSet.add(id);
  }

  const out = new Map<OracleId, OracleState>();
  const batchSize = 50;
  const ids = [...oracleIdSet];
  for (let i = 0; i < ids.length; i += batchSize) {
    const batch = ids.slice(i, i + batchSize);
    const resps = await client.multiGetObjects({
      ids: batch,
      options: { showContent: true },
    });
    for (const resp of resps) {
      const parsed = parseOracleObject(resp);
      if (!parsed) continue;
      const status = classifyStatus({
        active: parsed.active,
        expiryMs: parsed.expiryMs,
        settlementPriceOpt: parsed.settlementPriceOpt,
        nowMs,
      });
      const tier = inferTier(parsed.expiryMs, nowMs, config.tiersEnabled);
      if (!tier) {
        log.warn({
          event: "oracle_discovered",
          oracleId: parsed.oracleId,
          reason: "expiry_not_in_tier_schedule",
          expiryMs: parsed.expiryMs,
        });
        continue;
      }
      out.set(parsed.oracleId, {
        id: parsed.oracleId,
        underlying: "BTC",
        expiryMs: parsed.expiryMs,
        tier,
        status,
        lastTimestampMs: parsed.timestampMs,
        registeredCapIds: new Set(parsed.authorizedCaps.filter((c) => capIds.includes(c))),
        matrixCompacted: false,
      });
      log.info({
        event: "oracle_discovered",
        oracleId: parsed.oracleId,
        tier,
        status,
        expiryMs: parsed.expiryMs,
      });
    }
  }
  return out;
}

async function oracleIdsForCap(
  client: SuiClient,
  config: Config,
  capId: CapId,
): Promise<OracleId[]> {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.predictPackageId}::registry::oracle_ids`,
    arguments: [tx.object(config.registryId), tx.pure.id(capId)],
  });
  try {
    const resp = await client.devInspectTransactionBlock({
      transactionBlock: tx,
      sender: "0x0000000000000000000000000000000000000000000000000000000000000000",
    });
    const returnValues = resp.results?.[0]?.returnValues;
    if (!returnValues || returnValues.length === 0) return [];
    const { bcs } = await import("@mysten/sui/bcs");
    const ids = bcs.vector(bcs.Address).parse(Uint8Array.from(returnValues[0][0])) as string[];
    return ids;
  } catch {
    return [];
  }
}

type OracleObjectFields = {
  oracleId: string;
  expiryMs: number;
  active: boolean;
  timestampMs: number;
  settlementPriceOpt: number | null;
  authorizedCaps: string[];
};

function parseOracleObject(resp: any): OracleObjectFields | undefined {
  const data = resp.data;
  if (!data) return undefined;
  const content = data.content;
  if (!content || content.dataType !== "moveObject") return undefined;
  const f = content.fields as Record<string, any>;
  const authCapsRaw = f.authorized_caps?.fields?.contents ?? [];
  const authCaps = Array.isArray(authCapsRaw) ? authCapsRaw.map(String) : [];
  const settlementPriceOpt =
    f.settlement_price?.fields?.vec?.length > 0
      ? Number(f.settlement_price.fields.vec[0])
      : null;
  return {
    oracleId: data.objectId,
    expiryMs: Number(f.expiry),
    active: Boolean(f.active),
    timestampMs: Number(f.timestamp),
    settlementPriceOpt,
    authorizedCaps: authCaps,
  };
}
