// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

export interface OracleEntry {
    oracleId: string;
    expiry: string; // ISO 8601
    expiryMs: number; // on-chain milliseconds
    underlying: string; // Move type arg
}

export const predictOracles: Record<string, OracleEntry[]> = {
    testnet: [
    {
        "oracleId": "0xa1b8445734246d105d7028bafb0006f3214e98fa6e51c65f40bf9dde21829e25",
        "expiry": "2026-04-23T08:00:00.000Z",
        "expiryMs": 1776931200000,
        "underlying": "BTC"
    },
    {
        "oracleId": "0x0daa7a9e8ebe302c2788fbde69601271bb6aa3416704ffba06c636952e2fbbaf",
        "expiry": "2026-04-30T08:00:00.000Z",
        "expiryMs": 1777536000000,
        "underlying": "BTC"
    },
    {
        "oracleId": "0x5022da16acca1184e6e973d44eed6a34430cda98129cb7a68a9116b1dfc5bab8",
        "expiry": "2026-05-07T08:00:00.000Z",
        "expiryMs": 1778140800000,
        "underlying": "BTC"
    },
    {
        "oracleId": "0x268e46ca8cde92b352c0ede0f79655f85c13fc1dee5f50f23a6454d373440304",
        "expiry": "2026-05-14T08:00:00.000Z",
        "expiryMs": 1778745600000,
        "underlying": "BTC"
    },
    {
        "oracleId": "0x45701b610101c3793b59c12d20be634732c80c5bf35b81074078282f7093f92d",
        "expiry": "2026-05-21T08:00:00.000Z",
        "expiryMs": 1779350400000,
        "underlying": "BTC"
    }
],
    mainnet: [],
};
