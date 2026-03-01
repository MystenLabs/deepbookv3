// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

export const adminCapOwner = {
  mainnet: "0xd0ec0b201de6b4e7f425918bbd7151c37fc1b06c59b3961a2a00db74f6ea865e",
  testnet: "0xb3d277c50f7b846a5f609a8d13428ae482b5826bb98437997373f3a0d60d280e",
};

export const upgradeCapOwner = {
  mainnet: "0x37f187e1e54e9c9b8c78b6c46a7281f644ebc62e75493623edcaa6d1dfcf64d2",
  testnet: "0xb3d277c50f7b846a5f609a8d13428ae482b5826bb98437997373f3a0d60d280e",
};

export const upgradeCapID = {
  mainnet: "0xdadf253cea3b91010e64651b03da6d56166a4f44b43bdd4e185c277658634483",
  testnet: "0x479467ad71ba0b7f93b38b26cb121fbd181ae2db8c91585d3572db4aaa764ffb",
};

export const adminCapID = {
  mainnet: "0xada554b8b712556b8509be47ac1bc04db9505c3532049a543721aca0c010a840",
  testnet: "0x29a62a5385c549dd8e9565312265d2bda0b8700c1560b3e34941671325daae77",
};

export const marginAdminCapID = {
  mainnet: "0x3ec65d06f0be30905cc1742b903aa497791c702820331db263176b74e74c95c8",
  testnet: "0x42a2e769541d272e624c54fff72b878fb0be670776c2b34ef07be5308480650e",
};

export const marginMaintainerCapID = {
  mainnet: "0xf44fb36ebfe03ff7696f8c17723bbc6af3db1e5eff7944aa65d092575851ca72",
  testnet: "",
};

export const suiMarginPoolCapID = {
  mainnet: "0x4894832150466e190359716e415f92d6260d4e86c5e29f919fff8b5afa6682cb",
  testnet: "",
};

export const usdcMarginPoolCapID = {
  mainnet: "0x3c6278f0b21ebf51cec6485e312123c1dbad6d89fca9bb7cfe027dad32c275d8",
  testnet: "",
};

export const deepMarginPoolCapID = {
  mainnet: "0xa9532986275e3eac41b8c59da91c29d591b017422b96071276e833f7c9ed855f",
  testnet: "",
};

export const walMarginPoolCapID = {
  mainnet: "0x8aa9345ea5b61e095e5de9dc5a498cf8c8cec9469d7916552b8772d313b41dc8",
  testnet: "",
};

export const suiUsdeMarginPoolCapID = {
  mainnet: "0x63f701fac292fc3a7a5c8a9da44f427ce55a6263bfdc6ba9b54b9cc4ef68c6cd",
  testnet: "",
};

export const liquidationAdminCapID = {
  mainnet: "0x21521b9ddc1cfc76b6f4c9462957b4d58a998a23eb100ab2821d27d55c60d0a9",
  testnet: "",
};

export const supplierCapID = {
  mainnet: "0xe0e64f2b0037304e29647fd5ef2c5ea758828a8e5aea73bb0bd5f227c1c20204",
  testnet: "",
};

// DUSDC test token
export const dusdcPackageID = {
  mainnet: "",
  testnet: "0x2ff52f1b7cc2d7332cead8f6b812e1f017047e00e9ca843979d92f70aeca75b1",
};

export const dusdcTreasuryCapID = {
  mainnet: "",
  testnet: "0x02becc90ac3a62e7197693a6faef8126e50b79fa47f95cc375d19a551f3af9c5",
};

// Predict package
export const predictPackageID = {
  mainnet: "",
  testnet: "0x01db8fc74ead463c7167f9c609af72e64ac4eeb0f6b9c05da17c16ad0fd348d0",
};

export const predictRegistryID = {
  mainnet: "",
  testnet: "0xc30b84b73d64472c19f12bc5357273ddce6d76ef04116306808b022078080d0a",
};

export const predictAdminCapID = {
  mainnet: "",
  testnet: "0x9ed9f87992ebf99e707f39105ba727bb33894a0e1c684810e1fb462f5d3e7d03",
};

export const predictUpgradeCapID = {
  mainnet: "",
  testnet: "0x082c8c4d6636848bfacbbce0bf73ba7df210574f1bf4b064d05af1b5a1d3a09b",
};

export const predictObjectID = {
  mainnet: "",
  testnet: "0x25970603328dd3a95a92596cac4d7baebae93f59fd4c51e95ebaae5540d94c8b",
};

export const predictOracleCapID = {
  mainnet: "",
  testnet: "0xb40eea2aec22bd62ece95342806c1ee18a826e29afdc859530fec3842faaa391",
};

export const predictOracleCapIDs: Record<string, string[]> = {
  mainnet: [],
  testnet: [], // populated by setupOracleCapLanes script
};

export const predictOracleID = {
  mainnet: "",
  testnet: "0xd1fa546d31733a6806374f004479a2c5b593c5912fe4a432729846cb9106ebba",
};
