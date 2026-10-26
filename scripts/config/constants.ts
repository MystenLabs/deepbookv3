// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// The DeepBook core UpgradeCap, used by mainPackageUpgrade.ts,
// mainPackageUpgradeEnableVersion.ts and marginPackageUpgradeEnableVersion.ts.
// Liquidation caps moved with the multisig scripts to deepbook-services
// (multisig-txs/config/constants.ts).
export const upgradeCapID = {
  mainnet: "0xdadf253cea3b91010e64651b03da6d56166a4f44b43bdd4e185c277658634483",
  testnet: "0x479467ad71ba0b7f93b38b26cb121fbd181ae2db8c91585d3572db4aaa764ffb",
};

// The core DeepbookAdminCap and Registry, used by mainPackageUpgradeEnableVersion.ts
// to enable the upgraded package's version in the same transaction.
export const adminCapID = {
  mainnet: "0xada554b8b712556b8509be47ac1bc04db9505c3532049a543721aca0c010a840",
};

export const registryID = {
  mainnet: "0xaf16199a2dff736e9f07a845f23c5da6df6f756eddb631aed9d24a93efc4549d",
};

// The margin UpgradeCap, MarginAdminCap and MarginRegistry, used by
// marginPackageUpgradeEnableVersion.ts.
export const marginUpgradeCapID = {
  mainnet: "0xd57c7a41b31c0a1fab5e71d296a75daf2e9e09945df383d4745daa49f06d9c56",
};

export const marginAdminCapID = {
  mainnet: "0x3ec65d06f0be30905cc1742b903aa497791c702820331db263176b74e74c95c8",
};

export const marginRegistryID = {
  mainnet: "0x0e40998b359a9ccbab22a98ed21bd4346abf19158bc7980c8291908086b3a742",
};
