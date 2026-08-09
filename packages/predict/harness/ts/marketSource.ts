// Market-data sources behind one `MarketSource` interface.
//
// - DirectWsSource owns the provider WS pair (Pyth Lazer spot + Block Scholes per-expiry
//   forward/SVI). Used by a single `harness live` and by the shared hub.
// - HubSource reads a global snapshot written by ONE hub, so N parallel localnets share a
//   single WS pair instead of opening one each.
import { readFileSync } from "node:fs";

import { PythLazerClient } from "@pythnetwork/pyth-lazer-sdk";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import WebSocket from "ws";

import {
  PREDICT_BLOCK_SCHOLES_BASE_ASSET,
  PREDICT_BLOCK_SCHOLES_QUOTE_ASSET,
  forwardSid,
  spotSid,
  sviSid,
} from "../../devtools/ts/blockScholesSid.js";
import { harnessKey } from "./io.js";
import {
  type BsSviUpdate,
  type BsValueUpdate,
  type BsWireSignature,
  providerBatchFromJson,
  verifyProviderBatchSignature,
} from "../../devtools/ts/blockScholesWire.js";

export const isoSec = (ms: number): string => new Date(ms).toISOString().slice(0, 19) + "Z";
const SCALE_1E9 = 1_000_000_000;

// Public, versioned Block Scholes testnet trust triple. The IDs are the deployment recorded by
// the exact upstream source revision pinned in Predict's Move.toml. The subscription's
// `{network, pkg_ver}` selects this verifier deployment on the provider side;
// startup fail-fast reads the shared registry over Sui gRPC, and every signed
// batch re-reads it so pause and signer rotation take effect without a restart.
const BS_PROVIDER_PROFILE = {
  name: "testnet-v1",
  network: "testnet" as const,
  pkgVer: 1,
  packageId: "0x9d2cf38611d971a0e918b93fc0113d279f5c923f43e62c407a9ad0f9d82f6698",
  registryId: "0x94d0198a6fa973bb457603ed39b39b76c98468114808ad5b518745b7b957c414",
  grpcUrl: "https://fullnode.testnet.sui.io:443",
};

export function providerPublicKeyFromRegistryObject(result: unknown): Uint8Array {
  const object = result as any;
  const expectedType = `${BS_PROVIDER_PROFILE.packageId}::registry::SignerRegistry`;
  const objectType = object?.objectType ?? object?.type ?? "";
  if (objectType && objectType !== expectedType) {
    throw new Error(`Block Scholes registry type mismatch: ${objectType}`);
  }
  const json = object?.json?.fields ?? object?.json;
  if (!json || json.paused !== false) {
    throw new Error("Block Scholes provider registry is paused or unreadable");
  }
  if (typeof json.signer_pubkey !== "string") {
    throw new Error("Block Scholes provider registry has no signer key");
  }
  const publicKey = Uint8Array.from(Buffer.from(json.signer_pubkey, "base64"));
  if (publicKey.length !== 33 || (publicKey[0] !== 2 && publicKey[0] !== 3)) {
    throw new Error("Block Scholes provider registry signer key is malformed");
  }
  return publicKey;
}

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
// series by this clock first, so discarding it would collapse the dual-clock contract the
// updater exists to exercise; the SVI additionally carries its batch envelope time, the clock
// on-chain freshness gates and the roll-down anchors on.
export interface ExpiryData {
  forward: number;
  /// Exact provider integer at the signed subscription's decimals=9 scale.
  forward1e9: bigint;
  forwardTsMs: number;
  svi: Svi;
  /// Exact provider integers/sign bits used when re-domain-signing for localnet.
  svi1e9: FixedSvi;
  sviTsMs: number;
  /// Envelope time of the batch that last carried the SVI tuple — the roll-down anchor.
  sviPublishedAtMs: number;
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
    schemaVersion: 1,
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
          sviPublishedAtMs: entry.sviPublishedAtMs,
        },
      ]),
    ),
  };
}

function strictObject(
  value: unknown,
  keys: readonly string[],
  label: string,
): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  const object = value as Record<string, unknown>;
  const expected = new Set(keys);
  const missing = keys.filter((key) => !(key in object));
  const unknown = Object.keys(object).filter((key) => !expected.has(key));
  if (missing.length || unknown.length) {
    throw new Error(
      `${label} schema mismatch` +
      (missing.length ? `; missing=${missing.join(",")}` : "") +
      (unknown.length ? `; unknown=${unknown.join(",")}` : ""),
    );
  }
  return object;
}

function integerString(value: unknown, label: string): bigint {
  if (typeof value !== "string" || !/^-?\d+$/.test(value)) {
    throw new Error(`${label} must be an integer string`);
  }
  return BigInt(value);
}

function finiteNumber(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error(`${label} must be a finite number`);
  }
  return value;
}

// Parse the current versioned hub snapshot. Missing and unknown fields fail the read;
// callers retry the next atomic snapshot instead of silently manufacturing semantics.
function snapshotFrom(raw: unknown, wanted: number[]): MarketSnapshot {
  const h = strictObject(
    raw,
    ["schemaVersion", "spot1e9", "publishedAtMs", "bsSpot1e9", "bsSpotTsMs", "expiries"],
    "snapshot",
  );
  if (h.schemaVersion !== 1) {
    throw new Error(`unsupported snapshot schemaVersion: ${String(h.schemaVersion)}`);
  }
  const encodedExpiries = h.expiries;
  if (encodedExpiries === null || typeof encodedExpiries !== "object" || Array.isArray(encodedExpiries)) {
    throw new Error("snapshot.expiries must be an object");
  }
  const entry = (e: any): ExpiryData => {
    const encoded = strictObject(
      e,
      ["forward", "forward1e9", "forwardTsMs", "svi", "svi1e9", "sviTsMs", "sviPublishedAtMs"],
      "snapshot expiry",
    );
    const encodedSvi = strictObject(
      encoded.svi,
      ["alpha", "beta", "rho", "m", "sigma"],
      "snapshot expiry.svi",
    );
    const encodedFixed = strictObject(
      encoded.svi1e9,
      ["a", "aNegative", "b", "sigma", "rho", "rhoNegative", "m", "mNegative"],
      "snapshot expiry.svi1e9",
    );
    const boolean = (value: unknown, label: string): boolean => {
      if (typeof value !== "boolean") throw new Error(`${label} must be a boolean`);
      return value;
    };
    const svi: Svi = {
      alpha: finiteNumber(encodedSvi.alpha, "snapshot expiry.svi.alpha"),
      beta: finiteNumber(encodedSvi.beta, "snapshot expiry.svi.beta"),
      rho: finiteNumber(encodedSvi.rho, "snapshot expiry.svi.rho"),
      m: finiteNumber(encodedSvi.m, "snapshot expiry.svi.m"),
      sigma: finiteNumber(encodedSvi.sigma, "snapshot expiry.svi.sigma"),
    };
    return {
      forward: finiteNumber(encoded.forward, "snapshot expiry.forward"),
      forward1e9: integerString(encoded.forward1e9, "snapshot expiry.forward1e9"),
      forwardTsMs: finiteNumber(encoded.forwardTsMs, "snapshot expiry.forwardTsMs"),
      svi,
      svi1e9: {
        a: integerString(encodedFixed.a, "snapshot expiry.svi1e9.a"),
        aNegative: boolean(encodedFixed.aNegative, "snapshot expiry.svi1e9.aNegative"),
        b: integerString(encodedFixed.b, "snapshot expiry.svi1e9.b"),
        sigma: integerString(encodedFixed.sigma, "snapshot expiry.svi1e9.sigma"),
        rho: integerString(encodedFixed.rho, "snapshot expiry.svi1e9.rho"),
        rhoNegative: boolean(encodedFixed.rhoNegative, "snapshot expiry.svi1e9.rhoNegative"),
        m: integerString(encodedFixed.m, "snapshot expiry.svi1e9.m"),
        mNegative: boolean(encodedFixed.mNegative, "snapshot expiry.svi1e9.mNegative"),
      },
      sviTsMs: finiteNumber(encoded.sviTsMs, "snapshot expiry.sviTsMs"),
      sviPublishedAtMs: finiteNumber(encoded.sviPublishedAtMs, "snapshot expiry.sviPublishedAtMs"),
    };
  };
  const expiries = new Map<number, ExpiryData>();
  for (const ms of wanted) {
    const e = (encodedExpiries as Record<string, unknown>)[String(ms)];
    if (e) expiries.set(ms, entry(e));
  }
  return {
    spot1e9: integerString(h.spot1e9, "snapshot.spot1e9"),
    publishedAtMs: integerString(h.publishedAtMs, "snapshot.publishedAtMs"),
    bsSpot1e9: integerString(h.bsSpot1e9, "snapshot.bsSpot1e9"),
    bsSpotTsMs: finiteNumber(h.bsSpotTsMs, "snapshot.bsSpotTsMs"),
    expiries,
  };
}

const pythToken = () => harnessKey("PYTH_PRO_API_KEY");
const blockScholesKey = () => harnessKey("BLOCK_SCHOLES_API_KEY");

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
        headers: { Authorization: `Bearer ${pythToken()}`, "Content-Type": "application/json" },
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

type BlockScholesSubscription = {
  expectedSid: string;
  request: Record<string, unknown>;
};

const sidHex = (sid: bigint): string => `0x${sid.toString(16).padStart(64, "0")}`;

export function blockScholesSpotSubscription(): BlockScholesSubscription {
  return {
    expectedSid: sidHex(
      spotSid(BS_PROVIDER_PROFILE.packageId, PREDICT_BLOCK_SCHOLES_BASE_ASSET),
    ),
    request: {
      feed: "index.px",
      asset: "spot",
      exchange: "blockscholes",
      base_asset: PREDICT_BLOCK_SCHOLES_BASE_ASSET,
      quote_asset: PREDICT_BLOCK_SCHOLES_QUOTE_ASSET,
    },
  };
}

export function blockScholesForwardSubscription(expiryMs: number): BlockScholesSubscription {
  return {
    expectedSid: sidHex(
      forwardSid(
        BS_PROVIDER_PROFILE.packageId,
        PREDICT_BLOCK_SCHOLES_BASE_ASSET,
        BigInt(expiryMs),
      ),
    ),
    request: {
      feed: "mark.px",
      asset: "future",
      exchange: "composite",
      base_asset: PREDICT_BLOCK_SCHOLES_BASE_ASSET,
      quote_asset: PREDICT_BLOCK_SCHOLES_QUOTE_ASSET,
      expiry: isoSec(expiryMs),
    },
  };
}

export function blockScholesSubscribeRequest(
  id: number,
  clientId: string,
  batch: Record<string, unknown>[],
) {
  return {
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
          pkg_ver: BS_PROVIDER_PROFILE.pkgVer,
          signature_schema: "ecdsa",
          domain: {
            network: BS_PROVIDER_PROFILE.network,
          },
        },
      },
    }],
  };
}

export function subscriptionItemMatches(
  expected: Record<string, unknown>,
  actual: unknown,
): boolean {
  return Object.entries(expected).every(
    ([key, value]) => (actual as Record<string, unknown> | null)?.[key] === value,
  );
}

const fixedNumber = (value: bigint): number => Number(value) / SCALE_1E9;
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
  #svi = new Map<number, { raw1e9: FixedSvi; tsMs: number; publishedAtMs: number }>();
  #expiries: number[] = [];
  #routes = new Map<string, BsRoute>();
  #acknowledgedSids = new Set<string>();
  #retiredSids = new Map<string, number>();
  #pendingAcks = new Map<number, PendingAck>();
  #registryClient = new SuiGrpcClient({
    baseUrl: BS_PROVIDER_PROFILE.grpcUrl,
    network: BS_PROVIDER_PROFILE.network,
  });
  #signedBatchQueue: Promise<void> = Promise.resolve();
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
    await this.#loadProviderPublicKey(true);
    this.#pyth = await PythLazerClient.create({
      token: pythToken(),
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

  async #loadProviderPublicKey(announce = false): Promise<Uint8Array> {
    const { object } = await this.#registryClient.getObject({
      objectId: BS_PROVIDER_PROFILE.registryId,
      include: { json: true },
    });
    const publicKey = providerPublicKeyFromRegistryObject(object);
    if (announce) {
      console.log(
        `[bs-signed] trust ready profile=${BS_PROVIDER_PROFILE.name} ` +
        `package=${BS_PROVIDER_PROFILE.packageId.slice(0, 10)} ` +
        `registry=${BS_PROVIDER_PROFILE.registryId.slice(0, 10)}`,
      );
    }
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
        params: { api_key: blockScholesKey() },
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
      for (const entry of entries) {
        this.#signedBatchQueue = this.#signedBatchQueue.then(() =>
          this.#handleSignedBatch(entry),
        );
      }
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
        Number(signature?.pkg_ver) === BS_PROVIDER_PROFILE.pkgVer &&
        (signature?.signature_schema ?? "ecdsa") === "ecdsa" &&
        domain?.network === BS_PROVIDER_PROFILE.network
      );
    });
    const itemsOk = items.every((item: any) => {
      const expectedItem = pending.expectedItems.get(String(item.sid));
      return (
        expectedItem !== undefined &&
        subscriptionItemMatches(expectedItem, item)
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

  async #handleSignedBatch(entry: any): Promise<void> {
    try {
      const data = entry?.data;
      const signature = entry?.signature as BsWireSignature | undefined;
      if (!data || !signature || !Array.isArray(data.values)) {
        throw new Error("Block Scholes signed notification is missing data/signature");
      }
      const batch = providerBatchFromJson(data);
      // Registry pause and signer rotation are live trust inputs. Re-read them for
      // every serialized provider batch so an already-running hub cannot continue
      // under a revoked key or reject a newly-authorized one until restart.
      const providerPublicKey = await this.#loadProviderPublicKey();
      if (batch.kind === "value") {
        const updates: BsValueUpdate[] = batch.updates;
        this.#verify(signature, batch.payload, providerPublicKey);
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
      } else {
        const updates: BsSviUpdate[] = batch.updates;
        this.#verify(signature, batch.payload, providerPublicKey);
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
            publishedAtMs: Number(batch.batchTimestampMs),
          });
        }
      }
      const verified = this.#verifiedValueBatches + this.#verifiedSviBatches;
      if (verified <= 3 || verified % 30 === 0) {
        console.log(
          `[bs-signed] verified batch #${verified} kind=${batch.kind} ` +
          `values=${batch.updates.length} published_at_ms=${batch.batchTimestampMs}`,
        );
      }
    } catch (error) {
      this.#invalidBatches++;
      this.#fail(error instanceof Error ? error : new Error(String(error)));
    }
  }

  #verify(
    signature: BsWireSignature,
    payload: Uint8Array,
    providerPublicKey: Uint8Array,
  ): void {
    if (
      !verifyProviderBatchSignature({
        signature,
        payload,
        verifierPackageId: BS_PROVIDER_PROFILE.packageId,
        expectedPublicKey: providerPublicKey,
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

  // Subscribe the full current grid under stable client_ids. Each id is derived
  // from the provider package and complete subscription descriptor; each
  // acknowledgement is checked before the stream is trusted.
  #subscribeBsGrid(): void {
    const ws = this.#bs;
    if (!ws) return;
    const active = this.#expiries.filter((ms) => ms > Date.now());
    const spot = blockScholesSpotSubscription();
    const forwards = active.map(blockScholesForwardSubscription);
    const svis: BlockScholesSubscription[] = active.map((ms) => ({
      expectedSid: sidHex(
        sviSid(BS_PROVIDER_PROFILE.packageId, PREDICT_BLOCK_SCHOLES_BASE_ASSET, BigInt(ms)),
      ),
      request: {
        feed: "model.params",
        exchange: "composite",
        asset: "option",
        base_asset: PREDICT_BLOCK_SCHOLES_BASE_ASSET,
        model: "SVI",
        expiry: isoSec(ms),
      },
    }));
    const nextRoutes = new Map<string, BsRoute>();
    nextRoutes.set(spot.expectedSid, { kind: "spot" });
    active.forEach((expiryMs, index) => {
      nextRoutes.set(forwards[index].expectedSid, { kind: "forward", expiryMs });
      nextRoutes.set(svis[index].expectedSid, { kind: "svi", expiryMs });
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

  #sendSubscription(id: number, clientId: string, batch: BlockScholesSubscription[]): void {
    const ws = this.#bs;
    if (!ws) return;
    const expectedSids = new Set(batch.map((item) => item.expectedSid));
    const expectedItems = new Map(
      batch.map((item) => [item.expectedSid, item.request]),
    );
    this.#pendingAcks.set(id, {
      clientId,
      expectedSids,
      expectedItems,
      sentAtMs: Date.now(),
    });
    ws.send(JSON.stringify(
      blockScholesSubscribeRequest(id, clientId, batch.map((item) => item.request)),
    ));
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
          sviPublishedAtMs: svi.publishedAtMs,
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
      provider_profile: BS_PROVIDER_PROFILE.name,
      provider_network: BS_PROVIDER_PROFILE.network,
      provider_pkg_ver: BS_PROVIDER_PROFILE.pkgVer,
      verifier_package_id: BS_PROVIDER_PROFILE.packageId,
      signer_registry_id: BS_PROVIDER_PROFILE.registryId,
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
      return snapshotFrom(JSON.parse(readFileSync(this.path, "utf8")), this.#wanted);
    } catch {
      return null;
    }
  }
  stop(): void {}
}
