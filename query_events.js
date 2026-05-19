import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const PACKAGE = "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982";
const MANAGER_ID = "0x909b5a9684cd56b62e9fb598e794e2128b15552ebae7d5244fe814a90090c244";

async function queryEvents() {
    console.log(`Querying events for BalanceManager: ${MANAGER_ID}`);
    try {
        const events = await client.queryEvents({
            query: { MoveModule: { package: PACKAGE, module: "order_info" } },
            limit: 100,
            descendingOrder: true
        });
        
        let managerEvents = events.data.filter(e => e.parsedJson.balance_manager_id === MANAGER_ID);
        console.log(`Found ${managerEvents.length} events for this manager.`);
        
        for (const e of managerEvents) {
            console.log(JSON.stringify(e, null, 2));
        }
    } catch (err) {
        console.error("Error:", err);
    }
}

queryEvents().catch(console.error);
