// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { coinWithBalance, Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";
import {
  adminCapOwner,
  deepMarginPoolCapID,
  marginAdminCapID,
  suiMarginPoolCapID,
  suiUsdeMarginPoolCapID,
  usdcMarginPoolCapID,
  walMarginPoolCapID,
  xbtcMarginPoolCapID,
} from "../config/constants.js";

declare const process: {
  exitCode?: number;
};

const MAINNET = "mainnet";

// Upgraded margin package (v5).
const MARGIN_PACKAGE =
  "0x124bb3d8105d6d301c0d40feaa54d65df6b301e4d8ddd5eb8475b0f8a18cff2e";

const MARGIN_REGISTRY_ID =
  "0x0e40998b359a9ccbab22a98ed21bd4346abf19158bc7980c8291908086b3a742";

const SUI_MARGIN_POOL_ID =
  "0x53041c6f86c4782aabbfc1d4fe234a6d37160310c7ee740c915f0a01b7127344";
const USDC_MARGIN_POOL_ID =
  "0xba473d9ae278f10af75c50a8fa341e9c6a1c087dc91a3f23e8048baf67d0754f";
const DEEP_MARGIN_POOL_ID =
  "0x1d723c5cd113296868b55208f2ab5a905184950dd59c48eb7345607d6b5e6af7";
const WAL_MARGIN_POOL_ID =
  "0x38decd3dbb62bd4723144349bf57bc403b393aee86a51596846a824a1e0c2c01";
const SUIUSDE_MARGIN_POOL_ID =
  "0xbb990ca04a7743e6c0a25a7fb16f60fc6f6d8bf213624ff03a63f1bb04c3a12f";
const XBTC_MARGIN_POOL_ID =
  "0x14dfbf54400e0b97e892349310d392bef6d187c2b6709d9b246b8f41c9a13de4";

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

// Both v3 and v4 must be enabled in the registry: v3 so users with existing
// margin managers can still call reduce-only / withdraw paths; v4 so the
// admin disable + inject calls in this PTB resolve through the upgraded
// package. enable_version aborts with EVersionAlreadyEnabled
// (margin_registry.move:374) on a no-op — comment out the matching line if
// either version is already enabled at sign time.
const MARGIN_VERSIONS_TO_ENABLE = [3, 4];

const ADMIN_INJECT_CAPITAL_TARGET = `${MARGIN_PACKAGE}::margin_pool::admin_inject_capital`;
const DISABLE_DEEPBOOK_POOL_TARGET = `${MARGIN_PACKAGE}::margin_registry::disable_deepbook_pool`;
const DISABLE_DEEPBOOK_POOL_FOR_LOAN_TARGET = `${MARGIN_PACKAGE}::margin_pool::disable_deepbook_pool_for_loan`;
const ENABLE_VERSION_TARGET = `${MARGIN_PACKAGE}::margin_registry::enable_version`;

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

// Mirrors the (deepbookPool, marginPool) pairs enabled in marginSetup.ts via
// enableDeepbookPoolForLoan (USDSUI pairs intentionally excluded). For each,
// we call disable_deepbook_pool_for_loan to flip MarginPool.allowed_deepbook_pools
// off — defense in depth on top of the registry-side disable above.
//
// Aborts with EDeepbookPoolNotAllowed (margin_pool.move:207) if the pair was
// already disabled on chain. If PR #22 already executed, comment out the
// matching entries before signing.
const LOAN_PAIRS_TO_DISABLE: {
  label: string;
  marginPoolId: string;
  marginPoolCapId: string;
  deepbookPoolId: string;
  assetType: string;
}[] = [
  {
    label: "SUI_USDC + USDC margin pool",
    marginPoolId: USDC_MARGIN_POOL_ID,
    marginPoolCapId: usdcMarginPoolCapID[MAINNET],
    deepbookPoolId:
      "0xe05dafb5133bcffb8d59f4e12465dc0e9faeaa05e3e342a08fe135800e3e4407",
    assetType: USDC_TYPE,
  },
  {
    label: "SUI_USDC + SUI margin pool",
    marginPoolId: SUI_MARGIN_POOL_ID,
    marginPoolCapId: suiMarginPoolCapID[MAINNET],
    deepbookPoolId:
      "0xe05dafb5133bcffb8d59f4e12465dc0e9faeaa05e3e342a08fe135800e3e4407",
    assetType: SUI_TYPE,
  },
  {
    label: "DEEP_USDC + USDC margin pool",
    marginPoolId: USDC_MARGIN_POOL_ID,
    marginPoolCapId: usdcMarginPoolCapID[MAINNET],
    deepbookPoolId:
      "0xf948981b806057580f91622417534f491da5f61aeaf33d0ed8e69fd5691c95ce",
    assetType: USDC_TYPE,
  },
  {
    label: "DEEP_USDC + DEEP margin pool",
    marginPoolId: DEEP_MARGIN_POOL_ID,
    marginPoolCapId: deepMarginPoolCapID[MAINNET],
    deepbookPoolId:
      "0xf948981b806057580f91622417534f491da5f61aeaf33d0ed8e69fd5691c95ce",
    assetType: DEEP_TYPE,
  },
  {
    label: "WAL_USDC + USDC margin pool",
    marginPoolId: USDC_MARGIN_POOL_ID,
    marginPoolCapId: usdcMarginPoolCapID[MAINNET],
    deepbookPoolId:
      "0x56a1c985c1f1123181d6b881714793689321ba24301b3585eec427436eb1c76d",
    assetType: USDC_TYPE,
  },
  {
    label: "WAL_USDC + WAL margin pool",
    marginPoolId: WAL_MARGIN_POOL_ID,
    marginPoolCapId: walMarginPoolCapID[MAINNET],
    deepbookPoolId:
      "0x56a1c985c1f1123181d6b881714793689321ba24301b3585eec427436eb1c76d",
    assetType: WAL_TYPE,
  },
  {
    label: "SUIUSDE_USDC + USDC margin pool",
    marginPoolId: USDC_MARGIN_POOL_ID,
    marginPoolCapId: usdcMarginPoolCapID[MAINNET],
    deepbookPoolId:
      "0x0fac1cebf35bde899cd9ecdd4371e0e33f44ba83b8a2902d69186646afa3a94b",
    assetType: USDC_TYPE,
  },
  {
    label: "SUIUSDE_USDC + SUIUSDE margin pool",
    marginPoolId: SUIUSDE_MARGIN_POOL_ID,
    marginPoolCapId: suiUsdeMarginPoolCapID[MAINNET],
    deepbookPoolId:
      "0x0fac1cebf35bde899cd9ecdd4371e0e33f44ba83b8a2902d69186646afa3a94b",
    assetType: SUIUSDE_TYPE,
  },
  {
    label: "SUI_SUIUSDE + SUI margin pool",
    marginPoolId: SUI_MARGIN_POOL_ID,
    marginPoolCapId: suiMarginPoolCapID[MAINNET],
    deepbookPoolId:
      "0x034f3a42e7348de2084406db7a725f9d9d132a56c68324713e6e623601fb4fd7",
    assetType: SUI_TYPE,
  },
  {
    label: "SUI_SUIUSDE + SUIUSDE margin pool",
    marginPoolId: SUIUSDE_MARGIN_POOL_ID,
    marginPoolCapId: suiUsdeMarginPoolCapID[MAINNET],
    deepbookPoolId:
      "0x034f3a42e7348de2084406db7a725f9d9d132a56c68324713e6e623601fb4fd7",
    assetType: SUIUSDE_TYPE,
  },
  {
    label: "XBTC_USDC + USDC margin pool",
    marginPoolId: USDC_MARGIN_POOL_ID,
    marginPoolCapId: usdcMarginPoolCapID[MAINNET],
    deepbookPoolId:
      "0x20b9a3ec7a02d4f344aa1ebc5774b7b0ccafa9a5d76230662fdc0300bb215307",
    assetType: USDC_TYPE,
  },
  {
    label: "XBTC_USDC + XBTC margin pool",
    marginPoolId: XBTC_MARGIN_POOL_ID,
    marginPoolCapId: xbtcMarginPoolCapID[MAINNET],
    deepbookPoolId:
      "0x20b9a3ec7a02d4f344aa1ebc5774b7b0ccafa9a5d76230662fdc0300bb215307",
    assetType: XBTC_TYPE,
  },
];

(async () => {
  const tx = new Transaction();

  // 1. Enable both v3 (so existing margin managers stay callable for
  //    reduce-only and withdraw paths) and v4 (so the disable + inject calls
  //    below resolve through the upgraded margin package).
  for (const version of MARGIN_VERSIONS_TO_ENABLE) {
    tx.moveCall({
      target: ENABLE_VERSION_TARGET,
      arguments: [
        tx.object(MARGIN_REGISTRY_ID),
        tx.pure.u64(version),
        tx.object(marginAdminCapID[MAINNET]),
      ],
    });
  }

  // 2. Disable all DeepBook pools so no liquidation activity can race the
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

  // 3. Disable each (deepbook_pool, margin_pool) loan allowlist entry that was
  //    enabled in marginSetup.ts (USDSUI pairs excluded). Belt-and-suspenders
  //    on top of step 2: step 2 blocks pool_proxy::* trades, step 3 blocks
  //    margin_manager::borrow_* at the margin-pool level.
  for (const pair of LOAN_PAIRS_TO_DISABLE) {
    tx.moveCall({
      target: DISABLE_DEEPBOOK_POOL_FOR_LOAN_TARGET,
      arguments: [
        tx.object(pair.marginPoolId),
        tx.object(MARGIN_REGISTRY_ID),
        tx.pure.id(pair.deepbookPoolId),
        tx.object(pair.marginPoolCapId),
        tx.object.clock(),
      ],
      typeArguments: [pair.assetType],
    });
  }

  // 4. Inject the aggregate pool_default amount (283,604.871465 USDC) into the
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
    marginVersionsEnabled: MARGIN_VERSIONS_TO_ENABLE,
    poolKeysDisabled: POOLS_TO_DISABLE.map((p) => p.key),
    loanPairsDisabled: LOAN_PAIRS_TO_DISABLE.map((p) => p.label),
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
