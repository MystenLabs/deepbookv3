// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/**
 * Oracle Feed Storage Demo (TypeScript port)
 *
 * A TypeScript implementation demonstrating feed storage, identification, indexing,
 * updates, permission bitmasks, and extensible calculator routing with chained
 * dependencies for financial data oracles.
 */

import { createHash } from "crypto";

// =============================================================================
// Constants
// =============================================================================

const DAYS_IN_YEAR = 365.0;
const SECONDS_IN_YEAR = DAYS_IN_YEAR * 24 * 60 * 60;
const FIVE_MIN_IN_YEARS = (5 * 60) / SECONDS_IN_YEAR;

const API_BASE_URL = "https://prod-data.blockscholes.com";
const API_KEY = process.env.BLOCKSCHOLES_API_KEY ?? "";
const DOMESTIC_RATE = 0.035;

// =============================================================================
// API Client
// =============================================================================

async function apiRequest(
  endpoint: string,
  payload: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const url = `${API_BASE_URL}${endpoint}`;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "X-API-Key": API_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    throw new Error(`API request failed: ${response.status} ${response.statusText}`);
  }
  return response.json() as Promise<Record<string, unknown>>;
}

export interface SVIParamsResult {
  timestamp: number;
  a: number;
  b: number;
  rho: number;
  m: number;
  sigma: number;
}

export interface PriceResult {
  timestamp: number;
  price: number;
}

/**
 * Fetch SVI model parameters for a given expiry.
 */
export async function fetchSVIParams(expiryIso: string): Promise<SVIParamsResult> {
  const payload = {
    exchange: "composite",
    base_asset: "BTC",
    model: "SVI",
    expiry: expiryIso,
    start: "LATEST",
    end: "LATEST",
    frequency: "1m",
    options: {
      format: { timestamp: "s", hexify: false, decimals: 5 },
    },
  };
  const data = await apiRequest("/api/v1/modelparams", payload);
  const rows = data.data as Array<Record<string, number>>;
  const row = rows[0];
  return {
    timestamp: row.timestamp,
    a: row.alpha,
    b: row.beta,
    rho: row.rho,
    m: row.m,
    sigma: row.sigma,
  };
}

/**
 * Fetch forward (futures mark) price for a given expiry.
 */
export async function fetchForwardPrice(expiryIso: string): Promise<PriceResult> {
  const payload = {
    base_asset: "BTC",
    asset_type: "future",
    expiry: expiryIso,
    start: "LATEST",
    end: "LATEST",
    frequency: "1m",
    options: {
      format: { timestamp: "s", hexify: false, decimals: 5 },
    },
  };
  const data = await apiRequest("/api/v1/price/mark", payload);
  const rows = data.data as Array<Record<string, number>>;
  const row = rows[0];
  return { timestamp: row.timestamp, price: row.v };
}

/**
 * Fetch current BTC spot index price.
 */
export async function fetchSpotPrice(): Promise<PriceResult> {
  const payload = {
    base_asset: "BTC",
    asset_type: "spot",
    start: "LATEST",
    end: "LATEST",
    frequency: "1m",
    options: {
      format: { timestamp: "s", hexify: false, decimals: 5 },
    },
  };
  const data = await apiRequest("/api/v1/price/index", payload);
  const rows = data.data as Array<Record<string, number>>;
  const row = rows[0];
  return { timestamp: row.timestamp, price: row.v };
}

// =============================================================================
// Core Data Structures
// =============================================================================

export enum FeedType {
  IV = 0,
  FORWARD = 1,
  SVI_PARAMS = 2,
  OPTION_PRICE = 3,
  SPOT = 4,
  DOMESTIC_RATE = 5,
}

export enum SVIParam {
  A = 0,
  B = 1,
  RHO = 2,
  M = 3,
  SIGMA = 4,
}

export interface FeedParameters {
  enumerable: number[];
  other: Record<string, number | string | boolean>;
}

export interface Feed {
  id: number;
  parameters: FeedParameters;
}

export interface FeedData {
  value: number;
  timestamp: number;
}

function makeFeedParams(
  enumerable: number[] = [],
  other: Record<string, number | string | boolean> = {},
): FeedParameters {
  return { enumerable, other };
}

function makeFeed(id: number, parameters?: FeedParameters): Feed {
  return { id, parameters: parameters ?? makeFeedParams() };
}

// =============================================================================
// Data Storage
// =============================================================================

class DataStorage {
  private data: number[] = [];
  private timestamps: number[] = [];
  private feedIndexes = new Map<string, number>(); // feed_key -> 1-based index
  version = 0;

  private getFeedKey(feed: Feed): string {
    const raw = `${feed.id}:${this.version}:${JSON.stringify(feed.parameters.enumerable)}:${JSON.stringify(feed.parameters.other)}`;
    return createHash("sha256").update(raw).digest("hex");
  }

  getLatestFeedData(feed: Feed): FeedData {
    const key = this.getFeedKey(feed);
    const index = this.feedIndexes.get(key);
    if (index === undefined || index === 0) {
      throw new Error(`Feed not found: ${JSON.stringify(feed)}`);
    }
    const idx = index - 1;
    return { value: this.data[idx], timestamp: this.timestamps[idx] };
  }

  addFeedWithValue(
    feed: Feed,
    value: number,
    timestamp: number,
    targetIndex?: number,
  ): number {
    const key = this.getFeedKey(feed);
    if (this.feedIndexes.has(key)) {
      throw new Error(`Feed already exists: ${JSON.stringify(feed)}`);
    }

    if (targetIndex !== undefined) {
      this.data[targetIndex] = value;
      this.timestamps[targetIndex] = timestamp;
      this.feedIndexes.set(key, targetIndex + 1);
      return targetIndex + 1;
    }

    this.data.push(value);
    this.timestamps.push(timestamp);
    const oneBasedIndex = this.data.length;
    this.feedIndexes.set(key, oneBasedIndex);
    return oneBasedIndex;
  }

  updateDataForFeed(feed: Feed, value: number, timestamp: number): void {
    const key = this.getFeedKey(feed);
    const index = this.feedIndexes.get(key);
    if (index === undefined || index === 0) {
      throw new Error(`Feed not found: ${JSON.stringify(feed)}`);
    }
    const idx = index - 1;
    this.data[idx] = value;
    this.timestamps[idx] = timestamp;
  }

  removeFeed(feed: Feed): void {
    const key = this.getFeedKey(feed);
    this.feedIndexes.delete(key);
  }

  resetAllData(): void {
    this.data = [];
    this.timestamps = [];
    this.feedIndexes.clear();
    this.version++;
  }

  feedCount(): number {
    return this.feedIndexes.size;
  }
}

// =============================================================================
// Calculator Interface & Derived Data Provider
// =============================================================================

interface Calculator {
  NUM_INPUTS: number;
  calculate(
    timestamp: number,
    inputData: number[],
    parameters: FeedParameters,
  ): number;
  getInputFeedParameters(parameters: FeedParameters): FeedParameters[];
}

interface CalculatorEntry {
  handler: Calculator;
  inputFeedIds: number[];
}

class DerivedDataProvider {
  private storage: DataStorage;
  private calculators = new Map<number, CalculatorEntry>();

  constructor(storage: DataStorage) {
    this.storage = storage;
  }

  addCalculator(
    outputFeedId: number,
    inputFeedIds: number[],
    handler: Calculator,
  ): void {
    this.calculators.set(outputFeedId, { handler, inputFeedIds });
  }

  getLatestFeedData(feed: Feed): FeedData {
    const entry = this.calculators.get(feed.id);
    if (!entry) {
      return this.storage.getLatestFeedData(feed);
    }

    const { handler, inputFeedIds } = entry;
    const inputParams = handler.getInputFeedParameters(feed.parameters);
    const inputData: number[] = [];
    let minTimestamp = Infinity;

    for (let i = 0; i < inputFeedIds.length; i++) {
      const inputFeed = makeFeed(inputFeedIds[i], inputParams[i]);
      const data = this.getLatestFeedData(inputFeed);
      inputData.push(data.value);
      if (data.timestamp < minTimestamp) minTimestamp = data.timestamp;
    }

    const result = handler.calculate(minTimestamp, inputData, feed.parameters);
    return { value: result, timestamp: minTimestamp };
  }

  isDerived(feedId: number): boolean {
    return this.calculators.has(feedId);
  }
}

// =============================================================================
// Math Helpers
// =============================================================================

function computeTimeToExpiry(
  currentTimestamp: number,
  expiryTimestamp: number,
): number {
  return Math.max(0, (expiryTimestamp - currentTimestamp) / SECONDS_IN_YEAR);
}

/**
 * Standard normal CDF approximation (Abramowitz & Stegun).
 */
function normalCdf(x: number): number {
  const a1 = 0.254829592;
  const a2 = -0.284496736;
  const a3 = 1.421413741;
  const a4 = -1.453152027;
  const a5 = 1.061405429;
  const p = 0.3275911;

  const sign = x < 0 ? -1 : 1;
  const absX = Math.abs(x);
  const t = 1.0 / (1.0 + p * absX);
  const y =
    1.0 -
    ((((a5 * t + a4) * t + a3) * t + a2) * t + a1) * t * Math.exp(-absX * absX / 2);
  return 0.5 * (1.0 + sign * y);
}

/**
 * Standard normal PDF.
 */
function normalPdf(x: number): number {
  return Math.exp(-0.5 * x * x) / Math.sqrt(2 * Math.PI);
}

// =============================================================================
// Option Pricing Helper
// =============================================================================

type OptionType = "C" | "P";
type OptionStyle = "vanilla" | "digital";

interface OptionPriceResult {
  premium: number;
  delta: number;
  gamma: number;
  vega: number;
  theta: number;
  volga: number;
  vanna: number;
}

function computeOptionPrice(
  spot: number,
  forward: number,
  strike: number,
  vol: number,
  t: number,
  rD: number,
  opType: OptionType,
  style: OptionStyle,
): OptionPriceResult {
  const phi = opType === "C" ? 1 : -1;
  const discount = Math.exp(-rD * t);

  if (vol <= 0 || t <= 0) {
    let intrinsic: number;
    if (style === "digital") {
      intrinsic = phi * (forward - strike) > 0 ? discount : 0;
    } else {
      intrinsic = discount * Math.max(phi * (forward - strike), 0);
    }
    return {
      premium: intrinsic,
      delta: 0,
      gamma: 0,
      vega: 0,
      theta: 0,
      volga: 0,
      vanna: 0,
    };
  }

  const sqrtT = Math.sqrt(t);
  const volSqrtT = vol * sqrtT;

  const d1 = (Math.log(forward / strike) + 0.5 * vol * vol * t) / volSqrtT;
  const d2 = d1 - volSqrtT;

  // For digital options, the relevant "d" for pricing is d2 (measuring)
  const dM = d2;

  let premium: number;
  let delta: number;
  let gamma: number;
  let vega: number;
  let theta: number;
  let volga: number;
  let vanna: number;

  if (style === "digital") {
    // Digital option: discounted probability of finishing ITM
    premium = discount * normalCdf(phi * dM);
    const nDm = normalPdf(dM);
    delta = (discount * phi * nDm) / (spot * volSqrtT);
    gamma =
      (-discount * phi * nDm * (1 + dM / volSqrtT)) /
      (spot * spot * volSqrtT);
    vega = -discount * phi * nDm * (dM / vol + sqrtT);
    theta =
      discount *
      (rD * normalCdf(phi * dM) + phi * nDm * (dM / (2 * t) - rD / volSqrtT));
    const dvdm = -dM / vol - sqrtT;
    volga = -discount * phi * ((-dM * nDm * dvdm) / vol + nDm * dvdm);
    vanna =
      discount *
      phi *
      nDm *
      (dM / (spot * volSqrtT * vol) + 1 / (spot * vol));
  } else {
    // Vanilla option: standard Black-Scholes
    const Nd1 = normalCdf(phi * d1);
    const Nd2 = normalCdf(phi * d2);
    const nd1 = normalPdf(d1);

    premium = discount * phi * (forward * Nd1 - strike * Nd2);
    delta = discount * phi * Nd1 * (forward / spot);
    gamma = (discount * nd1 * forward) / (spot * spot * volSqrtT);
    vega = discount * forward * nd1 * sqrtT;
    theta =
      -discount * forward * nd1 * vol / (2 * sqrtT) +
      rD * discount * phi * (forward * Nd1 - strike * Nd2);
    volga = vega * ((d1 * d2) / vol);
    vanna = (-discount * nd1 * d2) / vol;
  }

  return { premium, delta, gamma, vega, theta, volga, vanna };
}

// =============================================================================
// Calculators
// =============================================================================

class SVIImpliedVolCalculator implements Calculator {
  NUM_INPUTS = 6; // forward + 5 SVI params

  calculate(
    timestamp: number,
    inputData: number[],
    parameters: FeedParameters,
  ): number {
    if (inputData.length !== this.NUM_INPUTS) {
      throw new Error(`Expected ${this.NUM_INPUTS} inputs, got ${inputData.length}`);
    }

    const forward = inputData[0];
    const sviA = inputData[1];
    const sviB = inputData[2];
    const sviRho = inputData[3];
    const sviM = inputData[4];
    const sviSigma = inputData[5];

    const expiryTimestamp = Number(parameters.other.expiry_timestamp ?? 0);
    const strike = Number(parameters.other.strike ?? forward);
    const timeToExpiry = computeTimeToExpiry(timestamp, expiryTimestamp);

    if (timeToExpiry <= 0) return 0.0;

    const logK = forward > 0 ? Math.log(strike / forward) : 0.0;
    const term1 = sviRho * (logK - sviM);
    const term2 = Math.sqrt((logK - sviM) ** 2 + sviSigma ** 2);
    const totalVar = sviA + sviB * (term1 + term2);

    return Math.sqrt(totalVar / timeToExpiry);
  }

  getInputFeedParameters(parameters: FeedParameters): FeedParameters[] {
    const forwardParams = makeFeedParams(
      parameters.enumerable.slice(0, 2),
      { expiry_timestamp: parameters.other.expiry_timestamp ?? 0 },
    );
    const baseEnum = parameters.enumerable.slice(0, 2);
    return [
      forwardParams,
      makeFeedParams([...baseEnum, SVIParam.A]),
      makeFeedParams([...baseEnum, SVIParam.B]),
      makeFeedParams([...baseEnum, SVIParam.RHO]),
      makeFeedParams([...baseEnum, SVIParam.M]),
      makeFeedParams([...baseEnum, SVIParam.SIGMA]),
    ];
  }
}

class OptionPriceCalculator implements Calculator {
  NUM_INPUTS = 4; // spot, forward, iv, domestic_rate

  calculate(
    timestamp: number,
    inputData: number[],
    parameters: FeedParameters,
  ): number {
    if (inputData.length !== this.NUM_INPUTS) {
      throw new Error(`Expected ${this.NUM_INPUTS} inputs, got ${inputData.length}`);
    }

    const spot = inputData[0];
    const forward = inputData[1];
    const iv = inputData[2];
    const domesticRate = inputData[3];

    const expiryTimestamp = Number(parameters.other.expiry_timestamp ?? 0);
    const strike = Number(parameters.other.strike ?? forward);
    const isCall = Boolean(parameters.other.is_call ?? true);
    const isDigital = Boolean(parameters.other.is_digital ?? false);

    const timeToExpiry = computeTimeToExpiry(timestamp, expiryTimestamp);
    if (timeToExpiry <= 0) return 0.0;

    if (timeToExpiry < FIVE_MIN_IN_YEARS) {
      if (isCall) return Math.max(spot - strike, 0.0);
      return Math.max(strike - spot, 0.0);
    }

    if (iv <= 0) return 0.0;

    const opType: OptionType = isCall ? "C" : "P";
    const style: OptionStyle = isDigital ? "digital" : "vanilla";

    const result = computeOptionPrice(
      spot,
      forward,
      strike,
      iv,
      timeToExpiry,
      domesticRate,
      opType,
      style,
    );
    return result.premium;
  }

  getInputFeedParameters(parameters: FeedParameters): FeedParameters[] {
    const base = makeFeedParams(parameters.enumerable.slice(0, 2));
    const forwardParams = makeFeedParams(
      parameters.enumerable.slice(0, 2),
      { expiry_timestamp: parameters.other.expiry_timestamp ?? 0 },
    );
    return [base, forwardParams, parameters, base];
  }
}

// =============================================================================
// Permission Bitmask Utilities
// =============================================================================

function isAuthorizedForParameter(bitmask: number, value: number): boolean {
  return ((1 << value) & bitmask) !== 0;
}

class PermissionManager {
  private permissions = new Map<string, Map<number, number[]>>();

  grant(address: string, feedId: number, paramBitmasks: number[]): void {
    if (!this.permissions.has(address)) {
      this.permissions.set(address, new Map());
    }
    this.permissions.get(address)!.set(feedId, paramBitmasks);
  }

  revoke(address: string, feedId: number): void {
    this.permissions.get(address)?.delete(feedId);
  }

  checkAccess(address: string, feed: Feed): boolean {
    const addrPerms = this.permissions.get(address);
    if (!addrPerms) return false;

    const bitmasks = addrPerms.get(feed.id);
    if (!bitmasks) return false;

    for (let i = 0; i < feed.parameters.enumerable.length; i++) {
      if (i >= bitmasks.length) return false;
      if (!isAuthorizedForParameter(bitmasks[i], feed.parameters.enumerable[i])) {
        return false;
      }
    }
    return true;
  }
}

// =============================================================================
// Demonstration
// =============================================================================

function tsToIso(ts: number): string {
  return new Date(ts * 1000).toISOString().replace(".000Z", "Z");
}

async function main(): Promise<void> {
  console.log("=".repeat(70));
  console.log("Oracle Feed Storage Demo (TypeScript)");
  console.log("=".repeat(70));

  // -------------------------------------------------------------------------
  // [1] Initialize Storage
  // -------------------------------------------------------------------------
  const storage = new DataStorage();
  console.log(`\n[1] Created DataStorage (version=${storage.version})`);

  // -------------------------------------------------------------------------
  // [2] Fetch Live Data from API & Add Base Feeds
  // -------------------------------------------------------------------------
  const expiryIso = "2026-06-26T08:00:00.000Z";
  const expiryJun26 = Math.floor(
    new Date(expiryIso).getTime() / 1000,
  );

  console.log("\n[2] Fetching live data from BlockScholes API...");

  // Fetch spot price
  const spotData = await fetchSpotPrice();
  const spotValue = spotData.price;
  const spotTimestamp = Math.floor(spotData.timestamp);
  console.log(`    SPOT: ts=${spotTimestamp} (${tsToIso(spotTimestamp)})`);

  // Fetch forward price
  const forwardData = await fetchForwardPrice(expiryIso);
  const forwardValue = forwardData.price;
  const forwardTimestamp = Math.floor(forwardData.timestamp);
  console.log(`    FORWARD: ts=${forwardTimestamp} (${tsToIso(forwardTimestamp)})`);

  // Fetch SVI parameters
  const sviData = await fetchSVIParams(expiryIso);
  const sviTimestamp = Math.floor(sviData.timestamp);
  const { a: sviA, b: sviB, rho: sviRho, m: sviM, sigma: sviSigma } = sviData;
  console.log(`    SVI: ts=${sviTimestamp} (${tsToIso(sviTimestamp)})`);

  // Reference timestamp
  const refTimestamp = Math.min(spotTimestamp, forwardTimestamp, sviTimestamp);
  const timeToExpiryYears = (expiryJun26 - refTimestamp) / SECONDS_IN_YEAR;
  console.log(
    `    Reference ts (min): ${refTimestamp} (${tsToIso(refTimestamp)}) -> TTX=${timeToExpiryYears.toFixed(4)}y`,
  );

  // Add feeds to storage
  const baseParams = makeFeedParams([0, 1]);

  const spotFeed = makeFeed(FeedType.SPOT, baseParams);
  storage.addFeedWithValue(spotFeed, spotValue, spotTimestamp);
  console.log(
    `    Added SPOT feed: $${storage.getLatestFeedData(spotFeed).value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`,
  );

  const domesticRateFeed = makeFeed(FeedType.DOMESTIC_RATE, baseParams);
  storage.addFeedWithValue(domesticRateFeed, DOMESTIC_RATE, spotTimestamp);
  console.log(
    `    Added DOMESTIC_RATE feed: ${(storage.getLatestFeedData(domesticRateFeed).value * 100).toFixed(2)}%`,
  );

  const forwardParams = makeFeedParams([0, 1], { expiry_timestamp: expiryJun26 });
  const forwardFeed = makeFeed(FeedType.FORWARD, forwardParams);
  storage.addFeedWithValue(forwardFeed, forwardValue, forwardTimestamp);
  console.log(`    Added FORWARD feed (26JUN26 expiry): $${forwardValue.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);

  // Add SVI parameters
  const sviAFeed = makeFeed(FeedType.SVI_PARAMS, makeFeedParams([0, 1, SVIParam.A]));
  const sviBFeed = makeFeed(FeedType.SVI_PARAMS, makeFeedParams([0, 1, SVIParam.B]));
  const sviRhoFeed = makeFeed(FeedType.SVI_PARAMS, makeFeedParams([0, 1, SVIParam.RHO]));
  const sviMFeed = makeFeed(FeedType.SVI_PARAMS, makeFeedParams([0, 1, SVIParam.M]));
  const sviSigmaFeed = makeFeed(FeedType.SVI_PARAMS, makeFeedParams([0, 1, SVIParam.SIGMA]));

  storage.addFeedWithValue(sviAFeed, sviA, sviTimestamp);
  storage.addFeedWithValue(sviBFeed, sviB, sviTimestamp);
  storage.addFeedWithValue(sviRhoFeed, sviRho, sviTimestamp);
  storage.addFeedWithValue(sviMFeed, sviM, sviTimestamp);
  storage.addFeedWithValue(sviSigmaFeed, sviSigma, sviTimestamp);
  console.log(
    `    Added SVI params: a=${sviA.toFixed(5)}, b=${sviB.toFixed(5)}, rho=${sviRho.toFixed(5)}, m=${sviM.toFixed(5)}, sigma=${sviSigma.toFixed(5)}`,
  );
  console.log(`    Storage now has ${storage.feedCount()} feeds`);

  // -------------------------------------------------------------------------
  // [3] Set Up Derived Data Provider
  // -------------------------------------------------------------------------
  const derived = new DerivedDataProvider(storage);
  console.log("\n[3] Created DerivedDataProvider");

  derived.addCalculator(
    FeedType.IV,
    [
      FeedType.FORWARD,
      FeedType.SVI_PARAMS,
      FeedType.SVI_PARAMS,
      FeedType.SVI_PARAMS,
      FeedType.SVI_PARAMS,
      FeedType.SVI_PARAMS,
    ],
    new SVIImpliedVolCalculator(),
  );
  console.log(
    "    Registered SVIImpliedVolCalculator: FORWARD + SVI[a,b,rho,m,sigma] -> IV",
  );

  derived.addCalculator(
    FeedType.OPTION_PRICE,
    [FeedType.SPOT, FeedType.FORWARD, FeedType.IV, FeedType.DOMESTIC_RATE],
    new OptionPriceCalculator(),
  );
  console.log(
    "    Registered OptionPriceCalculator: SPOT + FORWARD + IV + DOMESTIC_RATE -> OPTION_PRICE",
  );

  // -------------------------------------------------------------------------
  // [4] Query Derived Data (Chained Resolution)
  // -------------------------------------------------------------------------
  console.log("\n[4] Querying derived feeds (demonstrates chained resolution)");

  const forwardDataStored = storage.getLatestFeedData(forwardFeed);
  console.log(
    `    FORWARD (26JUN26): $${forwardDataStored.value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} (from storage)`,
  );

  // IV for ATM strike
  const atmStrike = forwardValue;
  const ivParamsAtm = makeFeedParams([0, 1], {
    expiry_timestamp: expiryJun26,
    strike: atmStrike,
  });
  const ivFeedAtm = makeFeed(FeedType.IV, ivParamsAtm);
  const ivDataAtm = derived.getLatestFeedData(ivFeedAtm);
  console.log(
    `    IV (26JUN26, ATM K=${atmStrike.toLocaleString("en-US", { maximumFractionDigits: 0 })}): ${(ivDataAtm.value * 100).toFixed(2)}%`,
  );

  // IV for OTM strike
  const otmStrike = forwardValue + 10000;
  const ivParamsOtm = makeFeedParams([0, 1], {
    expiry_timestamp: expiryJun26,
    strike: otmStrike,
  });
  const ivFeedOtm = makeFeed(FeedType.IV, ivParamsOtm);
  const ivDataOtm = derived.getLatestFeedData(ivFeedOtm);
  console.log(
    `    IV (26JUN26, OTM K=${otmStrike.toLocaleString("en-US", { maximumFractionDigits: 0 })}): ${(ivDataOtm.value * 100).toFixed(2)}% <- SVI smile effect`,
  );
  console.log(
    "    Chain: FORWARD(storage) + SVI -> IV, SPOT+FORWARD+IV+DOMESTIC_RATE -> PRICE",
  );

  // -------------------------------------------------------------------------
  // [5] Option Pricing (Vanilla & Digital)
  // -------------------------------------------------------------------------
  console.log("\n[5] Option pricing (Vanilla & Digital, Call & Put)");

  function getOptionPrice(
    strike: number,
    isCall: boolean,
    isDigital: boolean,
  ): number {
    const params = makeFeedParams([0, 1], {
      expiry_timestamp: expiryJun26,
      strike,
      is_call: isCall,
      is_digital: isDigital,
    });
    const feed = makeFeed(FeedType.OPTION_PRICE, params);
    return derived.getLatestFeedData(feed).value;
  }

  // ATM options
  console.log(`\n    ATM (K=${atmStrike.toLocaleString("en-US", { maximumFractionDigits: 0 })}):`);
  console.log(`      Vanilla Call: $${getOptionPrice(atmStrike, true, false).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);
  console.log(`      Vanilla Put:  $${getOptionPrice(atmStrike, false, false).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);
  console.log(`      Digital Call: ${getOptionPrice(atmStrike, true, true).toFixed(4)}`);
  console.log(`      Digital Put:  ${getOptionPrice(atmStrike, false, true).toFixed(4)}`);

  // OTM options
  console.log(`\n    OTM (K=${otmStrike.toLocaleString("en-US", { maximumFractionDigits: 0 })}):`);
  console.log(`      Vanilla Call: $${getOptionPrice(otmStrike, true, false).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);
  console.log(`      Vanilla Put:  $${getOptionPrice(otmStrike, false, false).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);
  console.log(`      Digital Call: ${getOptionPrice(otmStrike, true, true).toFixed(4)}`);
  console.log(`      Digital Put:  ${getOptionPrice(otmStrike, false, true).toFixed(4)}`);

  // -------------------------------------------------------------------------
  // [6] Update Base Feed & Re-query
  // -------------------------------------------------------------------------
  console.log("\n[6] Update SPOT & FORWARD prices and re-query derived values");
  const newSpot = spotValue + 5000.0;
  const newForward = forwardValue + 5000.0;
  storage.updateDataForFeed(spotFeed, newSpot, spotTimestamp + 100);
  console.log(
    `    Updated SPOT: $${storage.getLatestFeedData(spotFeed).value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} (+5k)`,
  );

  storage.updateDataForFeed(forwardFeed, newForward, forwardTimestamp + 100);
  console.log(`    Updated FORWARD (26JUN26): $${newForward.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} (+5k)`);

  const newAtmStrike = newForward;
  const newOtmStrike = newForward + 10000;
  console.log(`\n    New ATM (K=${newAtmStrike.toLocaleString("en-US", { maximumFractionDigits: 0 })}):`);
  console.log(`      Vanilla Call: $${getOptionPrice(newAtmStrike, true, false).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);
  console.log(`      Vanilla Put:  $${getOptionPrice(newAtmStrike, false, false).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);
  console.log(`      Digital Call: ${getOptionPrice(newAtmStrike, true, true).toFixed(4)}`);
  console.log(`      Digital Put:  ${getOptionPrice(newAtmStrike, false, true).toFixed(4)}`);

  console.log(`\n    New OTM (K=${newOtmStrike.toLocaleString("en-US", { maximumFractionDigits: 0 })}):`);
  console.log(`      Vanilla Call: $${getOptionPrice(newOtmStrike, true, false).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);
  console.log(`      Vanilla Put:  $${getOptionPrice(newOtmStrike, false, false).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);
  console.log(`      Digital Call: ${getOptionPrice(newOtmStrike, true, true).toFixed(4)}`);
  console.log(`      Digital Put:  ${getOptionPrice(newOtmStrike, false, true).toFixed(4)}`);

  // -------------------------------------------------------------------------
  // [7] Permission Bitmask Demonstration
  // -------------------------------------------------------------------------
  console.log("\n[7] Permission bitmask demonstration");
  const perms = new PermissionManager();

  perms.grant("0xAlice", FeedType.SPOT, [0b0001, 0b0010]);
  console.log("    Granted 0xAlice: SPOT for source=0, asset=1");

  const allowedFeed = makeFeed(FeedType.SPOT, makeFeedParams([0, 1]));
  const deniedFeed = makeFeed(FeedType.SPOT, makeFeedParams([1, 1]));

  console.log(
    `    0xAlice read SPOT(source=0, asset=1): ${perms.checkAccess("0xAlice", allowedFeed)}`,
  );
  console.log(
    `    0xAlice read SPOT(source=1, asset=1): ${perms.checkAccess("0xAlice", deniedFeed)}`,
  );
  console.log(
    `    0xBob read SPOT(source=0, asset=1): ${perms.checkAccess("0xBob", allowedFeed)}`,
  );

  // -------------------------------------------------------------------------
  // [8] Extensibility: Add New Calculator at Runtime
  // -------------------------------------------------------------------------
  console.log("\n[8] Extensibility: Add custom calculator at runtime");

  const basisCalculator: Calculator = {
    NUM_INPUTS: 2,
    calculate(_timestamp: number, inputData: number[], _parameters: FeedParameters): number {
      return inputData[0] - inputData[1]; // forward - spot
    },
    getInputFeedParameters(parameters: FeedParameters): FeedParameters[] {
      const base = makeFeedParams(parameters.enumerable);
      return [parameters, base];
    },
  };

  const BASIS_FEED_ID = 100;
  derived.addCalculator(
    BASIS_FEED_ID,
    [FeedType.FORWARD, FeedType.SPOT],
    basisCalculator,
  );
  console.log(`    Registered BasisCalculator for feed ID ${BASIS_FEED_ID}`);

  const basisFeed = makeFeed(BASIS_FEED_ID, forwardParams);
  const basisData = derived.getLatestFeedData(basisFeed);
  console.log(
    `    BASIS (Forward - Spot, 26JUN26): $${basisData.value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`,
  );

  // -------------------------------------------------------------------------
  // [9] Reset Demonstration
  // -------------------------------------------------------------------------
  console.log(
    "\n[9] Reset storage (invalidates all feed keys via version increment)",
  );
  const oldVersion = storage.version;
  storage.resetAllData();
  console.log(`    Version changed: ${oldVersion} -> ${storage.version}`);
  console.log(`    Feed count after reset: ${storage.feedCount()}`);

  console.log("\n" + "=".repeat(70));
  console.log("Demo complete!");
  console.log("=".repeat(70));
}

// Only run the demo when this file is executed directly
const isMainModule =
  import.meta.url === `file://${process.argv[1]}` ||
  process.argv[1]?.endsWith("/blockscholes-oracle.ts");
if (isMainModule) {
  main().catch(console.error);
}
