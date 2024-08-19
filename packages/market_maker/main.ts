import { Transaction } from "@mysten/sui/transactions";
import { MarketMaker } from "./marketMaker";

(async () => {
    const mm = new MarketMaker();
    await mm.printBook("DEEP_SUI");
    await mm.printBook("SUI_DBUSDC");
    await mm.printBook("DEEP_DBUSDC");
    await mm.printBook("DBUSDT_DBUSDC");

    const tx = new Transaction();
    await mm.placeOrdersAroundMid(tx, "DEEP_SUI", 4, 10);
    await mm.placeOrdersAroundMid(tx, "SUI_DBUSDC", 4, 10);
    await mm.placeOrdersAroundMid(tx, "DEEP_DBUSDC", 4, 10);
    await mm.placeOrdersAroundMid(tx, "DBUSDT_DBUSDC", 4, 10);
    await mm.signAndExecute(tx);

    await mm.printBook("DEEP_SUI");
    await mm.printBook("SUI_DBUSDC");
    await mm.printBook("DEEP_DBUSDC");
    await mm.printBook("DBUSDT_DBUSDC");
})();