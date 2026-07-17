// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// The DeepBook core UpgradeCap, used by mainPackageUpgrade.ts.
// Admin / margin / liquidation caps moved with the multisig scripts to
// deepbook-services (multisig-txs/config/constants.ts).
export const upgradeCapID = {
  mainnet: "0xdadf253cea3b91010e64651b03da6d56166a4f44b43bdd4e185c277658634483",
  testnet: "0x479467ad71ba0b7f93b38b26cb121fbd181ae2db8c91585d3572db4aaa764ffb",
};
