// Market-data sources behind one `MarketSource` interface.
//
// - DirectWsSource owns the provider WS pair (Pyth Lazer spot + Block Scholes per-expiry
//   forward/SVI). Used by a single `harness up` and by the shared hub.
// - HubSource reads a global snapshot written by ONE hub, so N parallel localnets share a
//   single WS pair instead of opening one each.
// - ReplaySource re-plays a recorded hub stream (deterministic market dynamics): it maps
//   recorded expiries onto the current grid by sorted position and stamps fresh timestamps,
//   so the recorded spot path + term structure run against the replay localnet's clock.
import { readFileSync } from "node:fs";

import { PythLazerClient } from "@pythnetwork/pyth-lazer-sdk";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import WebSocket from "ws";

import { forwardSid, spotSid, sviSid } from "./blockScholesSid.js";
import { harnessKey } from "./io.js";
import {
  type BsSviUpdate,
  type BsValueUpdate,
  type BsWireSignature,
  sviBatchPayloadBytes,
  valueBatchPayloadBytes,
  verifyProviderBatchSignature,
} from "./localBlockScholes.js";

export const isoSec = (ms: number): string => new Date(ms).toISOString().slice(0, 19) + "Z";
const SCALE_1E9 = 1_000_000_000;
const BS_UNDERLYING_ID = 1;

// Public, versioned Block Scholes testnet trust triple. The subscription's
// `{network, pkg_ver}` selects this verifier deployment on the provider side;
// startup reads the shared registry over Sui gRPC and refuses a paused, wrong-
// package, or malformed signer configuration before accepting any market data.
const BS_PROVIDER_NETWORK = process.env.BS_PROVIDER_NETWORK ?? "testnet";
const BS_PROVIDER_PKG_VER = Number(process.env.BS_PROVIDER_PKG_VER ?? 1);
const BS_PROVIDER_PACKAGE_ID =
  process.env.BS_PROVIDER_PACKAGE_ID ??
  "0x87cc43db9b6c1e8b174841221e8e4bde5ab8fc8aaffacc58699c77e9e6340ff6";
const BS_PROVIDER_REGISTRY_ID =
  process.env.BS_PROVIDER_REGISTRY_ID ??
  "0xe1198f0add6ba5286d23f2790818937e4a629b95a86e98b1ece93c0ef3c2c440";
const BS_PROVIDER_GRPC_URL =
  process.env.BS_PROVIDER_GRPC_URL ?? "https://fullnode.testnet.sui.io:443";

export interface Svi {
  alpha: number;
  beta: number;
  rho: number;
  m: number;
  sigma: number;
}
export interface FixedSvi {
  a: bigint;
  aNegative: boolean;
  b: bigint;
  sigma: bigint;
  rho: bigint;
  rhoNegative: boolean;
  m: bigint;
  mNegative: boolean;
}
// One expiry's provider data with each series' own model timestamp — when that data is "as of",
// pinned by the provider across retransmissions of an unchanged value. The on-chain stores order
// and age series by this clock, so discarding it would collapse the dual-clock contract the
// updater exists to exercise.
export interface ExpiryData {
  forward: number;
  /// Exact provider integer at the signed subscription's decimals=9 scale.
  forward1e9: bigint;
  forwardTsMs: number;
  svi: Svi;
  /// Exact provider integers/sign bits used when re-domain-signing for localnet.
  svi1e9: FixedSvi;
  sviTsMs: number;
}
export interface MarketSnapshot {
  /// Pyth spot (the Pyth lane's input), stamped by the Pyth stream.
  spot1e9: bigint;
  publishedAtMs: bigint;
  /// Block Scholes' own signed spot series (`index.px`) with its provider model time — a
  /// separate observation from the Pyth spot, so the BS spot slot carries BS data, not a
  /// Pyth value relabeled.
  bsSpot1e9: bigint;
  bsSpotTsMs: number;
  expiries: Map<number, ExpiryData>;
}
export interface MarketSource {
  start(expiries: number[]): Promise<void>;
  ensureExpiries(want: number[]): void;
  latest(): MarketSnapshot | null;
  diagnostics?(): Record<string, unknown>;
  stop(): void;
}

export function serializableSnapshot(snapshot: MarketSnapshot): Record<string, unknown> {
  return {
    spot1e9: snapshot.spot1e9.toString(),
    publishedAtMs: snapshot.publishedAtMs.toString(),
    bsSpot1e9: snapshot.bsSpot1e9.toString(),
    bsSpotTsMs: snapshot.bsSpotTsMs,
    expiries: Object.fromEntries(
      [...snapshot.expiries.entries()].map(([expiryMs, entry]) => [
        String(expiryMs),
        {
          forward: entry.forward,
          forward1e9: entry.forward1e9.toString(),
          forwardTsMs: entry.forwardTsMs,
          svi: entry.svi,
          svi1e9: {
            a: entry.svi1e9.a.toString(),
            aNegative: entry.svi1e9.aNegative,
            b: entry.svi1e9.b.toString(),
            sigma: entry.svi1e9.sigma.toString(),
            rho: entry.svi1e9.rho.toString(),
            rhoNegative: entry.svi1e9.rhoNegative,
            m: entry.svi1e9.m.toString(),
            mNegative: entry.svi1e9.mNegative,
          },
          sviTsMs: entry.sviTsMs,
        },
      ]),
    ),
  };
}

// Parse a snapshot JSON object ({spot1e9, publishedAtMs, expiries:{ms:{forward,forwardTsMs,svi,
// sviTsMs}}}) into a MarketSnapshot. Older recordings without per-series timestamps fall back to
// the publish time. mapByPosition remaps the recorded expiries onto `wanted` by sorted index
// (replay); otherwise it filters to exactly the wanted expiries (hub).
function snapshotFrom(h: any, wanted: number[], mapByPosition: boolean): MarketSnapshot {
  const publishedAtMs = Number(h.publishedAtMs);
  const fixed = (value: unknown, fallback: number): bigint =>
    value === undefined ? BigInt(Math.round(fallback * SCALE_1E9)) : BigInt(String(value));
  const entry = (e: any): ExpiryData => {
    const svi: Svi = e.svi;
    const raw = e.svi1e9 ?? {};
    return {
      forward: Number(e.forward),
      forward1e9: fixed(e.forward1e9, Number(e.forward)),
      forwardTsMs: Number(e.forwardTsMs ?? publishedAtMs),
      svi,
      svi1e9: {
        a: fixed(raw.a, Math.abs(svi.alpha)),
        aNegative: raw.aNegative ?? svi.alpha < 0,
        b: fixed(raw.b, svi.beta),
        sigma: fixed(raw.sigma, svi.sigma),
        rho: fixed(raw.rho, Math.abs(svi.rho)),
        rhoNegative: raw.rhoNegative ?? svi.rho < 0,
        m: fixed(raw.m, Math.abs(svi.m)),
        mNegative: raw.mNegative ?? svi.m < 0,
      },
      sviTsMs: Number(e.sviTsMs ?? publishedAtMs),
    };
  };
  const expiries = new Map<number, ExpiryData>();
  if (mapByPosition) {
    const recorded = Object.keys(h.expiries ?? {}).map(Number).sort((a, b) => a - b);
    const sortedWanted = [...wanted].sort((a, b) => a - b);
    for (let i = 0; i < sortedWanted.length && i < recorded.length; i++) {
      const e = h.expiries[String(recorded[i])];
      if (e) expiries.set(sortedWanted[i], entry(e));
    }
  } else {
    for (const ms of wanted) {
      const e = h.expiries?.[String(ms)];
      if (e) expiries.set(ms, entry(e));
    }
  }
  return {
    spot1e9: BigInt(h.spot1e9),
    publishedAtMs: BigInt(h.publishedAtMs),
    // Recordings that predate the separate BS spot lane carried only the Pyth spot; fall
    // back to it so old hubs/replays keep working.
    bsSpot1e9: BigInt(h.bsSpot1e9 ?? h.spot1e9),
    bsSpotTsMs: Number(h.bsSpotTsMs ?? publishedAtMs),
    expiries,
  };
}

const PYTH_TOKEN = harnessKey("PYTH_PRO_API_KEY");
const BS_KEY = harnessKey("BLOCK_SCHOLES_API_KEY");

// Pyth Lazer history endpoint (settlement, independent of the live stream): the EXACT spot
// at a past timestamp. Mirrors deepbook-services' fetchExactLazerPayload (POST /v1/price,
// exact-timestamp assertion, fixed_rate channel so a print lands on the ms boundary), but
// returns the value (1e9) — the harness re-signs it with its own key (the pyth_feed trusts
// the local signer, not Pyth's signature) before inserting it at the expiry key.
const PYTH_HISTORY_URL = "https://pyth-lazer.dourolabs.app/v1/price";
const PYTH_HISTORY_CHANNEL = "fixed_rate@200ms";

export async function fetchExactSpot1e9(expiryMs: number, retries = 3): Promise<bigint> {
  const timestampUs = expiryMs * 1000;
  // Bounded retry/backoff: the exact-ts price is deterministic, so a rate-limit (429), a 5xx,
  // a transient network error, or the endpoint not-yet-having the print is safe to retry. This
  // keeps a transient blip from deferring the flush — which, repeated, grows the active set
  // past the single-PTB flush gas wall.
  let lastErr: unknown;
  for (let attempt = 0; attempt <= retries; attempt++) {
    if (attempt > 0) await new Promise((r) => setTimeout(r, 500 * 2 ** (attempt - 1))); // 0.5s, 1s, 2s
    try {
      const res = await fetch(PYTH_HISTORY_URL, {
        method: "POST",
        headers: { Authorization: `Bearer ${PYTH_TOKEN}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          timestamp: timestampUs, priceFeedIds: [1], properties: ["price", "exponent"],
          formats: ["leEcdsa"], jsonBinaryEncoding: "base64", parsed: true, channel: PYTH_HISTORY_CHANNEL,
        }),
      });
      if (!res.ok) throw new Error(`pyth history HTTP ${res.status}: ${(await res.text()).slice(0, 120)}`);
      const root: any = await res.json();
      if (String(root?.parsed?.timestampUs ?? "") !== String(timestampUs))
        throw new Error(`pyth history: expected ts ${timestampUs}us, got ${root?.parsed?.timestampUs}us`);
      const feed = (root.parsed.priceFeeds ?? []).find((f: any) => Number(f.priceFeedId) === 1);
      if (feed?.price == null) throw new Error("pyth history: no price for feed 1");
      return BigInt(Math.round(Number(feed.price) * 10 ** (Number(feed.exponent ?? -8) + 9)));
    } catch (e) {
      lastErr = e;
    }
  }
  throw lastErr;
}

type BsRoute =
  | { kind: "spot" }
  | { kind: "forward"; expiryMs: number }
  | { kind: "svi"; expiryMs: number };

type PendingAck = {
  clientId: string;
  expectedSids: Set<string>;
  expectedItems: Map<string, Record<string, unknown>>;
  sentAtMs: number;
};

const sidHex = (sid: bigint): string => `0x${sid.toString(16).padStart(64, "0")}`;
const fixedNumber = (value: bigint): number => Number(value) / SCALE_1E9;
const requiredString = (value: unknown, field: string): string => {
  if (typeof value !== "string") {
    throw new Error(`Block Scholes ${field} must be a decimal string`);
  }
  return value;
};
const requiredBoolean = (value: unknown, field: string): boolean => {
  if (typeof value !== "boolean") {
    throw new Error(`Block Scholes ${field} must be a boolean`);
  }
  return value;
};
const sviView = (raw: FixedSvi): Svi => ({
  alpha: fixedNumber(raw.a) * (raw.aNegative ? -1 : 1),
  beta: fixedNumber(raw.b),
  rho: fixedNumber(raw.rho) * (raw.rhoNegative ? -1 : 1),
  m: fixedNumber(raw.m) * (raw.mNegative ? -1 : 1),
  sigma: fixedNumber(raw.sigma),
});

// Direct provider source: Pyth Lazer plus Block Scholes' SUI-signed testnet
// stream. Every BS frame is reconstructed byte-for-byte and checked against the
// live testnet SignerRegistry before its values enter the cache. The localnet
// later re-signs those exact fixed-point values for its freshly published
// verifier package because the provider signature is domain-bound to testnet.
export class DirectWsSource implements MarketSource {
  #pyth: PythLazerClient | null = null;
  #bs: WebSocket | null = null;
  #spot1e9: bigint | null = null;
  #spotMs = 0n;
  #bsSpot: { raw1e9: bigint; tsMs: number } | null = null;
  #fwd = new Map<number, { raw1e9: bigint; tsMs: number }>();
  #svi = new Map<number, { raw1e9: FixedSvi; tsMs: number }>();
  #expiries: number[] = [];
  #routes = new Map<string, BsRoute>();
  #acknowledgedSids = new Set<string>();
  #retiredSids = new Map<string, number>();
  #pendingAcks = new Map<number, PendingAck>();
  #providerPublicKey: Uint8Array | null = null;
  #bsOpen = false;
  #bsStartedAtMs = 0;
  #bsSubId = 1;
  #fatal: Error | null = null;
  #stopping = false;
  #verifiedValueBatches = 0;
  #verifiedSviBatches = 0;
  #invalidBatches = 0;
  #unknownSids = 0;
  #retiredSidUpdates = 0;
  #preAckUpdates = 0;
  #acknowledgedSubscriptions = 0;

  async start(expiries: number[]): Promise<void> {
    this.#expiries = expiries;
    this.#providerPublicKey = await this.#loadProviderPublicKey();
    this.#pyth = await PythLazerClient.create({
      token: PYTH_TOKEN,
      webSocketPoolConfig: { urls: ["wss://pyth-lazer.dourolabs.app/v1/stream"], numConnections: 1 },
    });
    this.#pyth.addMessageListener((ev: any) => {
      if (ev.type !== "binary" || !ev.value.parsed) return;
      const f = ev.value.parsed.priceFeeds?.[0];
      if (f?.price == null) return;
      const exp = Number(f.exponent ?? -8);
      this.#spot1e9 = BigInt(Math.round(Number(f.price) * 10 ** (exp + 9)));
      this.#spotMs = BigInt(Math.floor(Number(ev.value.parsed.timestampUs) / 1000));
    });
    this.#pyth.subscribe({
      type: "subscribe", subscriptionId: 1, priceFeedIds: [1],
      properties: ["price", "exponent"], formats: ["leEcdsa"],
      deliveryFormat: "binary", parsed: true, channel: "real_time",
    });
    this.#startBs();
  }

  async #loadProviderPublicKey(): Promise<Uint8Array> {
    const client = new SuiGrpcClient({
      baseUrl: BS_PROVIDER_GRPC_URL,
      network: BS_PROVIDER_NETWORK as "testnet",
    });
    const { object } = await client.getObject({
      objectId: BS_PROVIDER_REGISTRY_ID,
      include: { json: true },
    });
    const result = object as any;
    const expectedType = `${BS_PROVIDER_PACKAGE_ID}::registry::SignerRegistry`;
    const objectType = result.objectType ?? result.type ?? "";
    if (objectType && objectType !== expectedType) {
      throw new Error(`Block Scholes registry type mismatch: ${objectType}`);
    }
    const json = result.json?.fields ?? result.json;
    if (!json || json.paused !== false) {
      throw new Error(`Block Scholes provider registry is paused or unreadable`);
    }
    if (typeof json.signer_pubkey !== "string") {
      throw new Error(`Block Scholes provider registry has no signer key`);
    }
    const publicKey = Uint8Array.from(Buffer.from(json.signer_pubkey, "base64"));
    if (publicKey.length !== 33 || (publicKey[0] !== 2 && publicKey[0] !== 3)) {
      throw new Error(`Block Scholes provider registry signer key is malformed`);
    }
    console.log(
      `[bs-signed] trust ready network=${BS_PROVIDER_NETWORK} pkg_ver=${BS_PROVIDER_PKG_VER} ` +
      `package=${BS_PROVIDER_PACKAGE_ID.slice(0, 10)} registry=${BS_PROVIDER_REGISTRY_ID.slice(0, 10)}`,
    );
    return publicKey;
  }

  #startBs(): void {
    const ws = new WebSocket("wss://prod-websocket-api.blockscholes.com/");
    this.#bs = ws;
    this.#bsStartedAtMs = Date.now();
    ws.on("open", () =>
      ws.send(JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "authenticate",
        params: { api_key: BS_KEY },
      })));
    ws.on("message", (raw) => {
      let frame: any;
      try {
        frame = JSON.parse(String(raw));
      } catch {
        this.#fail(new Error("Block Scholes emitted invalid JSON"));
        return;
      }
      if (frame.id === 1) {
        if (frame.result !== "ok") {
          this.#fail(
            new Error(`Block Scholes authentication failed: ${JSON.stringify(frame.error ?? frame.result)}`),
          );
          return;
        }
        this.#bsOpen = true;
        this.#subscribeBsGrid();
        return;
      }
      if (this.#pendingAcks.has(Number(frame.id))) {
        this.#handleAck(Number(frame.id), frame);
        return;
      }
      if (frame.method !== "subscription") return;
      const entries = Array.isArray(frame.params)
        ? frame.params
        : frame.params
          ? [frame.params]
          : [];
      for (const entry of entries) this.#handleSignedBatch(entry);
    });
    ws.on("error", (error) => this.#fail(new Error(`Block Scholes socket error: ${String(error)}`)));
    ws.on("close", () => {
      if (!this.#stopping && this.#fatal === null) {
        this.#fail(new Error("Block Scholes socket closed unexpectedly"));
      }
    });
  }

  #handleAck(id: number, frame: any): void {
    const pending = this.#pendingAcks.get(id);
    if (!pending) return;
    if (frame.error) {
      this.#fail(new Error(`Block Scholes ${pending.clientId} subscription failed: ${JSON.stringify(frame.error)}`));
      return;
    }
    const groups = Array.isArray(frame.result) ? frame.result : [];
    const items = groups.flatMap((group: any) => group?.batch?.batch ?? []);
    const actual = new Set<string>(items.map((item: any) => String(item.sid)));
    const expected = [...pending.expectedSids].sort();
    const received = [...actual].sort();
    const configOk = groups.length > 0 && groups.every((group: any) => {
      const batch = group?.batch;
      const format = batch?.options?.format;
      const signature = batch?.options?.signature;
      const domain = signature?.domain;
      return (
        batch?.client_id === pending.clientId &&
        format?.timestamp === "ms" &&
        format?.hexify === false &&
        Number(format?.decimals) === 9 &&
        signature?.type === "SUI" &&
        (signature?.signature_schema ?? "ecdsa") === "ecdsa" &&
        domain?.network === BS_PROVIDER_NETWORK &&
        Number(domain?.pkg_ver) === BS_PROVIDER_PKG_VER
      );
    });
    const itemsOk = items.every((item: any) => {
      const expectedItem = pending.expectedItems.get(String(item.sid));
      return (
        expectedItem !== undefined &&
        Object.entries(expectedItem).every(([key, value]) => item?.[key] === value)
      );
    });
    if (
      !configOk ||
      !itemsOk ||
      expected.length !== received.length ||
      expected.some((sid, index) => sid !== received[index])
    ) {
      this.#fail(
        new Error(
          `Block Scholes ${pending.clientId} acknowledgement mismatch ` +
          `(expected ${expected.length} configured sids, received ${received.length})`,
        ),
      );
      return;
    }
    this.#pendingAcks.delete(id);
    for (const sid of received) this.#acknowledgedSids.add(sid);
    this.#acknowledgedSubscriptions++;
    console.log(`[bs-signed] acknowledged ${pending.clientId}: ${received.length} sid(s)`);
  }

  #handleSignedBatch(entry: any): void {
    try {
      const data = entry?.data;
      const signature = entry?.signature as BsWireSignature | undefined;
      if (!data || !signature || !Array.isArray(data.values)) {
        throw new Error("Block Scholes signed notification is missing data/signature");
      }
      const batchTimestampMs = BigInt(requiredString(data.timestamp, "data.timestamp"));
      if (data.batch_kind === 0) {
        const updates: BsValueUpdate[] = data.values.map((value: any) => ({
          sid: BigInt(requiredString(value.sid, "value.sid")),
          timestampMs: BigInt(requiredString(value.t, "value.t")),
          value: BigInt(requiredString(value.v, "value.v")),
        }));
        const payload = valueBatchPayloadBytes(batchTimestampMs, updates);
        this.#verify(signature, payload);
        this.#verifiedValueBatches++;
        for (const update of updates) {
          const sid = sidHex(update.sid);
          const route = this.#routes.get(sid);
          if (!route) {
            if (this.#isRetiredSid(sid)) this.#retiredSidUpdates++;
            else this.#unknownSids++;
            continue;
          }
          if (!this.#acknowledgedSids.has(sid)) {
            this.#preAckUpdates++;
            continue;
          }
          if (route?.kind === "spot") {
            this.#bsSpot = { raw1e9: update.value, tsMs: Number(update.timestampMs) };
          } else if (route?.kind === "forward") {
            this.#fwd.set(route.expiryMs, {
              raw1e9: update.value,
              tsMs: Number(update.timestampMs),
            });
          } else {
            this.#unknownSids++;
          }
        }
      } else if (data.batch_kind === 1) {
        const updates: BsSviUpdate[] = data.values.map((value: any) => ({
          sid: BigInt(requiredString(value.sid, "svi.sid")),
          timestampMs: BigInt(requiredString(value.t, "svi.t")),
          aMagnitude: BigInt(requiredString(value.svi_a_magnitude, "svi.a")),
          aNegative: requiredBoolean(value.svi_a_is_negative, "svi.a_is_negative"),
          b: BigInt(requiredString(value.svi_b, "svi.b")),
          sigma: BigInt(requiredString(value.svi_sigma, "svi.sigma")),
          rhoMagnitude: BigInt(requiredString(value.svi_rho_magnitude, "svi.rho")),
          rhoNegative: requiredBoolean(value.svi_rho_is_negative, "svi.rho_is_negative"),
          mMagnitude: BigInt(requiredString(value.svi_m_magnitude, "svi.m")),
          mNegative: requiredBoolean(value.svi_m_is_negative, "svi.m_is_negative"),
        }));
        const payload = sviBatchPayloadBytes(batchTimestampMs, updates);
        this.#verify(signature, payload);
        this.#verifiedSviBatches++;
        for (const update of updates) {
          const sid = sidHex(update.sid);
          const route = this.#routes.get(sid);
          if (!route) {
            if (this.#isRetiredSid(sid)) this.#retiredSidUpdates++;
            else this.#unknownSids++;
            continue;
          }
          if (!this.#acknowledgedSids.has(sid)) {
            this.#preAckUpdates++;
            continue;
          }
          if (route.kind !== "svi") {
            this.#unknownSids++;
            continue;
          }
          this.#svi.set(route.expiryMs, {
            raw1e9: {
              a: update.aMagnitude,
              aNegative: update.aNegative,
              b: update.b,
              sigma: update.sigma,
              rho: update.rhoMagnitude,
              rhoNegative: update.rhoNegative,
              m: update.mMagnitude,
              mNegative: update.mNegative,
            },
            tsMs: Number(update.timestampMs),
          });
        }
      } else {
        throw new Error(`unsupported Block Scholes batch kind ${data.batch_kind}`);
      }
      const verified = this.#verifiedValueBatches + this.#verifiedSviBatches;
      if (verified <= 3 || verified % 30 === 0) {
        console.log(
          `[bs-signed] verified batch #${verified} kind=${data.batch_kind} ` +
          `values=${data.values.length} published_at_ms=${batchTimestampMs}`,
        );
      }
    } catch (error) {
      this.#invalidBatches++;
      this.#fail(error instanceof Error ? error : new Error(String(error)));
    }
  }

  #verify(signature: BsWireSignature, payload: Uint8Array): void {
    if (
      this.#providerPublicKey === null ||
      !verifyProviderBatchSignature({
        signature,
        payload,
        verifierPackageId: BS_PROVIDER_PACKAGE_ID,
        expectedPublicKey: this.#providerPublicKey,
      })
    ) {
      throw new Error("Block Scholes batch signature did not match the live testnet registry");
    }
  }

  #fail(error: Error): void {
    if (this.#fatal !== null) return;
    this.#fatal = error;
    console.warn(`[bs-signed] fatal: ${error.message.slice(0, 240)}`);
    this.#bs?.close();
  }

  #isRetiredSid(sid: string): boolean {
    const expiresAtMs = this.#retiredSids.get(sid);
    if (expiresAtMs === undefined) return false;
    if (expiresAtMs >= Date.now()) return true;
    this.#retiredSids.delete(sid);
    return false;
  }

  // Subscribe the full current grid under stable client_ids. The client supplies
  // Propbook's packed u256 ids because today's stores derive those exact ids at
  // read time; each acknowledgement is checked before the stream is trusted.
  #subscribeBsGrid(): void {
    const ws = this.#bs;
    if (!ws) return;
    const active = this.#expiries.filter((ms) => ms > Date.now());
    const spot = {
      sid: sidHex(spotSid(BS_UNDERLYING_ID)),
      feed: "index.px",
      asset: "spot",
      base_asset: "BTC",
      exchange: "blockscholes",
    };
    const forwards = active.map((ms) => ({
      sid: sidHex(forwardSid(BS_UNDERLYING_ID, BigInt(ms))),
      feed: "mark.px",
      asset: "future",
      base_asset: "BTC",
      expiry: isoSec(ms),
    }));
    const svis = active.map((ms) => ({
      sid: sidHex(sviSid(BS_UNDERLYING_ID, BigInt(ms))),
      feed: "model.params",
      exchange: "composite",
      asset: "option",
      base_asset: "BTC",
      model: "SVI",
      expiry: isoSec(ms),
    }));
    const nextRoutes = new Map<string, BsRoute>();
    nextRoutes.set(spot.sid, { kind: "spot" });
    active.forEach((expiryMs, index) => {
      nextRoutes.set(forwards[index].sid, { kind: "forward", expiryMs });
      nextRoutes.set(svis[index].sid, { kind: "svi", expiryMs });
    });
    const retiredUntilMs = Date.now() + 10_000;
    for (const sid of this.#routes.keys()) {
      if (!nextRoutes.has(sid)) this.#retiredSids.set(sid, retiredUntilMs);
    }
    this.#routes = nextRoutes;
    this.#acknowledgedSids = new Set<string>();

    const firstId = this.#bsSubId + 1;
    this.#bsSubId += 3;
    this.#sendSubscription(firstId, "spot", [spot]);
    this.#sendSubscription(firstId + 1, "forwards", forwards);
    this.#sendSubscription(firstId + 2, "svi", svis);
  }

  #sendSubscription(id: number, clientId: string, batch: Record<string, unknown>[]): void {
    const ws = this.#bs;
    if (!ws) return;
    const expectedSids = new Set(batch.map((item) => String(item.sid)));
    const expectedItems = new Map(
      batch.map((item) => [String(item.sid), item]),
    );
    this.#pendingAcks.set(id, {
      clientId,
      expectedSids,
      expectedItems,
      sentAtMs: Date.now(),
    });
    ws.send(JSON.stringify({
      jsonrpc: "2.0",
      id,
      method: "subscribe",
      params: [{
        frequency: "1000ms",
        retransmit_frequency: "1000ms",
        client_id: clientId,
        batch,
        options: {
          format: { timestamp: "ms", hexify: false, decimals: 9 },
          signature: {
            type: "SUI",
            signature_schema: "ecdsa",
            domain: {
              network: BS_PROVIDER_NETWORK,
              pkg_ver: BS_PROVIDER_PKG_VER,
            },
          },
        },
      }],
    }));
  }

  // Roll the warmed grid forward by replacing the provider batches wholesale;
  // prune expired cached rows so memory and routing stay bounded.
  ensureExpiries(want: number[]): void {
    const same = want.length === this.#expiries.length && want.every((ms, i) => ms === this.#expiries[i]);
    this.#expiries = [...want];
    const keep = new Set(want);
    for (const ms of [...this.#fwd.keys()]) if (!keep.has(ms)) this.#fwd.delete(ms);
    for (const ms of [...this.#svi.keys()]) if (!keep.has(ms)) this.#svi.delete(ms);
    if (this.#bsOpen && !same) this.#subscribeBsGrid();
  }

  latest(): MarketSnapshot | null {
    if (this.#fatal !== null) throw this.#fatal;
    if (!this.#bsOpen && Date.now() - this.#bsStartedAtMs > 10_000) {
      this.#fail(new Error("Block Scholes authentication timed out"));
      throw this.#fatal;
    }
    const staleAck = [...this.#pendingAcks.values()].find(
      (pending) => Date.now() - pending.sentAtMs > 10_000,
    );
    if (staleAck) {
      this.#fail(new Error(`Block Scholes ${staleAck.clientId} acknowledgement timed out`));
      throw this.#fatal;
    }
    if (this.#spot1e9 == null || this.#bsSpot == null) return null;
    const expiries = new Map<number, ExpiryData>();
    for (const ms of this.#expiries) {
      const forward = this.#fwd.get(ms);
      const svi = this.#svi.get(ms);
      if (forward != null && svi) {
        expiries.set(ms, {
          forward: fixedNumber(forward.raw1e9),
          forward1e9: forward.raw1e9,
          forwardTsMs: forward.tsMs,
          svi: sviView(svi.raw1e9),
          svi1e9: svi.raw1e9,
          sviTsMs: svi.tsMs,
        });
      }
    }
    return {
      spot1e9: this.#spot1e9,
      publishedAtMs: this.#spotMs,
      bsSpot1e9: this.#bsSpot.raw1e9,
      bsSpotTsMs: this.#bsSpot.tsMs,
      expiries,
    };
  }

  diagnostics(): Record<string, unknown> {
    return {
      provider_network: BS_PROVIDER_NETWORK,
      provider_pkg_ver: BS_PROVIDER_PKG_VER,
      verifier_package_id: BS_PROVIDER_PACKAGE_ID,
      signer_registry_id: BS_PROVIDER_REGISTRY_ID,
      authenticated: this.#bsOpen,
      acknowledged_subscriptions: this.#acknowledgedSubscriptions,
      pending_acknowledgements: this.#pendingAcks.size,
      verified_value_batches: this.#verifiedValueBatches,
      verified_svi_batches: this.#verifiedSviBatches,
      invalid_batches: this.#invalidBatches,
      unknown_sids: this.#unknownSids,
      retired_sid_updates: this.#retiredSidUpdates,
      pre_ack_updates: this.#preAckUpdates,
      fatal: this.#fatal?.message ?? null,
    };
  }

  stop(): void {
    this.#stopping = true;
    this.#pyth?.shutdown();
    this.#bs?.close();
    console.log(
      `[bs-signed] summary: acks=${this.#acknowledgedSubscriptions} ` +
      `value_batches=${this.#verifiedValueBatches} svi_batches=${this.#verifiedSviBatches} ` +
      `invalid=${this.#invalidBatches} unknown_sids=${this.#unknownSids}`,
    );
  }
}

// Reads the global snapshot written by the hub; filters to the wanted expiries. No WS.
export class HubSource implements MarketSource {
  #wanted: number[] = [];
  constructor(private readonly path: string) {}
  async start(expiries: number[]): Promise<void> {
    this.#wanted = expiries;
  }
  ensureExpiries(want: number[]): void {
    this.#wanted = want;
  }
  latest(): MarketSnapshot | null {
    try {
      return snapshotFrom(JSON.parse(readFileSync(this.path, "utf8")), this.#wanted, false);
    } catch {
      return null;
    }
  }
  stop(): void {}
}

// Re-plays a recorded hub stream (JSONL of snapshots), one record per poll, remapping
// recorded expiries onto the current grid and stamping a fresh publish time so the values
// stay within the on-chain freshness window.
export class ReplaySource implements MarketSource {
  #records: any[] = [];
  #i = 0;
  #wanted: number[] = [];
  constructor(private readonly path: string) {}
  async start(expiries: number[]): Promise<void> {
    this.#wanted = expiries;
    this.#records = readFileSync(this.path, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  }
  ensureExpiries(want: number[]): void {
    this.#wanted = want;
  }
  latest(): MarketSnapshot | null {
    if (this.#records.length === 0) return null;
    const h = this.#records[Math.min(this.#i, this.#records.length - 1)];
    this.#i++;
    const snap = snapshotFrom(h, this.#wanted, true);
    // Rebase EVERY clock by one offset so relative ages survive the replay. Refreshing only
    // the envelope hands the store fresh batches whose model times still carry the
    // recording's absolute age — the store accepts them and Predict immediately rejects
    // them as stale.
    const nowMs = Date.now();
    const offsetMs = nowMs - Number(snap.publishedAtMs);
    const shift = (tsMs: number): number => (tsMs > 0 ? tsMs + offsetMs : 0);
    const expiries = new Map<number, ExpiryData>();
    for (const [ms, e] of snap.expiries) {
      expiries.set(ms, { ...e, forwardTsMs: shift(e.forwardTsMs), sviTsMs: shift(e.sviTsMs) });
    }
    return {
      ...snap,
      publishedAtMs: BigInt(nowMs),
      bsSpotTsMs: shift(snap.bsSpotTsMs),
      expiries,
    };
  }
  stop(): void {}
}
