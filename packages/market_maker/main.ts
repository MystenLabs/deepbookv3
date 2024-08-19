import { Transaction } from "@mysten/sui/transactions";
import { MarketMaker } from "./marketMaker";
// import fetch from "node-fetch";


(async () => {
    const mm = new MarketMaker();
    // await mm.createAndShareBM();
    // await mm.depositCoins(800, 25000, 25000, 25000);
    // await mm.withdrawCoins();

    await mm.checkBalances();
    let response = await fetch("https://api.dexscreener.com/latest/dex/pairs/sui/0x5eb2dfcdd1b15d2021328258f6d5ec081e9a0cdcfa9e13a0eaeb9b5f7505ca78");
    let json = await response.json();
    let pair = json.pairs[0];
    let priceUsd = pair.priceUsd;
    
    let suiPrice = Math.round(priceUsd * 100) / 100;
    let deepsuiPrice = Math.round((1 / suiPrice) * 100) / 100;
    console.log(`SUI price: ${suiPrice}, DEEP_SUI price: ${deepsuiPrice}`);

    // await mm.printBook("DEEP_SUI");
    // await mm.printBook("SUI_DBUSDC");
    // await mm.printBook("DEEP_DBUSDC");
    // await mm.printBook("DBUSDT_DBUSDC");

    const tx = new Transaction();
    await mm.placeOrdersAroundMid(tx, "DEEP_SUI", 3, 25, deepsuiPrice);
    await mm.placeOrdersAroundMid(tx, "SUI_DBUSDC", 3, 25, suiPrice);
    await mm.placeOrdersAroundMid(tx, "DEEP_DBUSDC", 3, 25, 1);
    await mm.placeOrdersAroundMid(tx, "DBUSDT_DBUSDC", 3, 25, 1);
    // await mm.placeOrder(tx, "DBUSDT_DBUSDC", 1.5, 1, false);
    await mm.signAndExecute(tx);

    await mm.printBook("DEEP_SUI");
    await mm.printBook("SUI_DBUSDC");
    await mm.printBook("DEEP_DBUSDC");
    await mm.printBook("DBUSDT_DBUSDC");
})();