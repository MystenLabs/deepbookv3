// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// The DeepBook core UpgradeCap, used by mainPackageUpgrade.ts and
// mainPackageUpgradeEnableVersion.ts.
// Margin / liquidation caps moved with the multisig scripts to
// deepbook-services (multisig-txs/config/constants.ts).
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
