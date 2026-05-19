import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const PACKAGE = "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982";

async function findPools() {
    console.log("Fetching ALL OrderPlaced events to find pools...");
    try {
        const events = await client.queryEvents({
            query: { MoveEventType: `${PACKAGE}::order_info::OrderPlaced` }
        });
        console.log(`Found ${events.data.length} events.`);
        const poolIds = new Set();
        events.data.forEach(e => {
            poolIds.add(e.parsedJson.pool_id);
        });
        
        console.log(`Found ${poolIds.size} unique pools.`);
        for (const poolId of poolIds) {
            try {
                const pool = await client.getObject({ id: poolId, options: { showType: true } });
                console.log(`Pool ${poolId}: ${pool.data.type}`);
            } catch (e) {
                console.log(`Pool ${poolId}: Error fetching type`);
            }
        }
    } catch (err) {
        console.error("Error:", err);
    }
}

findPools().catch(console.error);
