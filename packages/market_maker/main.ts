import { Transaction } from "@mysten/sui/transactions";
import { MarketMaker } from "./marketMaker";

(async () => {
    const mm = new MarketMaker();
    // await mm.createAndShareBM();
    // await mm.checkBalances();

    // Deposit 1.0 SUI, 1.0 DEEP, 0 DBUSDC, 0 DBUSDT
    // const tx = new Transaction();
    // await mm.depositCoins(100,100,100,100);
    // await mm.signAndExecute(tx);
    // await mm.checkBalances();
    // const tx = new Transaction();
    // await mm.borrowAndReturnFlashloan(tx, "DEEP_SUI", 1);
    // await mm.signAndExecute(tx);

    const tx = new Transaction();
    // await mm.placeOrder(tx, "DEEP_SUI", 0.98, 10, true);
    await mm.burnDeep(tx, 'SUI_USDC')
    // await mm.burnDeep(tx, 'NS_SUI')
    // await mm.burnDeep(tx, 'NS_USDC')
    // await mm.placeOrder(tx, "DEEP_SUI", 1.02, 1, true);
    // await mm.placeOrdersAroundMid(tx, "DEEP_SUI", 10, 25, deepsuiPrice);
    // await mm.placeOrdersAroundMid(tx, "SUI_DBUSDC", 10, 25, suiPrice);
    // await mm.placeOrdersAroundMid(tx, "DEEP_DBUSDC", 10, 25, 1);
    // await mm.placeOrdersAroundMid(tx, "DBUSDT_DBUSDC", 10, 25, 1);
    await mm.signAndExecute(tx);
    
    // withdraw all SUI, DEEP, DBUSDC, DBUSDT
    // await mm.withdrawCoins();
})();