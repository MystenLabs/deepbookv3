// Oracle lifecycle states
export type OracleState = "created" | "active" | "pending_settlement" | "settled";

// Oracle entry in packages.json
export interface OracleEntry {
  oracle_id: string;
  underlying: string;
  expiry_iso: string;
  expiry_ms: number;
  state: OracleState;
  first_update_ts: string | null;
}

// Package entry in packages.json (deployment manifest)
export interface PackageEntry {
  label: string;
  commit: string;
  package_id: string;
  predict_id: string;
  registry_id: string;
  admin_cap_id: string;
  deployer_cap_id: string;
  oracle_cap_id: string;
  manager_id: string;
  oracles: OracleEntry[];
  deployed_at: string;
  active: boolean;
  token_rev?: string;
}

// Fuzz mint parameters
export interface FuzzMint {
  package_id: string;
  predict_id: string;
  manager_id: string;
  oracle_id: string;
  expiry_ms: number;
  strike: number;
  is_up: boolean;
  quantity: number;
}

// Digest entry (written to digests/{pkg_id}.jsonl)
export interface DigestEntry {
  digest: string;
  ts: number;
  package_id: string;
  oracle_id: string;
  expiry_ms: number;
  strike: number;
  is_up: boolean;
  qty: number;
  status: "success" | "failure";
  gas_used: number;
  actual_cost: number | null;
  ask_price: number | null;
  error: string | null;
}

// Gas profile from replay
export interface GasProfileFunction {
  name: string;
  total_gas: number;
  self_gas: number;
}

export interface GasProfile {
  total_gas: number;
  functions: GasProfileFunction[];
}

// Replay result (written to replays/{pkg_id}.jsonl)
export interface ReplayResult {
  digest: string;
  ts: number;
  status: "success" | "failure";
  gas: {
    computation: number;
    storage: number;
    storage_rebate: number;
    total: number;
  };
  gas_profile: GasProfile | null;
  vault: {
    balance: number;
    total_mtm: number;
  } | null;
  mint: {
    strike: number;
    is_up: boolean;
    quantity: number;
    oracle_id: string;
  } | null;
  error: string | null;
}

// Oracle data entry (written to oracle-data/{date}.jsonl)
export interface OracleDataEntry {
  ts: number;
  spot: number;
  expiry: string;
  forward: number;
  svi: {
    a: number;
    b: number;
    rho: number;
    m: number;
    sigma: number;
  } | null;
  rfr: number;
}

// SVI params for on-chain calls (scaled to u64)
export interface ScaledSVIParams {
  a: bigint;
  b: bigint;
  rho: bigint;
  rho_negative: boolean;
  m: bigint;
  m_negative: boolean;
  sigma: bigint;
}

// Log entry structure
export type LogLevel = "debug" | "info" | "warn" | "error";

export interface LogEntry {
  ts: string;
  level: LogLevel;
  service: string;
  msg: string;
  meta?: Record<string, unknown>;
}
