// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

export type OracleId = string;
export type CapId = string;
export type GasCoinId = string;

export type PriceSample = { value: number; receivedAtMs: number };

export type PriceCache = {
  spot: PriceSample | null;
  forwards: Map<OracleId, PriceSample>;
};

export type SVIParams = {
  a: number;
  b: number;
  rho: number;
  m: number;
  sigma: number;
};

export type SVISample = {
  params: SVIParams;
  receivedAtMs: number;
  lastPushedAtMs: number | null;
};

export type SVICache = Map<OracleId, SVISample>;

/// Minimal per-oracle state used by the executor: the oracle object ID we
/// push updates to, the underlying asset (used only for log context), and
/// the expiry so the executor can stop pushing after settlement.
export type OracleState = {
  id: OracleId;
  underlying: string;
  expiryMs: number;
};

export type Lane = {
  id: number;
  gasCoinId: GasCoinId;
  gasCoinVersion: string;
  gasCoinDigest: string;
  gasCoinBalanceApproxMist: number;
  available: boolean;
  lastTxDigest: string | null;
};

export type LaneState = {
  lanes: Lane[];
  nextHint: number;
};

export type ServiceState = {
  oracles: Map<OracleId, OracleState>;
  priceCache: PriceCache;
  sviCache: SVICache;
  lanes: LaneState;
  clock: { tickId: number };
};

export type LogEvent =
  | "tick_fired"
  | "tick_skipped_no_lane"
  | "tick_skipped_empty"
  | "tick_skipped_stale_prices"
  | "tx_submitted"
  | "tx_finalized"
  | "tx_failed"
  | "oracle_loaded"
  | "oracle_expired"
  | "ws_connecting"
  | "ws_connected"
  | "ws_auth_ok"
  | "ws_subscribed"
  | "ws_subscribe_error"
  | "ws_reconnect"
  | "ws_frame_dropped"
  | "lane_low"
  | "health_ok"
  | "health_degraded"
  | "service_started"
  | "service_shutdown"
  | "service_fatal";
