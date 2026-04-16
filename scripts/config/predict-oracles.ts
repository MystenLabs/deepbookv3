// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

export interface OracleEntry {
    oracleId: string;
    expiry: string; // ISO 8601
    expiryMs: number; // on-chain milliseconds
    underlying: string; // Move type arg
}

export const predictOracles: Record<string, OracleEntry[]> = {
    testnet: [],
    mainnet: [],
};
