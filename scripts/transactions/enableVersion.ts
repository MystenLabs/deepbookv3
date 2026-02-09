// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";
import { adminCapOwner, adminCapID } from "../config/constants.js";
import { deepbook } from "@mysten/deepbook-v3";
import { SuiGrpcClient } from "@mysten/sui/grpc";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const versionToEnable = 6;

  const client = new SuiGrpcClient({
    url: "https://sui-mainnet.mystenlabs.com",
    network: "mainnet",
  }).$extend(
    deepbook({
      address: "0x0",
      adminCap: adminCapID[env],
    }),
  );

  const tx = new Transaction();

  client.deepbook.deepBookAdmin.enableVersion(versionToEnable)(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("DEEP_SUI")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("SUI_USDC")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("DEEP_USDC")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("WUSDT_USDC")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("WUSDC_USDC")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("BETH_USDC")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("NS_USDC")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("NS_SUI")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("TYPUS_SUI")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("SUI_AUSD")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("AUSD_USDC")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("DRF_SUI")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("SEND_USDC")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("WAL_USDC")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("WAL_SUI")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("XBTC_USDC")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("IKA_USDC")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("ALKIMI_SUI")(tx);
  client.deepbook.deepBookAdmin.updateAllowedVersions("LZWBTC_USDC")(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
