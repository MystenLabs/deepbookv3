// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { coinWithBalance, Transaction } from "@mysten/sui/transactions";
import { prepareMultisigTx } from "../utils/utils.js";
import { adminCapOwner, marginAdminCapID } from "../config/constants.js";

declare const process: {
  exitCode?: number;
};

const MAINNET = "mainnet";

const MARGIN_PACKAGE =
  "0xfbd322126f1452fd4c89aedbaeb9fd0c44df9b5cedbe70d76bf80dc086031377";

const USDC_MARGIN_POOL_ID =
  "0xba473d9ae278f10af75c50a8fa341e9c6a1c087dc91a3f23e8048baf67d0754f";

const USDC_TYPE =
  "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC";

// Sum of pool_default across the five MarginManagerLiquidated events from
// digest 2e6RkQYWrhtKxRArGWUXGXQHreqr9GLfkxwJamvXmomw (USDC, 6 decimals):
//   116,051,397,182 + 53,704,452,210 + 53,393,729,579
// + 33,577,714,688 +  26,877,577,806 = 283,604,871,465 (≈ 283,604.871465 USDC).
const USDC_INJECTION_AMOUNT = 283_604_871_465n;

const ADMIN_INJECT_CAPITAL_TARGET = `${MARGIN_PACKAGE}::margin_pool::admin_inject_capital`;

const buildInjectionTransaction = (): Transaction => {
  const tx = new Transaction();

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

  return tx;
};

const main = async () => {
  const tx = buildInjectionTransaction();

  console.log({
    usdcInjectionAmount: USDC_INJECTION_AMOUNT.toString(),
    usdcMarginPool: USDC_MARGIN_POOL_ID,
    marginAdminCap: marginAdminCapID[MAINNET],
  });

  const res = await prepareMultisigTx(tx, MAINNET, adminCapOwner[MAINNET]);
  console.dir(res, { depth: null });
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
