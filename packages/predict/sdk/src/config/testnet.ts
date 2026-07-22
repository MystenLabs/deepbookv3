import type { PredictConfig } from "./types.js";

/**
 * Testnet deployment constants. Pure data — every id below is public on-chain
 * data. Regenerate from the deployment record when a new package version ships.
 */
export const TESTNET_CONFIG: PredictConfig = {
	network: "testnet",
	packages: {
		predict: "0xdb3ef5a5129920e59c9b2ae25a77eddb48acd0e1c6307b97073f0e076016446e",
		account: "0xb9389eac8d59170ffd1427c1a66e5c8306263464fcc6615e825c1f5b3e15da3b",
		propbook: "0x8eb2adde1c91f8b7c9ba5e9b0a32bfb804510c342939c5f77458fd8143f9755b",
	},
	objects: {
		registry: "0x54afbf245caf42466cedb5756ed7816f34f544afdfa13579a862eccf3afa21ca",
		protocolConfig: "0x2325224629b4bd96d1f1d7ee937e07f8a06f861018a130bbb26db09cb0394cb6",
		poolVault: "0xfde98c636eb8a7aba59c3a238cfee6b576b7118d1e5ffa2952876c4b270a3a2a",
		oracleRegistry: "0xf3deaff68cbd081a35ec21653af6f671d2ad5f012f3b4d817d81752843374136",
		accountRegistry: "0x3c54d5b8b6bca376fc289121838ad02f8a5b3843242b9ad7e8f8245720e685a2",
	},
	quoteCoinType:
		"0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC",
	underlyings: {
		BTC: {
			symbol: "BTC",
			propbookUnderlyingId: 1,
			pythFeedId: "0xc78d7de16217d46d21b92ae475da799448be30b71a758dc6d7bb3ac2f1c35afb",
			bsSpotFeedId: "0xcdc5fa7364e60fd2504aa96f65b707dc0734e507a919b1a7d7d63164fd67b745",
			bsForwardFeedId: "0xe72c734ea8d8dcbc9183d9d8f96f51aaa1fb5034d5ed33ac60d67d261e15b48a",
			bsSviFeedId: "0xdc2f8270676bd05fb28491e8d4a41a495722fda7a454926dd66dbba256a21c69",
		},
	},
};
