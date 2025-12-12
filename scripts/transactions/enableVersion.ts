// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils";
import { adminCapOwner, adminCapID } from "../config/constants";
import { DeepBookClient } from "@mysten/deepbook-v3";
import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";

(async () => {
  // Update constant for env
  const env = "mainnet";
  const versionToEnable = 4;

  const dbClient = new DeepBookClient({
    address: "0x0",
    env: env,
    client: new SuiClient({
      url: getFullnodeUrl(env),
    }),
    adminCap: adminCapID[env],
  });

  const tx = new Transaction();

  dbClient.deepBookAdmin.enableVersion(versionToEnable)(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("DEEP_SUI")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("SUI_USDC")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("DEEP_USDC")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("WUSDT_USDC")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("WUSDC_USDC")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("BETH_USDC")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("NS_USDC")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("NS_SUI")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("TYPUS_SUI")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("SUI_AUSD")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("AUSD_USDC")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("DRF_SUI")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("SEND_USDC")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("WAL_USDC")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("WAL_SUI")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("XBTC_USDC")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("IKA_USDC")(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
