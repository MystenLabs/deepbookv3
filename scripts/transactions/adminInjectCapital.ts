// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { coinWithBalance, Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";
import { adminCapOwner, marginAdminCapID } from "../config/constants.js";

declare const process: {
  exitCode?: number;
};

const MAINNET = "mainnet";

// Placeholder — replace with the real margin package id before signing.
const MARGIN_PACKAGE = "0x1234";

const MARGIN_REGISTRY_ID =
  "0x0e40998b359a9ccbab22a98ed21bd4346abf19158bc7980c8291908086b3a742";

const USDC_MARGIN_POOL_ID =
  "0xba473d9ae278f10af75c50a8fa341e9c6a1c087dc91a3f23e8048baf67d0754f";

const SUI_TYPE =
  "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI";
const USDC_TYPE =
  "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC";
const DEEP_TYPE =
  "0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP";
const WAL_TYPE =
  "0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59::wal::WAL";
const SUIUSDE_TYPE =
  "0x41d587e5336f1c86cad50d38a7136db99333bb9bda91cea4ba69115defeb1402::sui_usde::SUI_USDE";
const XBTC_TYPE =
  "0x876a4b7bce8aeaef60464c11f4026903e9afacab79b9b142686158aa86560b50::xbtc::XBTC";

// Sum of pool_default across the five MarginManagerLiquidated events from
// digest 2e6RkQYWrhtKxRArGWUXGXQHreqr9GLfkxwJamvXmomw (USDC, 6 decimals):
//   116,051,397,182 + 53,704,452,210 + 53,393,729,579
// + 33,577,714,688 +  26,877,577,806 = 283,604,871,465 (≈ 283,604.871465 USDC).
const USDC_INJECTION_AMOUNT = 283_604_871_465n;

const ADMIN_INJECT_CAPITAL_TARGET = `${MARGIN_PACKAGE}::margin_pool::admin_inject_capital`;
const DISABLE_DEEPBOOK_POOL_TARGET = `${MARGIN_PACKAGE}::margin_registry::disable_deepbook_pool`;

const POOLS_TO_DISABLE: {
  key: string;
  address: string;
  baseType: string;
  quoteType: string;
}[] = [
  {
    key: "SUI_USDC",
    address:
      "0xe05dafb5133bcffb8d59f4e12465dc0e9faeaa05e3e342a08fe135800e3e4407",
    baseType: SUI_TYPE,
    quoteType: USDC_TYPE,
  },
  {
    key: "WAL_USDC",
    address:
      "0x56a1c985c1f1123181d6b881714793689321ba24301b3585eec427436eb1c76d",
    baseType: WAL_TYPE,
    quoteType: USDC_TYPE,
  },
  {
    key: "DEEP_USDC",
    address:
      "0xf948981b806057580f91622417534f491da5f61aeaf33d0ed8e69fd5691c95ce",
    baseType: DEEP_TYPE,
    quoteType: USDC_TYPE,
  },
  {
    key: "SUIUSDE_USDC",
    address:
      "0x0fac1cebf35bde899cd9ecdd4371e0e33f44ba83b8a2902d69186646afa3a94b",
    baseType: SUIUSDE_TYPE,
    quoteType: USDC_TYPE,
  },
  {
    key: "SUI_SUIUSDE",
    address:
      "0x034f3a42e7348de2084406db7a725f9d9d132a56c68324713e6e623601fb4fd7",
    baseType: SUI_TYPE,
    quoteType: SUIUSDE_TYPE,
  },
  {
    key: "XBTC_USDC",
    address:
      "0x20b9a3ec7a02d4f344aa1ebc5774b7b0ccafa9a5d76230662fdc0300bb215307",
    baseType: XBTC_TYPE,
    quoteType: USDC_TYPE,
  },
];

(async () => {
  const tx = new Transaction();

  // 1. Disable all DeepBook pools first so no liquidation activity can race the
  //    capital injection inside the same multisig PTB. Built manually against
  //    MARGIN_PACKAGE rather than the SDK so the package id can be pinned.
  for (const pool of POOLS_TO_DISABLE) {
    tx.moveCall({
      target: DISABLE_DEEPBOOK_POOL_TARGET,
      arguments: [
        tx.object(MARGIN_REGISTRY_ID),
        tx.object(marginAdminCapID[MAINNET]),
        tx.object(pool.address),
        tx.object.clock(),
      ],
      typeArguments: [pool.baseType, pool.quoteType],
    });
  }

  // 2. Inject the aggregate pool_default amount (283,604.871465 USDC) into the
  //    USDC margin pool without minting supplier shares.
  const usdcCoin = coinWithBalance({
    type: USDC_TYPE,
    balance: USDC_INJECTION_AMOUNT,
  })(tx);

  tx.moveCall({
    target: ADMIN_INJECT_CAPITAL_TARGET,
    arguments: [
      tx.object(USDC_MARGIN_POOL_ID),
      tx.object(marginAdminCapID[MAINNET]),
      usdcCoin,
      tx.object.clock(),
    ],
    typeArguments: [USDC_TYPE],
  });

  console.log({
    poolKeysDisabled: POOLS_TO_DISABLE.map((p) => p.key),
    usdcInjectionAmount: USDC_INJECTION_AMOUNT.toString(),
    usdcMarginPool: USDC_MARGIN_POOL_ID,
    marginAdminCap: marginAdminCapID[MAINNET],
    marginPackage: MARGIN_PACKAGE,
  });

  const res = await prepareMultisigTx(tx, MAINNET, adminCapOwner[MAINNET]);
  console.dir(res, { depth: null });
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
