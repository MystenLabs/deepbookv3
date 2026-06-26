TESTNET_DEPLOYMENT = {
    "network": "testnet",
    "chainId": "4c78adac",
    "packages": {
        "fixed_math": "0x6930d8eff504f15e45e7ceec3d504bfc1a6f1e1d4c02babe03c156f77b84523d",
        "block_scholes_oracle": "0x8192932b70d5946217d0f09aad44f84ad5c27ee4c1ca31b09f46200fbd31d3de",
        "account": "0xb9389eac8d59170ffd1427c1a66e5c8306263464fcc6615e825c1f5b3e15da3b",
        "propbook": "0x8eb2adde1c91f8b7c9ba5e9b0a32bfb804510c342939c5f77458fd8143f9755b",
        "predict": "0xdb3ef5a5129920e59c9b2ae25a77eddb48acd0e1c6307b97073f0e076016446e",
    },
    "linked": {
        "dusdc": "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a",
        "deep": "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8",
        "pyth_lazer": "0xf5bd2141967507050a91b58de3d95e77c432cd90d1799ee46effc27430a68c21",
        "wormhole": "0xd5afd4e456e5451f1ca1e7b3d734ce7a0a3b397811a6cb72a4bd1dfc387839f2",
    },
    "sharedObjects": {
        "account": {
            "account_registry::AccountRegistry": "0x3c54d5b8b6bca376fc289121838ad02f8a5b3843242b9ad7e8f8245720e685a2",
        },
        "propbook": {
            "registry::OracleRegistry": "0xf3deaff68cbd081a35ec21653af6f671d2ad5f012f3b4d817d81752843374136",
        },
        "predict": {
            "plp::PoolVault": "0xfde98c636eb8a7aba59c3a238cfee6b576b7118d1e5ffa2952876c4b270a3a2a",
            "protocol_config::ProtocolConfig": "0x2325224629b4bd96d1f1d7ee937e07f8a06f861018a130bbb26db09cb0394cb6",
            "registry::Registry": "0x54afbf245caf42466cedb5756ed7816f34f544afdfa13579a862eccf3afa21ca",
        },
    },
    "wiring": {
        "asset": {
            "name": "BTC_USD",
            "propbookUnderlyingId": 1,
            "pythLazerFeedId": 1,
            "blockScholesSourceId": 1,
            "pythFeedId": "0xc78d7de16217d46d21b92ae475da799448be30b71a758dc6d7bb3ac2f1c35afb",
            "blockScholesSpotFeedId": "0xcdc5fa7364e60fd2504aa96f65b707dc0734e507a919b1a7d7d63164fd67b745",
            "blockScholesForwardFeedId": "0xe72c734ea8d8dcbc9183d9d8f96f51aaa1fb5034d5ed33ac60d67d261e15b48a",
            "blockScholesSviFeedId": "0xdc2f8270676bd05fb28491e8d4a41a495722fda7a454926dd66dbba256a21c69",
        },
        "cadences": [
            {
                "id": 0,
                "name": "1m",
                "tickSize": "1000000000",
                "admissionTickSize": "10000000000",
                "maxExpiryAllocation": "50000000000",
                "initialExpiryCash": "10000000000",
                "windowSize": "3",
            },
            {
                "id": 1,
                "name": "5m",
                "tickSize": "1000000000",
                "admissionTickSize": "10000000000",
                "maxExpiryAllocation": "50000000000",
                "initialExpiryCash": "10000000000",
                "windowSize": "3",
            },
            {
                "id": 2,
                "name": "1h",
                "tickSize": "1000000000",
                "admissionTickSize": "10000000000",
                "maxExpiryAllocation": "250000000000",
                "initialExpiryCash": "50000000000",
                "windowSize": "3",
            },
        ],
    },
}
