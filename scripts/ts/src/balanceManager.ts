import { TransactionBlock } from "@mysten/sui.js/transactions";
import { signAndExecute } from "./utils";
import { normalizeSuiAddress } from "@mysten/sui.js/utils";
import { SuiClient, getFullnodeUrl } from "@mysten/sui.js/client";
import { bcs } from "@mysten/sui.js/bcs";
import {
    ENV, COIN_SCALARS, DEEPBOOK_PACKAGE_ID, TONY_TYPE, DEEP_TYPE, SUI_TYPE,
    MANAGER_ID, COIN_IDS, MY_ADDRESS
} from './coinConstants';

const client = new SuiClient({ url: getFullnodeUrl(ENV) });

// =================================================================
// Transactions
// =================================================================

const createAndShareBalanceManager = async (
    txb: TransactionBlock
) => {
    const manager = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::new`,
    });
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::share`,
        arguments: [
            manager,
        ],
    });
}

const depositIntoManager = async (
    amountToDeposit: number,
    coinType: string,
    coinId: string,
    txb: TransactionBlock
) => {
    const scalar = COIN_SCALARS[coinType];
    let deposit;

    if (coinType === SUI_TYPE) {
        [deposit] = txb.splitCoins(
            txb.gas,
            [txb.pure.u64(amountToDeposit * scalar)]
        );
    } else {
        [deposit] = txb.splitCoins(
            txb.object(coinId),
            [txb.pure.u64(amountToDeposit * scalar)]
        );
    }

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::deposit`,
        arguments: [
            txb.object(MANAGER_ID),
            deposit,
        ],
        typeArguments: [coinType]
    });

    console.log(`Deposited ${amountToDeposit} of type ${coinType} into manager ${MANAGER_ID}`);
}

const withdrawFromManager = async (
    amountToWithdraw: number,
    coinType: string,
    txb: TransactionBlock
) => {
    const scalar = COIN_SCALARS[coinType];
    const coin = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::withdraw`,
        arguments: [
            txb.object(MANAGER_ID),
            txb.pure.u64(amountToWithdraw * scalar),
        ],
        typeArguments: [coinType]
    });

    txb.transferObjects([coin], MY_ADDRESS);
    console.log(`Withdrew ${amountToWithdraw} of type ${coinType} from manager ${MANAGER_ID}`);
}

const withdrawAllFromManager = async (
    coinType: string,
    txb: TransactionBlock
) => {
    const coin = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::withdraw_all`,
        arguments: [
            txb.object(MANAGER_ID),
        ],
        typeArguments: [coinType]
    });

    txb.transferObjects([coin], MY_ADDRESS);
    console.log(`Withdrew all of type ${coinType} from manager ${MANAGER_ID}`);
};

const checkManagerBalance = async (
    coinType: string,
    txb: TransactionBlock
) => {
    const scalar = COIN_SCALARS[coinType];
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::balance`,
        arguments: [
            txb.object(MANAGER_ID),
        ],
        typeArguments: [coinType]
    });

    const res = await client.devInspectTransactionBlock({
        sender: normalizeSuiAddress(MY_ADDRESS),
        transactionBlock: txb,
    });

    const bytes = res.results![0].returnValues![0][0];
    const parsed_balance = bcs.U64.parse(new Uint8Array(bytes));
    const balanceNumber = Number(parsed_balance);
    const adjusted_balance = balanceNumber / scalar;

    console.log(`Manager balance for ${coinType} is ${adjusted_balance.toString()}`); // Output the u64 number as a string
}

/// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();

    // await createAndShareBalanceManager(txb);
    // await depositIntoManager(5000, DEEP_TYPE, COIN_IDS.DEEP, txb);
    // await depositIntoManager(40, SUI_TYPE, COIN_IDS.SUI, txb);
    // await depositIntoManager(5000, TONY_TYPE, COIN_IDS.TONY, txb);
    // await withdrawFromManager(5, SUI_TYPE, txb);
    // await withdrawAllFromManager(SUI_TYPE, txb);
    // await checkManagerBalance(DEEP_TYPE, txb);
    // await checkManagerBalance(SUI_TYPE, txb);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
