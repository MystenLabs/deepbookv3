// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";
import { adminCapOwner } from "../config/constants.js";

const ABYSS_VAULT_PACKAGE =
  "0x90a75f641859f4d77a4349d67e518e1dd9ecb4fac079e220fa46b7a7f164e0a5";
const USDC_TYPE =
  "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC";
const ATOKEN_TYPE = `${ABYSS_VAULT_PACKAGE}::abyss_vault::AToken<${USDC_TYPE}>`;

// Shared objects
const AbyssVault =
  "0x86cd17116a5c1bc95c25296a901eb5ea91531cb8ba59d01f64ee2018a14d6fa5";
const marginPool =
  "0xba473d9ae278f10af75c50a8fa341e9c6a1c087dc91a3f23e8048baf67d0754f";
const vaultRegistry =
  "0xfac1800074e8ed8eb2baf1e631e8199ccce6b0f6bfd50b5143e1ff47c438aecf";
const marginRegistry =
  "0x0e40998b359a9ccbab22a98ed21bd4346abf19158bc7980c8291908086b3a742";
const abyssSupplierCap =
  "0x3d0faab3953525d243275b39cbed465cb310fe2d4dd2c15428b8f7cf5962c2c0";

(async () => {
  const env = "mainnet";
  const tx = new Transaction();

  // Supply 99k into abyss vault
  const yieldTokens = tx.moveCall({
    target: `${ABYSS_VAULT_PACKAGE}::abyss_vault::supply`,
    typeArguments: [USDC_TYPE, ATOKEN_TYPE],
    arguments: [
      tx.object(AbyssVault),
      tx.object(marginPool),
      tx.object(vaultRegistry),
      tx.object(marginRegistry),
      tx.object(
        "0x392b92d4a872bff969d9ef8d51c3d7a4223fe2b75da29d7befb2aee25c017562",
      ),
      tx.object(abyssSupplierCap),
      tx.pure.option(
        "id",
        "0xba436b3f0e57600e9318c2e03c51b940612d8b0d4df18ad9f31c203f95cad122",
      ),
      tx.object.clock(),
    ],
  });
  tx.transferObjects([yieldTokens], adminCapOwner[env]);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
