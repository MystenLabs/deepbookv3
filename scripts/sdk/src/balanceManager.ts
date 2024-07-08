import { TransactionBlock } from "@mysten/sui.js/transactions";
import {
    DEEPBOOK_PACKAGE_ID
} from './config';
import { Coin, CoinKey } from "./config";

export interface BalanceManager {
    address: string;
    tradeCap: string | undefined;
}

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
    managerId: string,
    amountToDeposit: number,
    coin: Coin,
    txb: TransactionBlock
) => {
    let deposit;

    if (coin.key === CoinKey.SUI) {
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
            txb.object(managerId),
            deposit,
        ],
        typeArguments: [coin.type]
    });

    console.log(`Deposited ${amountToDeposit} of type ${coin.type} into manager ${managerId}`);
};

export const withdrawFromManager = (
    managerId: string,
    amountToWithdraw: number,
    coin: Coin,
    recepient: string,
    txb: TransactionBlock
) => {
    const coinObject = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::withdraw`,
        arguments: [
            txb.object(managerId),
            txb.pure.u64(amountToWithdraw * coin.scalar),
        ],
        typeArguments: [coin.type]
    });

    txb.transferObjects([coinObject], recepient);
    console.log(`Withdrew ${amountToWithdraw} of type ${coin.type} from manager ${managerId}`);
};

export const withdrawAllFromManager = (
    managerId: string,
    coin: Coin,
    recepient: string,
    txb: TransactionBlock
) => {
    const coinObject = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::withdraw_all`,
        arguments: [
            txb.object(managerId),
        ],
        typeArguments: [coin.type]
    });

    txb.transferObjects([coinObject], recepient);
    console.log(`Withdrew all of type ${coin.type} from manager ${managerId}`);
};

export const checkManagerBalance = (
    managerId: string,
    coin: Coin,
    txb: TransactionBlock
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::balance`,
        arguments: [
            txb.object(managerId),
        ],
        typeArguments: [coin.type]
    });
}

export const generateProofAsOwner = (
    managerId: string,
    txb: TransactionBlock,
) => {
    return txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::generate_proof_as_owner`,
        arguments: [
            txb.object(managerId),
        ],
    });
}

export const generateProofAsTrader = (
    managerId: string,
    tradeCapId: string,
    txb: TransactionBlock,
) => {
    return txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::generate_proof_as_trader`,
        arguments: [
            txb.object(managerId),
            txb.object(tradeCapId),
        ],
    });
}

export const generateProof = (balanceManager: BalanceManager, txb: TransactionBlock) => {
    return balanceManager.tradeCap
        ? generateProofAsTrader(balanceManager.address, balanceManager.tradeCap, txb)
        : generateProofAsOwner(balanceManager.address, txb);
}

export const validateProof = (
    managerId: string,
    tradeProofId: string,
    txb: TransactionBlock,
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::validate_proof`,
        arguments: [
            txb.object(managerId),
            txb.object(tradeProofId),
        ],
    });
}

export const owner = (
    managerId: string,
    txb: TransactionBlock,
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::owner`,
        arguments: [
            txb.object(managerId),
        ],
    });
}

export const id = (
    managerId: string,
    txb: TransactionBlock,
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::id`,
        arguments: [
            txb.object(managerId),
        ],
    });
}
