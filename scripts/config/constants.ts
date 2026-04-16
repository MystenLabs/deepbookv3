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

export const usdSuiMarginPoolCapID = {
  mainnet: "0x44a74705863f509117c5dfa215b0eef2bae9f5273039f206bec4cf2ba005902d",
  testnet: "",
};

export const xbtcMarginPoolCapID = {
  mainnet: "0x2c419c0e02ed1a3ea6a1bbbba95b039680afc99eae6ae313a98bcc9f5a9caa58",
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

// --- Predict protocol ---
export const predictPackageID = { mainnet: "", testnet: "0x557ad48f98e33db0b0ea54cfb79c5edbfaf19a3e568342dc5ba1dae37a4aa749" };
export const predictRegistryID = { mainnet: "", testnet: "0x48a08b2d4b5f940ac3b8af2a13d39a86f58658fc2fe2ffc1606fe6b15dae4751" };
export const predictAdminCapID = { mainnet: "", testnet: "0xf715b17a1c61489c1094fa6934aeef133e6dbf11b63c46e1cb21f058d6292b8d" };
export const predictUpgradeCapID = { mainnet: "", testnet: "0xabc4b58d6083720ef3b24a8b5215c33ab55f3a6248363a538d958f7f832879d8" };
export const predictObjectID = { mainnet: "", testnet: "0x9f11242d6ad61679577b9d3a9df6ea68cc5eaf1c486e81199a304ad32570fa82" };
export const predictOracleCapID = { mainnet: "", testnet: "0x7efa929d2665d47f3dd6b4290d0b28a73a3337354e971e981dd70ae357599db2" };
export const predictOracleCapIDs: Record<string, string[]> = { mainnet: [], testnet: [] };
export const predictOracleID = { mainnet: "", testnet: "" };

// DUSDC test token
export const dusdcPackageID = { mainnet: "", testnet: "0xc70d8cb9a38025dc8d8810814f20707d3ef83ce0e41bbfad86e551bbf072f995" };
export const dusdcTreasuryCapID = { mainnet: "", testnet: "0x1713b3d987b9f3ce0beaa6caa7b9af2f6be3ee936ff69afde5ee91657130fce6" };
export const dusdcCurrencyID = { mainnet: "", testnet: "0x787d2eb16975543255e30fb97d2eb2d48186526ef35eda985613db9ab03956d9" };

// PLP treasury cap (minted at publish time by plp::init, captured by redeploy)
export const plpTreasuryCapID = { mainnet: "", testnet: "0xff4ae3f4ccd19e9604c957d59a3d4a1373a87a512f01a9df9c9c2027e1b20379" };
