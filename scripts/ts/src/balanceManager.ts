import { TransactionBlock } from "@mysten/sui.js/transactions";
import { signAndExecute } from "./utils";
import {
    ENV, Coin, Coins, DEEPBOOK_PACKAGE_ID, MY_ADDRESS,
} from './coinConstants';

export const createAndShareBalanceManager = (txb: TransactionBlock) => {
    const manager = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::new`,
    });
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::share`,
        arguments: [manager],
    });
};

export const depositIntoManager = (
    managerAddress: string,
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
            txb.object(managerAddress),
            deposit,
        ],
        typeArguments: [coin.type]
    });

    console.log(`Deposited ${amountToDeposit} of type ${coin.type} into manager ${managerAddress}`);
};

export const withdrawFromManager = (
    managerAddress: string,
    amountToWithdraw: number,
    coin: Coin,
    txb: TransactionBlock
) => {
    const coinObject = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::withdraw`,
        arguments: [
            txb.object(managerAddress),
            txb.pure.u64(amountToWithdraw * coin.scalar),
        ],
        typeArguments: [coin.type]
    });

    txb.transferObjects([coinObject], MY_ADDRESS);
    console.log(`Withdrew ${amountToWithdraw} of type ${coin.type} from manager ${managerAddress}`);
};

export const withdrawAllFromManager = (
    managerAddress: string,
    coin: Coin,
    txb: TransactionBlock
) => {
    const coinObject = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::withdraw_all`,
        arguments: [
            txb.object(managerAddress),
        ],
        typeArguments: [coin.type]
    });

    txb.transferObjects([coinObject], MY_ADDRESS);
    console.log(`Withdrew all of type ${coin.type} from manager ${managerAddress}`);
};

export const checkManagerBalance = (
    managerAddress: string,
    coin: Coin,
    txb: TransactionBlock
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::balance`,
        arguments: [
            txb.object(managerAddress),
        ],
        typeArguments: [coin.type]
    });
}

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
