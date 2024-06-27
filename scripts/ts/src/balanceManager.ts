import { TransactionBlock } from "@mysten/sui.js/transactions";
import { signAndExecute } from "./utils";
import { normalizeSuiAddress } from "@mysten/sui.js/utils";
import { SuiClient, getFullnodeUrl } from "@mysten/sui.js/client";
import { bcs } from "@mysten/sui.js/bcs";
import {
    ENV, Coin, Coins, Pools, DEEPBOOK_PACKAGE_ID, MY_ADDRESS, MANAGER_ID, Constants
} from './coinConstants';

const client = new SuiClient({ url: getFullnodeUrl(ENV) });

// =================================================================
// Transactions
// =================================================================

const createAndShareBalanceManager = async (txb: TransactionBlock) => {
    const manager = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::new`,
    });
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::share`,
        arguments: [manager],
    });
};

const depositIntoManager = async (
    amountToDeposit: number,
    coin: Coin,
    txb: TransactionBlock
) => {
    let deposit;

    if (coin.type === Coins.SUI.type) {
        [deposit] = txb.splitCoins(
            txb.gas,
            [txb.pure.u64(amountToDeposit * coin.scalar)]
        );
    } else {
        [deposit] = txb.splitCoins(
            txb.object(coin.coinId),
            [txb.pure.u64(amountToDeposit * coin.scalar)]
        );
    }

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::deposit`,
        arguments: [
            txb.object(MANAGER_ID),
            deposit,
        ],
        typeArguments: [coin.type]
    });

    console.log(`Deposited ${amountToDeposit} of type ${coin.type} into manager ${MANAGER_ID}`);
};

const withdrawFromManager = async (
    amountToWithdraw: number,
    coin: Coin,
    txb: TransactionBlock
) => {
    const coinObject = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::withdraw`,
        arguments: [
            txb.object(MANAGER_ID),
            txb.pure.u64(amountToWithdraw * coin.scalar),
        ],
        typeArguments: [coin.type]
    });

    txb.transferObjects([coinObject], MY_ADDRESS);
    console.log(`Withdrew ${amountToWithdraw} of type ${coin.type} from manager ${MANAGER_ID}`);
};

const withdrawAllFromManager = async (
    coin: Coin,
    txb: TransactionBlock
) => {
    const coinObject = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::withdraw_all`,
        arguments: [
            txb.object(MANAGER_ID),
        ],
        typeArguments: [coin.type]
    });

    txb.transferObjects([coinObject], MY_ADDRESS);
    console.log(`Withdrew all of type ${coin.type} from manager ${MANAGER_ID}`);
};

const checkManagerBalance = async (
    coin: Coin,
    txb: TransactionBlock
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::balance`,
        arguments: [
            txb.object(MANAGER_ID),
        ],
        typeArguments: [coin.type]
    });

    const res = await client.devInspectTransactionBlock({
        sender: normalizeSuiAddress(MY_ADDRESS),
        transactionBlock: txb,
    });

    const bytes = res.results![0].returnValues![0][0];
    const parsed_balance = bcs.U64.parse(new Uint8Array(bytes));
    const balanceNumber = Number(parsed_balance);
    const adjusted_balance = balanceNumber / coin.scalar;

    console.log(`Manager balance for ${coin.type} is ${adjusted_balance.toString()}`); // Output the u64 number as a string
};

// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();

    // await createAndShareBalanceManager(txb);
    // await depositIntoManager(5000, Coins.DEEP, txb);
    // await depositIntoManager(40, Coins.SUI, txb);
    // await depositIntoManager(5000, Coins.TONY, txb);
    // await withdrawFromManager(5, Coins.SUI, txb);
    // await withdrawAllFromManager(Coins.SUI, txb);
    // await checkManagerBalance(Coins.DEEP, txb);
    // await checkManagerBalance(Coins.SUI, txb);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
};

executeTransaction();
