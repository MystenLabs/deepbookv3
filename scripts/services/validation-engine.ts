/**
 * Validation Engine — Public Interface
 *
 * Full implementation with position tracking and settlement verification is private.
 * This module exports the types and a stub for integration testing.
 */

import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";

export const PositionState = {
  OPEN: "OPEN",
  WAITING_SETTLEMENT: "WAITING_SETTLEMENT",
  SETTLED: "SETTLED",
  CLAIMABLE: "CLAIMABLE",
  CLAIMED: "CLAIMED",
  FAILED: "FAILED",
} as const;

export type PositionState = (typeof PositionState)[keyof typeof PositionState];

export interface Position {
  positionId: string;
  digest: string;
  market: string;
  oracleId: string;
  direction: "UP" | "DOWN";
  state: PositionState;
  entryPrice: string;
  quantity: string;
  expiry: number;
  strike: string;
  createdAt: string;
  settledAt?: string;
  claimedAt?: string;
  rewardAmount?: string;
  claimAttempts?: number;
}

/**
 * ValidationEngine tracks positions and verifies settlement.
 * Full implementation handles on-chain verification, retry logic,
 * and state persistence.
 */
export class ValidationEngine {
  private positions: Position[] = [];

  constructor(client: SuiJsonRpcClient) {
    // Public stub — no persistence in public version
  }

  public logEvent(event: string, data: any) {
    console.log(`[JOURNAL] ${event.toUpperCase()}:`, data);
  }

  async trackMint(
    digest: string,
    oracleId: string,
    market: string,
    direction: "UP" | "DOWN",
    price: bigint,
    quantity: bigint,
    expiry: number,
    strike: bigint,
  ): Promise<Position | null> {
    console.log(
      `[TRACK] Public stub — full implementation tracks on-chain positions`,
    );
    return null;
  }

  getOpenPositions(): Position[] {
    return [];
  }

  getAllPositions(): Position[] {
    return this.positions;
  }

  async verifySettlement(oracleId: string) {
    console.log(
      `[SETTLE] Public stub — full implementation verifies on-chain settlement`,
    );
  }

  async markClaimed(positionId: string, digest: string, amount: bigint) {
    console.log(
      `[CLAIM] Public stub — full implementation marks positions claimed`,
    );
  }

  markFailed(positionId: string) {
    console.log(
      `[FAIL] Public stub — full implementation marks failed positions`,
    );
  }

  getMetrics() {
    return {
      total: 0,
      open: 0,
      settled: 0,
      claimable: 0,
      claimed: 0,
      successRate: "0.00%",
    };
  }
}
