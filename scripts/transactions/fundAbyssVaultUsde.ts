// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { coinWithBalance, Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";
import { adminCapOwner } from "../config/constants.js";

const ABYSS_VAULT_PACKAGE =
  "0x89a2379902ee37959c0dd95820ebb474531ef7727fa135d0324e62e8d4e06da5";
const COIN_TYPE =
  "0x41d587e5336f1c86cad50d38a7136db99333bb9bda91cea4ba69115defeb1402::sui_usde::SUI_USDE";
const ATOKEN_TYPE = `${ABYSS_VAULT_PACKAGE}::abyss_vault::AToken<${COIN_TYPE}>`;

// Shared objects
const AbyssVault =
  "0x5c76d44cf37a83bbe5c5704b46f8456dbf11c83fd70e21351b651cf0cabd2209";
const marginPool =
  "0xbb990ca04a7743e6c0a25a7fb16f60fc6f6d8bf213624ff03a63f1bb04c3a12f";
const vaultRegistry =
  "0xfac1800074e8ed8eb2baf1e631e8199ccce6b0f6bfd50b5143e1ff47c438aecf";
const marginRegistry =
  "0x0e40998b359a9ccbab22a98ed21bd4346abf19158bc7980c8291908086b3a742";
const abyssSupplierCap =
  "0x3d0faab3953525d243275b39cbed465cb310fe2d4dd2c15428b8f7cf5962c2c0";
const referralId =
  "0x36902236c237324616edb97d829c103367e4006258f37cac2f9464212fdf1a82";
const amount = 10;
const scalar = 1_000_000;

(async () => {
  const env = "mainnet";
  const tx = new Transaction();
  const inputCoin = coinWithBalance({
    type: COIN_TYPE,
    balance: amount * scalar,
  })(tx);

  const yieldTokens = tx.moveCall({
    target: `${ABYSS_VAULT_PACKAGE}::abyss_vault::supply`,
    typeArguments: [COIN_TYPE, ATOKEN_TYPE],
    arguments: [
      tx.object(AbyssVault),
      tx.object(marginPool),
      tx.object(vaultRegistry),
      tx.object(marginRegistry),
      inputCoin,
      tx.object(abyssSupplierCap),
      tx.pure.option("id", referralId),
      tx.object.clock(),
    ],
  });
  tx.transferObjects([yieldTokens], adminCapOwner[env]);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
