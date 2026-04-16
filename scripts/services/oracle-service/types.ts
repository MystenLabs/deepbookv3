export type Tier = "15m" | "1h" | "1d" | "1w";
export const ALL_TIERS: Tier[] = ["15m", "1h", "1d", "1w"];

export type OracleId = string;
export type CapId = string;
export type GasCoinId = string;

export type OracleStatus = "inactive" | "active" | "pending_settlement" | "settled";

export type OracleState = {
  id: OracleId;
  underlying: "BTC";
  expiryMs: number;
  tier: Tier;
  status: OracleStatus;
  lastTimestampMs: number;
  registeredCapIds: Set<CapId>;
  matrixCompacted: boolean;
};

export type OracleRegistry = {
  byId: Map<OracleId, OracleState>;
  byExpiry: Map<Tier, Map<number, OracleId>>;
};

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

export type Intent =
  | { kind: "create_oracle"; tier: Tier; expiryMs: number; retries: number }
  | { kind: "bootstrap_oracle"; oracleId: OracleId; retries: number }
  | { kind: "register_caps"; oracleId: OracleId; capIds: CapId[]; retries: number }
  | { kind: "activate"; oracleId: OracleId; retries: number }
  | { kind: "compact"; oracleId: OracleId; retries: number }
  | { kind: "settle_nudge"; oracleId: OracleId; retries: number };

export type IntentKind = Intent["kind"];

export function intentUsesAdminCap(kind: IntentKind): boolean {
  return kind === "create_oracle" || kind === "bootstrap_oracle" || kind === "register_caps";
}

export type IntentQueue = {
  pending: Intent[];
  inflight: Map<string, Intent[]>;   // txDigest → intents included
  deadLetter: Intent[];
};

export type Lane = {
  id: number;
  gasCoinId: GasCoinId;
  gasCoinBalanceApproxMist: number;
  capId: CapId;
  available: boolean;
  lastTxDigest: string | null;
};

export type LaneState = {
  lanes: Lane[];
  nextHint: number;
};

export type ServiceState = {
  registry: OracleRegistry;
  priceCache: PriceCache;
  sviCache: SVICache;
  intents: IntentQueue;
  lanes: LaneState;
  adminCapInFlight: boolean;
  clock: { tickId: number };
};

export type LogEvent =
  | "tick_fired"
  | "tick_skipped_no_lane"
  | "tick_skipped_empty"
  | "tx_submitted"
  | "tx_finalized"
  | "tx_failed"
  | "oracle_discovered"
  | "oracle_created"
  | "oracle_bootstrapped"
  | "oracle_activated"
  | "oracle_settled"
  | "oracle_compacted"
  | "cap_registered"
  | "intent_enqueued"
  | "intent_skipped_admin_cap"
  | "intent_retried"
  | "intent_failed_final"
  | "ws_connecting"
  | "ws_connected"
  | "ws_auth_ok"
  | "ws_subscribed"
  | "ws_subscribe_error"
  | "ws_reconnect"
  | "ws_frame_dropped"
  | "lane_excluded_create"
  | "lane_excluded_total"
  | "gas_pool_low"
  | "gas_pool_fatal"
  | "rotation_scheduled"
  | "health_ok"
  | "health_degraded"
  | "service_started"
  | "service_fatal";
