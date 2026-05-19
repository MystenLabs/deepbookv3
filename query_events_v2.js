import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const PACKAGE = "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982";
const MANAGER_ID = "0xe6e62fd71aeeef159092769ac50e85b5c5846dc05c7adfac97163cc5a868a3d0";

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
