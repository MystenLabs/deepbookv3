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
        "oracleId": "0xa796bd3c48ef8cccc37e213cf5639a20c2e802d34bc7e5f9f541819e8fe4a45c",
        "expiry": "2026-03-13T08:00:00.000Z",
        "expiryMs": 1773388800000,
        "underlying": "0x2::sui::SUI"
    },
    {
        "oracleId": "0xacc7604639b50b05e8d2511d35f7153a0fc6466cad0e05b868bc31f8e6d671d8",
        "expiry": "2026-03-20T08:00:00.000Z",
        "expiryMs": 1773993600000,
        "underlying": "0x2::sui::SUI"
    },
    {
        "oracleId": "0x623e2695969f34dcffe8fc8cdcd417537b5549aaabb43c121db3eabc5a2b5ca0",
        "expiry": "2026-03-27T08:00:00.000Z",
        "expiryMs": 1774598400000,
        "underlying": "0x2::sui::SUI"
    },
    {
        "oracleId": "0xe8ad8783796445149c09776f0ae8404b48ab1c9f191af64a81a03cc1d2d005a8",
        "expiry": "2026-04-24T08:00:00.000Z",
        "expiryMs": 1777017600000,
        "underlying": "0x2::sui::SUI"
    },
    {
        "oracleId": "0xd3a4e5e819dccc7c68c243f3f0eda1a8521ad7a4912104425d7a151b6a1acab4",
        "expiry": "2026-05-29T08:00:00.000Z",
        "expiryMs": 1780041600000,
        "underlying": "0x2::sui::SUI"
    },
    {
        "oracleId": "0x9434d52a2f8faba2d9723df9461426ab898fa6b8c7f715e6460d56dc9a3515b6",
        "expiry": "2026-06-26T08:00:00.000Z",
        "expiryMs": 1782460800000,
        "underlying": "0x2::sui::SUI"
    },
    {
        "oracleId": "0x78ae3139cd2273aa6a9e6325a1a160c5f65368073fe479a0e4bee2383cf67e36",
        "expiry": "2026-09-25T08:00:00.000Z",
        "expiryMs": 1790323200000,
        "underlying": "0x2::sui::SUI"
    },
    {
        "oracleId": "0x5525958a4ffa8ade210fbe0084a1dfd1db7870aa70a75c849df9ee1c2eb6844b",
        "expiry": "2026-12-25T08:00:00.000Z",
        "expiryMs": 1798185600000,
        "underlying": "0x2::sui::SUI"
    }
],
  mainnet: [],
};
