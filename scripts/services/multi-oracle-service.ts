/**
 * Multi-Oracle Service — Public Interface
 *
 * Full implementation with on-chain oracle management is private.
 * This module exports the types and state machine for reference.
 */

export const OracleState = {
  EXPIRED: "EXPIRED",
  CREATING: "CREATING",
  UPDATING: "UPDATING",
  WAITING_FINALITY: "WAITING_FINALITY",
  FRESH: "FRESH",
  TRADE_READY: "TRADE_READY",
  ERROR: "ERROR",
  INACTIVE: "INACTIVE",
} as const;

export type OracleState = (typeof OracleState)[keyof typeof OracleState];

export interface OracleConfig {
  oracleId: string;
  asset: string;
  quoteAsset: string;
  minStrike: bigint;
  tickSize: bigint;
}

/**
 * Oracle state machine:
 *
 *   INACTIVE → (activate) → UPDATING → (update_prices) → WAITING_FINALITY
 *       ↓                                                      ↓
 *   EXPIRED ←──────────────────────────────────────────── FRESH / TRADE_READY
 *       ↓
 *   (rotate) → new oracle
 *
 * Full implementation handles:
 * - On-chain state validation
 * - Price updates via Move calls
 * - Oracle rotation before expiry
 * - Trade execution with pre-flight checks
 */
export class MultiOracleService {
  private states: Record<
    string,
    {
      currentState: OracleState;
      lastKnownVersion: string;
      lastKnownTimestamp: string;
    }
  > = {};

  constructor(
    packageId: string,
    oracleCapId: string,
    predictId: string,
    network: any = "testnet",
  ) {
    console.log(
      `[ORACLE] Public stub — full implementation manages on-chain oracles`,
    );
  }

  getOracleState(oracleId: string) {
    if (!this.states[oracleId]) {
      this.states[oracleId] = {
        currentState: OracleState.FRESH,
        lastKnownVersion: "0",
        lastKnownTimestamp: "0",
      };
    }
    return this.states[oracleId];
  }

  addPendingAction(action: any) {
    console.log(`[ORACLE] Public stub — pending action queued`);
  }

  async validateState(oracleId: string): Promise<OracleState> {
    console.log(
      `[ORACLE] Public stub — full implementation validates on-chain state`,
    );
    return OracleState.UPDATING;
  }

  async fetchData(asset: string, expiry: number) {
    throw new Error(
      `fetchData — full implementation fetches from Binance/Bybit`,
    );
  }

  async executeUpdate(oracleId: string, asset: string, expiry: number) {
    throw new Error(
      `executeUpdate — full implementation calls oracle::update_prices`,
    );
  }

  async executeTrade(oracleId: string) {
    throw new Error(
      `executeTrade — full implementation calls predict::mint`,
    );
  }

  async settleOracle(oracleId: string, asset: string) {
    throw new Error(
      `settleOracle — full implementation calls oracle::update_prices for settlement`,
    );
  }

  async activateOracle(oracleId: string) {
    throw new Error(
      `activateOracle — full implementation calls oracle::activate`,
    );
  }

  async rotateOracle(
    registryId: string,
    asset: string,
    minStrike: bigint,
    tickSize: bigint,
  ) {
    throw new Error(
      `rotateOracle — full implementation calls registry::create_oracle`,
    );
  }
}
