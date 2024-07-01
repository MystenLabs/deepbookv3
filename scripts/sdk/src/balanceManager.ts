import { TransactionBlock } from "@mysten/sui.js/transactions";
import { signAndExecute } from "./utils";
import {
    ENV, Coin, Coins, DEEPBOOK_PACKAGE_ID, MY_ADDRESS, MANAGER_ADDRESSES
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
    managerKey: string,
    amountToDeposit: number,
    coin: Coin,
    txb: TransactionBlock
) => {
    const managerAddress = MANAGER_ADDRESSES[managerKey].address;
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
    managerKey: string,
    amountToWithdraw: number,
    coin: Coin,
    txb: TransactionBlock
) => {
    const managerAddress = MANAGER_ADDRESSES[managerKey].address;
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
    managerKey: string,
    coin: Coin,
    txb: TransactionBlock
) => {
    const managerAddress = MANAGER_ADDRESSES[managerKey].address;
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
    managerKey: string,
    coin: Coin,
    txb: TransactionBlock
) => {
    const managerAddress = MANAGER_ADDRESSES[managerKey].address;
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::balance`,
        arguments: [
            txb.object(managerAddress),
        ],
        typeArguments: [coin.type]
    });
}

export const generateProofAsOwner = (
    managerAddress: string,
    txb: TransactionBlock,
) => {
    return txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::generate_proof_as_owner`,
        arguments: [
            txb.object(managerAddress),
        ],
    });
}

export const generateProofAsTrader = (
    managerAddress: string,
    tradeCapId: string,
    txb: TransactionBlock,
) => {
    return txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::generate_proof_as_trader`,
        arguments: [
            txb.object(managerAddress),
            txb.object(tradeCapId),
        ],
    });
}

export const generateProof = (managerKey: string, txb: TransactionBlock) => {
    const { address, tradeCapId } = MANAGER_ADDRESSES[managerKey];
    return tradeCapId
        ? generateProofAsTrader(address, tradeCapId, txb)
        : generateProofAsOwner(address, txb);
}

// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();

    await createAndShareBalanceManager(txb);
    await depositIntoManager('MANAGER_ADDRESS_1', 5000, Coins.DEEP, txb);
    await depositIntoManager('MANAGER_ADDRESS_1', 1, Coins.SUI, txb);
    await depositIntoManager('MANAGER_ADDRESS_1', 5000, Coins.TONY, txb);
    await withdrawFromManager('MANAGER_ADDRESS_1', 5, Coins.SUI, txb);
    await withdrawAllFromManager('MANAGER_ADDRESS_1', Coins.SUI, txb);
    await checkManagerBalance('MANAGER_ADDRESS_1', Coins.DEEP, txb);
    await checkManagerBalance('MANAGER_ADDRESS_1', Coins.SUI, txb);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
};

executeTransaction();
