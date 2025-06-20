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
  // const versionToEnable = 3;

  const coins = {
    DEEP: {
      address: `0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270`,
      type: `0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP`,
      scalar: 1000000,
    },
    SUI: {
      address: `0x0000000000000000000000000000000000000000000000000000000000000002`,
      type: `0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI`,
      scalar: 1000000000,
    },
    USDC: {
      address: `0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7`,
      type: `0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC`,
      scalar: 1000000,
    },
    WUSDC: {
      address: `0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf`,
      type: `0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN`,
      scalar: 1000000,
    },
    WETH: {
      address: `0xaf8cd5edc19c4512f4259f0bee101a40d41ebed738ade5874359610ef8eeced5`,
      type: `0xaf8cd5edc19c4512f4259f0bee101a40d41ebed738ade5874359610ef8eeced5::coin::COIN`,
      scalar: 100000000,
    },
    BETH: {
      address: `0xd0e89b2af5e4910726fbcd8b8dd37bb79b29e5f83f7491bca830e94f7f226d29`,
      type: `0xd0e89b2af5e4910726fbcd8b8dd37bb79b29e5f83f7491bca830e94f7f226d29::eth::ETH`,
      scalar: 100000000,
    },
    WBTC: {
      address: `0x027792d9fed7f9844eb4839566001bb6f6cb4804f66aa2da6fe1ee242d896881`,
      type: `0x027792d9fed7f9844eb4839566001bb6f6cb4804f66aa2da6fe1ee242d896881::coin::COIN`,
      scalar: 100000000,
    },
    WUSDT: {
      address: `0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c`,
      type: `0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c::coin::COIN`,
      scalar: 1000000,
    },
    NS: {
      address: `0x5145494a5f5100e645e4b0aa950fa6b68f614e8c59e17bc5ded3495123a79178`,
      type: `0x5145494a5f5100e645e4b0aa950fa6b68f614e8c59e17bc5ded3495123a79178::ns::NS`,
      scalar: 1000000,
    },
    TYPUS: {
      address: `0xf82dc05634970553615eef6112a1ac4fb7bf10272bf6cbe0f80ef44a6c489385`,
      type: `0xf82dc05634970553615eef6112a1ac4fb7bf10272bf6cbe0f80ef44a6c489385::typus::TYPUS`,
      scalar: 1000000000,
    },
    AUSD: {
      address: `0x2053d08c1e2bd02791056171aab0fd12bd7cd7efad2ab8f6b9c8902f14df2ff2`,
      type: `0x2053d08c1e2bd02791056171aab0fd12bd7cd7efad2ab8f6b9c8902f14df2ff2::ausd::AUSD`,
      scalar: 1000000,
    },
    DRF: {
      address: `0x294de7579d55c110a00a7c4946e09a1b5cbeca2592fbb83fd7bfacba3cfeaf0e`,
      type: `0x294de7579d55c110a00a7c4946e09a1b5cbeca2592fbb83fd7bfacba3cfeaf0e::drf::DRF`,
      scalar: 1000000,
    },
    SEND: {
      address: `0xb45fcfcc2cc07ce0702cc2d229621e046c906ef14d9b25e8e4d25f6e8763fef7`,
      type: `0xb45fcfcc2cc07ce0702cc2d229621e046c906ef14d9b25e8e4d25f6e8763fef7::send::SEND`,
      scalar: 1000000,
    },
    WAL: {
      address: `0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59`,
      type: `0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59::wal::WAL`,
      scalar: 1000000000,
    },
    XBTC: {
      address: `0x876a4b7bce8aeaef60464c11f4026903e9afacab79b9b142686158aa86560b50`,
      type: `0x876a4b7bce8aeaef60464c11f4026903e9afacab79b9b142686158aa86560b50::xbtc::XBTC`,
      scalar: 100000000,
    },
    UP: {
      address: `0x87dfe1248a1dc4ce473bd9cb2937d66cdc6c30fee63f3fe0dbb55c7a09d35dec`,
      type: `0x87dfe1248a1dc4ce473bd9cb2937d66cdc6c30fee63f3fe0dbb55c7a09d35dec::up::UP`,
      scalar: 1000000,
    },
    LBTC: {
      address: `0x3e8e9423d80e1774a7ca128fccd8bf5f1f7753be658c5e645929037f7c819040`,
      type: `0x3e8e9423d80e1774a7ca128fccd8bf5f1f7753be658c5e645929037f7c819040::lbtc::LBTC`,
      scalar: 100000000,
    },
    CETUS: {
      address: `0x06864a6f921804860930db6ddbe2e16acdf8504495ea7481637a1c8b9a8fe54b`,
      type: `0x06864a6f921804860930db6ddbe2e16acdf8504495ea7481637a1c8b9a8fe54b::cetus::CETUS`,
      scalar: 1000000000,
    },
    TLP: {
      address: `0xe27969a70f93034de9ce16e6ad661b480324574e68d15a64b513fd90eb2423e5`,
      type: `0xe27969a70f93034de9ce16e6ad661b480324574e68d15a64b513fd90eb2423e5::tlp::TLP`,
      scalar: 1000000000,
    },
    HAEDAL: {
      address: `0x3a304c7feba2d819ea57c3542d68439ca2c386ba02159c740f7b406e592c62ea`,
      type: `0x3a304c7feba2d819ea57c3542d68439ca2c386ba02159c740f7b406e592c62ea::haedal::HAEDAL`,
      scalar: 1000000000,
    },
  };

  const pools = {
    DEEP_SUI: {
      address: `0xb663828d6217467c8a1838a03793da896cbe745b150ebd57d82f814ca579fc22`,
      baseCoin: "DEEP",
      quoteCoin: "SUI",
    },
    SUI_USDC: {
      address: `0xe05dafb5133bcffb8d59f4e12465dc0e9faeaa05e3e342a08fe135800e3e4407`,
      baseCoin: "SUI",
      quoteCoin: "USDC",
    },
    DEEP_USDC: {
      address: `0xf948981b806057580f91622417534f491da5f61aeaf33d0ed8e69fd5691c95ce`,
      baseCoin: "DEEP",
      quoteCoin: "USDC",
    },
    WUSDT_USDC: {
      address: `0x4e2ca3988246e1d50b9bf209abb9c1cbfec65bd95afdacc620a36c67bdb8452f`,
      baseCoin: "WUSDT",
      quoteCoin: "USDC",
    },
    WUSDC_USDC: {
      address: `0xa0b9ebefb38c963fd115f52d71fa64501b79d1adcb5270563f92ce0442376545`,
      baseCoin: "WUSDC",
      quoteCoin: "USDC",
    },
    BETH_USDC: {
      address: `0x1109352b9112717bd2a7c3eb9a416fff1ba6951760f5bdd5424cf5e4e5b3e65c`,
      baseCoin: "BETH",
      quoteCoin: "USDC",
    },
    NS_USDC: {
      address: `0x0c0fdd4008740d81a8a7d4281322aee71a1b62c449eb5b142656753d89ebc060`,
      baseCoin: "NS",
      quoteCoin: "USDC",
    },
    NS_SUI: {
      address: `0x27c4fdb3b846aa3ae4a65ef5127a309aa3c1f466671471a806d8912a18b253e8`,
      baseCoin: "NS",
      quoteCoin: "SUI",
    },
    TYPUS_SUI: {
      address: `0xe8e56f377ab5a261449b92ac42c8ddaacd5671e9fec2179d7933dd1a91200eec`,
      baseCoin: "TYPUS",
      quoteCoin: "SUI",
    },
    SUI_AUSD: {
      address: `0x183df694ebc852a5f90a959f0f563b82ac9691e42357e9a9fe961d71a1b809c8`,
      baseCoin: "SUI",
      quoteCoin: "AUSD",
    },
    AUSD_USDC: {
      address: `0x5661fc7f88fbeb8cb881150a810758cf13700bb4e1f31274a244581b37c303c3`,
      baseCoin: "AUSD",
      quoteCoin: "USDC",
    },
    DRF_SUI: {
      address: `0x126865a0197d6ab44bfd15fd052da6db92fd2eb831ff9663451bbfa1219e2af2`,
      baseCoin: "DRF",
      quoteCoin: "SUI",
    },
    SEND_USDC: {
      address: `0x1fe7b99c28ded39774f37327b509d58e2be7fff94899c06d22b407496a6fa990`,
      baseCoin: "SEND",
      quoteCoin: "USDC",
    },
    WAL_USDC: {
      address: `0x56a1c985c1f1123181d6b881714793689321ba24301b3585eec427436eb1c76d`,
      baseCoin: "WAL",
      quoteCoin: "USDC",
    },
    WAL_SUI: {
      address: `0x81f5339934c83ea19dd6bcc75c52e83509629a5f71d3257428c2ce47cc94d08b`,
      baseCoin: "WAL",
      quoteCoin: "SUI",
    },
    XBTC_USDC: {
      address: `0x20b9a3ec7a02d4f344aa1ebc5774b7b0ccafa9a5d76230662fdc0300bb215307`,
      baseCoin: "XBTC",
      quoteCoin: "USDC",
    },
    UP_SUI: {
      address: `0xd90e0a448e3224ee7760810a97b43bffe956f8443ca3489ef5aa51addf1fc4d8`,
      baseCoin: "UP",
      quoteCoin: "SUI",
    },
    CETUS_SUI: {
      address: `0xcf8d0d98dd3c2ceaf40845f5260c620fa62b3a15380bc100053aecd6df8e5e7c`,
      baseCoin: "CETUS",
      quoteCoin: "SUI",
    },
    LBTC_USDC: {
      address: `0xd9474556884afc05b31272823a31c7d1818b4c0951b15a92f576163ecb432613`,
      baseCoin: "LBTC",
      quoteCoin: "USDC",
    },
    TLP_SUI: {
      address: `0xa01557a2c5cb12fa6046d7c6921fa6665b7c009a1adec531947e1170ebbb0695`,
      baseCoin: "TLP",
      quoteCoin: "SUI",
    },
    HAEDAL_USDC: {
      address: `0xfacee57bc356dae0d9958c653253893dfb24e24e8871f53e69b7dccb3ffbf945`,
      baseCoin: "HAEDAL",
      quoteCoin: "USDC",
    },
  };

  const dbClient = new DeepBookClient({
    address: "0x0",
    env: env,
    client: new SuiClient({
      url: getFullnodeUrl(env),
    }),
    adminCap: adminCapID[env],
    coins,
    pools,
  });

  const tx = new Transaction();

  // dbClient.deepBookAdmin.enableVersion(versionToEnable)(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("UP_SUI")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("CETUS_SUI")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("LBTC_USDC")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("TLP_SUI")(tx);
  dbClient.deepBookAdmin.updateAllowedVersions("HAEDAL_USDC")(tx);

  let res = await prepareMultisigTx(tx, env, adminCapOwner[env]);

  console.dir(res, { depth: null });
})();
