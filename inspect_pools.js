import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const PACKAGE = "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982";

async function findPools() {
    console.log("Fetching OrderPlaced events...");
    try {
        const events = await client.queryEvents({
            query: { MoveEventType: `${PACKAGE}::order_info::OrderPlaced` }
        });
        console.log(`Found ${events.data.length} events.`);
        const pools = new Set();
        events.data.forEach(e => {
            pools.add(e.parsedJson.pool_id);
        });
        console.log("Pool IDs found:", Array.from(pools));
        
        // Let's inspect the first pool found
        if (Array.from(pools).length > 0) {
            const poolId = Array.from(pools)[0];
            const pool = await client.getObject({ id: poolId, options: { showType: true, showContent: true } });
            console.log(`Pool ${poolId} Type: ${pool.data.type}`);
        }
    } catch (err) {
        console.error("Error:", err);
    }
}

findPools().catch(console.error);
