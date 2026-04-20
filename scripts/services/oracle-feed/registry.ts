// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import type { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";
import type { Config } from "./config";
import type { CapId, OracleId, OracleState, OracleStatus } from "./types";
import type { Logger } from "./logger";
import { inferTier } from "./expiry";

export function classifyStatus(
  active: boolean,
  expiryMs: number,
  settlementPriceOpt: number | null,
  isCompacted: boolean,
  nowMs: number,
): OracleStatus {
  // `compacted` must win over `settled`: once the vault has moved this oracle
  // into `settled_oracles`, there is no further manager work to do — and
  // classifying it as `settled` would make `shouldRunManagerWindowNow` keep
  // the manager hot, starving the push path. See /Users/aslantashtanov/
  // .claude/plans/let-s-plan-out-all-cheeky-acorn.md for the full history.
  if (isCompacted) return "compacted";
  if (settlementPriceOpt !== null) return "settled";
  if (nowMs >= expiryMs) return "pending_settlement";
  if (!active) return "inactive";
  return "active";
}

/// Read the Vault's `settled_oracles` table to find every oracle that has
/// already been compacted. Returns an empty set on RPC failure (caller falls
/// back to the pre-fix classification) so the fix cannot make things worse
/// than the current stall state when the network blips.
export async function fetchCompactedOracleIds(
  client: SuiJsonRpcClient,
  predictId: string,
  log: Logger,
): Promise<Set<OracleId>> {
  try {
    const predict = await client.getObject({
      id: predictId,
      options: { showContent: true },
    });
    const content = predict.data?.content;
    if (!content || content.dataType !== "moveObject") {
      log.warn({ event: "vault_settled_fetch_failed", reason: "no_content" });
      return new Set();
    }
    const fields = content.fields as Record<string, any>;
    const settledTableId =
      fields?.vault?.fields?.settled_oracles?.fields?.id?.id ?? null;
    if (typeof settledTableId !== "string") {
      log.warn({ event: "vault_settled_fetch_failed", reason: "no_table_id" });
      return new Set();
    }

    const ids = new Set<OracleId>();
    let cursor: string | null = null;
    do {
      const page = await client.getDynamicFields({
        parentId: settledTableId,
        cursor,
      });
      for (const field of page.data ?? []) {
        // Table<ID, _> dynamic fields store the key under `name.value` as the
        // oracle's object id string.
        const name = field.name as { value?: unknown } | undefined;
        const value = name?.value;
        if (typeof value === "string") {
          ids.add(value);
        }
      }
      cursor = page.hasNextPage ? page.nextCursor ?? null : null;
    } while (cursor);
    return ids;
  } catch (err) {
    log.warn({
      event: "vault_settled_fetch_failed",
      reason: "rpc_error",
      err: String(err),
    });
    return new Set();
  }
}

/// Discover all oracles that any of the signer's caps can authorize. Reads
/// registry::oracle_ids via devInspect for each cap, unions the results, then
/// fetches the oracle objects to read their current state.
export async function discoverOracles(
  client: SuiJsonRpcClient,
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

  // Read Vault.settled_oracles up-front so classification can distinguish
  // settled-not-yet-compacted from settled-and-already-compacted. On RPC
  // failure we get an empty set and fall back to pre-fix behavior.
  const compactedIds = await fetchCompactedOracleIds(client, config.predictId, log);

  const out = new Map<OracleId, OracleState>();
  const batchSize = 50;
  const ids = [...oracleIdSet];
  for (let i = 0; i < ids.length; i += batchSize) {
    const batch = ids.slice(i, i + batchSize);
    const resps = await client.multiGetObjects({ ids: batch, options: { showContent: true } });
    for (const resp of resps) {
      const parsed = parseOracleObject(resp);
      if (!parsed) continue;
      const tier = inferTier(parsed.expiryMs, config.tiersEnabled);
      if (!tier) {
        log.warn({
          event: "oracle_discovered",
          oracleId: parsed.oracleId,
          reason: "expiry_not_in_tier_schedule",
          expiryMs: parsed.expiryMs,
        });
        continue;
      }
      const status = classifyStatus(
        parsed.active,
        parsed.expiryMs,
        parsed.settlementPriceOpt,
        compactedIds.has(parsed.oracleId),
        nowMs,
      );
      out.set(parsed.oracleId, {
        id: parsed.oracleId,
        underlying: parsed.underlying,
        expiryMs: parsed.expiryMs,
        tier,
        status,
        registeredCapIds: new Set(parsed.authorizedCaps.filter((c) => capIds.includes(c))),
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
  client: SuiJsonRpcClient,
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
    return bcs.vector(bcs.Address).parse(Uint8Array.from(returnValues[0][0])) as string[];
  } catch {
    return [];
  }
}

type OracleObjectFields = {
  oracleId: string;
  underlying: string;
  expiryMs: number;
  active: boolean;
  settlementPriceOpt: number | null;
  authorizedCaps: string[];
};

export function parseOracleObject(resp: any): OracleObjectFields | undefined {
  const data = resp.data;
  if (!data) return undefined;
  const content = data.content;
  if (!content || content.dataType !== "moveObject") return undefined;
  const f = content.fields as Record<string, any>;
  const authCapsRaw = f.authorized_caps?.fields?.contents ?? [];
  const authCaps = Array.isArray(authCapsRaw) ? authCapsRaw.map(String) : [];
  const settlementPriceOpt =
    typeof f.settlement_price === "string"
      ? Number(f.settlement_price)
      : f.settlement_price?.fields?.vec?.length > 0
        ? Number(f.settlement_price.fields.vec[0])
        : null;
  return {
    oracleId: data.objectId,
    underlying: String(f.underlying_asset ?? ""),
    expiryMs: Number(f.expiry),
    active: Boolean(f.active),
    settlementPriceOpt,
    authorizedCaps: authCaps,
  };
}
