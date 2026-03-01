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
        "oracleId": "0x8b05d190880a499a96f26bb03ce3f59c45cf65ea890d69f77c26cd94cfd695a7",
        "expiry": "2026-03-06T08:00:00.000Z",
        "expiryMs": 1772784000000,
        "underlying": "0x2::sui::SUI"
    },
    {
        "oracleId": "0x7fc356dd17b5209cff7b68ca700fa9fce12cfe61b3c84efe1fd1178e58c76b9c",
        "expiry": "2026-03-13T08:00:00.000Z",
        "expiryMs": 1773388800000,
        "underlying": "0x2::sui::SUI"
    },
    {
        "oracleId": "0x7de9b59268e225b408a7043b7dde8fc917d5b5f873648f6ea141f01dcb9a8846",
        "expiry": "2026-03-20T08:00:00.000Z",
        "expiryMs": 1773993600000,
        "underlying": "0x2::sui::SUI"
    },
    {
        "oracleId": "0xe9c672a5750b3fb1fd82f43adcc6bfbbabc4f8fe245d74d62bb6dc501081290d",
        "expiry": "2026-03-27T08:00:00.000Z",
        "expiryMs": 1774598400000,
        "underlying": "0x2::sui::SUI"
    },
    {
        "oracleId": "0x410a85da5606f7456822d97785d94e2a75828205da38f52967dcb56ab6fd5188",
        "expiry": "2026-04-24T08:00:00.000Z",
        "expiryMs": 1777017600000,
        "underlying": "0x2::sui::SUI"
    }
],
  mainnet: [],
};
