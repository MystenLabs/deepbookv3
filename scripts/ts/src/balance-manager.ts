
import { TransactionBlock, TransactionResult } from "@mysten/sui.js/transactions";
import { getActiveAddress, signAndExecute } from "./utils";
import { normalizeSuiAddress } from "@mysten/sui.js/utils";
import { SuiClient, getFullnodeUrl } from "@mysten/sui.js/client";
import { bcs } from "@mysten/sui.js/bcs";

// =================================================================
// Constants to update when running the different transactions
// =================================================================

const ENV = 'testnet';
const client = new SuiClient({ url: getFullnodeUrl(ENV) });

// The package id of the `deepbook` package
const DEEPBOOK_PACKAGE_ID = `0x22ed917fa56afe09677314871a2997a111ebacd1f622b6cfed3a4422aa4d2e06`;

// Create manager and give ID
const MANAGER_ID = `0x08b49d7067383d17cdd695161b247e2f617e0d9095da65edb85900e7b6f82de4`;

// Update to the base and quote types of the pool
const ASLAN_TYPE = `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::aslancoin::ASLANCOIN`;
const TONY_TYPE = `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::tonycoin::TONYCOIN`;
const DEEP_TYPE = `0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP`;
const SUI_TYPE = `0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI`;

// Give the id of the coin objects to deposit into balance manager
const DEEP_COIN_ID = `0x363fc7964af3ce74ec92ba37049601ffa88dfa432c488130b340b52d58bdcf50`;
const SUI_COIN_ID = `0x0064c4fd7c1c8f56ee8fb1d564bcd1c32a274156b942fd0ea25d605e3d2c5315`;
const TONY_COIN_ID = `0xd5dd3f2623fd809bf691362b6838efc7b84e12c49741299787439f755e5ee765`;

const DEEP_SCALAR = 1000000;
const SUI_SCALAR = 1000000000;
const TONY_SCALAR = 1000000;
const MY_ADDRESS = getActiveAddress();

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
    scalar: number,
    coinId: string,
    coinType: string,
    txb: TransactionBlock
) => {
    var deposit;
    if (coinType == SUI_TYPE) {
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
    scalar: number,
    coinType: string,
    txb: TransactionBlock
) => {
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
    scalar: number,
    txb: TransactionBlock
) => {
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
    // await depositIntoManager(5000, DEEP_SCALAR, DEEP_COIN_ID, DEEP_TYPE, txb);
    // await depositIntoManager(40, SUI_SCALAR, SUI_COIN_ID, SUI_TYPE, txb);
    // await depositIntoManager(5000, TONY_SCALAR, TONY_COIN_ID, TONY_TYPE, txb);
    // await withdrawFromManager(5, SUI_SCALAR, SUI_TYPE, txb);
    // await withdrawAllFromManager(SUI_TYPE, txb);
    await checkManagerBalance(DEEP_TYPE, DEEP_SCALAR, txb);
    // await checkManagerBalance(SUI_TYPE, SUI_SCALAR, txb);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
