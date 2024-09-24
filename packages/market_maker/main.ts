import { Transaction } from "@mysten/sui/transactions";
import { MarketMaker } from "./marketMaker";

(async () => {
    const mm = new MarketMaker();
    // await mm.createAndShareBM();
    await mm.checkBalances();

    // Deposit 1.0 SUI, 1.0 DEEP, 0 DBUSDC, 0 DBUSDT
    const tx = new Transaction();
    await mm.depositCoins(1, 1, 0, 0);
    await mm.signAndExecute(tx);
    await mm.checkBalances();
    
    // withdraw all SUI, DEEP, DBUSDC, DBUSDT
    // await mm.withdrawCoins();
})();