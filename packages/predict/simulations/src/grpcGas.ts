export interface GasCoin {
    objectId: string;
    version: string;
    digest: string;
    balance: string;
}

export interface GasPaymentRef {
    objectId: string;
    version: string;
    digest: string;
}

// Sui smashes every gas-payment coin into the first coin before charging the
// transaction. Select the largest eligible coins until their aggregate balance
// covers the budget; requiring one oversized coin can strand a funded actor
// after faucet refills fragment its balance.
export function selectGasPaymentRefs(
    coins: GasCoin[],
    usedObjectIds: ReadonlySet<string>,
    budget: bigint,
): GasPaymentRef[] {
    const eligible = coins
        .filter((coin) => !usedObjectIds.has(coin.objectId))
        .sort((a, b) => {
            const aBalance = BigInt(a.balance);
            const bBalance = BigInt(b.balance);
            return aBalance === bBalance ? 0 : aBalance > bBalance ? -1 : 1;
        });
    const payment: GasPaymentRef[] = [];
    let balance = 0n;
    for (const coin of eligible) {
        payment.push({
            objectId: coin.objectId,
            version: coin.version,
            digest: coin.digest,
        });
        balance += BigInt(coin.balance);
        if (balance >= budget) return payment;
    }
    throw new Error(`eligible SUI gas balance ${balance} does not cover budget ${budget}`);
}
