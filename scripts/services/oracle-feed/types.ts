// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

export type Tier = "15m" | "1h" | "1d" | "1w";
export type OracleId = string;
export type CapId = string;
export type GasCoinId = string;
export type OracleStatus = "inactive" | "active" | "pending_settlement" | "settled";

export type OracleState = {
  id: OracleId;
  underlying: string;
  expiryMs: number;
  tier: Tier;
  status: OracleStatus;
  registeredCapIds: Set<CapId>;
};

export type PriceSample = { value: number; receivedAtMs: number };

export type PriceCache = {
  spot: PriceSample | null;
  forwards: Map<OracleId, PriceSample>;
};

export type SVIParams = { a: number; b: number; rho: number; m: number; sigma: number };

export type SVISample = {
  params: SVIParams;
  receivedAtMs: number;
  lastPushedAtMs: number | null;
};

export type SVICache = Map<OracleId, SVISample>;

export type Lane = {
  id: number;
  gasCoinId: GasCoinId;
  gasCoinVersion: string;
  gasCoinDigest: string;
  capId: CapId;
  available: boolean;
};

export type ServiceState = {
  oracles: Map<OracleId, OracleState>;
  lanes: Lane[];
  capIds: CapId[];
  priceCache: PriceCache;
  sviCache: SVICache;
  managerInFlight: boolean;
  laneHint: number;
  lastPushMs: number;
};

export type LogEvent =
  | "service_started" | "service_shutdown" | "service_fatal"
  | "lanes_ready" | "caps_created"
  | "oracle_discovered" | "oracle_created" | "oracle_activated"
  | "oracle_settled" | "oracle_compacted"
  | "tx_submitting" | "tx_submitted" | "tx_failed"
  | "tick_skipped_manager" | "tick_skipped_no_lane"
  | "tick_skipped_stale_prices" | "tick_skipped_empty"
  | "cache_summary" | "lane_summary"
  | "manager_started" | "manager_finished"
  | "ws_connecting" | "ws_connected" | "ws_auth_ok" | "ws_subscribed"
  | "ws_subscribe_error" | "ws_reconnect" | "ws_frame_dropped"
  | "health_ok" | "health_degraded";
