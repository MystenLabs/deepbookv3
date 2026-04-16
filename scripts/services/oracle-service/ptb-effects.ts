import type { SuiEvent, SuiTransactionBlockResponse } from "@mysten/sui/client";

export type CreatedOracleEffect = {
  oracleId: string;
  underlyingAsset: string;
  expiryMs: number;
};

export type SettledOracleEffect = {
  oracleId: string;
  settlementPrice: number;
  timestampMs: number;
};

export type ParsedEvents = {
  created: CreatedOracleEffect[];
  settled: SettledOracleEffect[];
};

export function parseOracleEvents(events: SuiEvent[], packageId: string): ParsedEvents {
  const created: CreatedOracleEffect[] = [];
  const settled: SettledOracleEffect[] = [];
  const createdType = `${packageId}::registry::OracleCreated`;
  const settledType = `${packageId}::oracle::OracleSettled`;

  for (const e of events) {
    if (e.type === createdType) {
      const p = e.parsedJson as Record<string, string>;
      created.push({
        oracleId: p.oracle_id,
        underlyingAsset: p.underlying_asset,
        expiryMs: Number(p.expiry),
      });
    } else if (e.type === settledType) {
      const p = e.parsedJson as Record<string, string>;
      settled.push({
        oracleId: p.oracle_id,
        settlementPrice: Number(p.settlement_price),
        timestampMs: Number(p.timestamp),
      });
    }
  }

  return { created, settled };
}

type GasUsedShape = {
  gasUsed: {
    computationCost: string;
    storageCost: string;
    storageRebate: string;
    nonRefundableStorageFee: string;
  };
};

export function gasNetFromEffects(effects: GasUsedShape): number {
  const u = effects.gasUsed;
  const rebate = Number(u.storageRebate);
  const computation = Number(u.computationCost);
  const storage = Number(u.storageCost);
  const nonRefundable = Number(u.nonRefundableStorageFee);
  return rebate - computation - storage - nonRefundable;
}

export function newGasCoinVersionFromEffects(
  resp: SuiTransactionBlockResponse,
  gasCoinId: string,
): { version: string; digest: string } | undefined {
  const mutated = resp.effects?.mutated ?? [];
  for (const ref of mutated) {
    if (ref.reference.objectId === gasCoinId) {
      return { version: ref.reference.version, digest: ref.reference.digest };
    }
  }
  return undefined;
}
