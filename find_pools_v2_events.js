import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const PACKAGE = "0x000000000000000000000000000000000000000000000000000000000000dee9";

async function findPools() {
    console.log("Searching for PoolCreated events on 0xdee9...");
    try {
        const events = await client.queryEvents({
            query: { MoveEventType: `${PACKAGE}::clob::PoolCreated` }
        });
        console.log(`Found ${events.data.length} events.`);
        events.data.forEach(e => {
            console.log(`Pool: ${e.parsedJson.pool_id}`);
            console.log(`Base: ${e.parsedJson.base_asset.name}`);
            console.log(`Quote: ${e.parsedJson.quote_asset.name}`);
        });
    } catch (err) {
        console.error("Error:", err);
    }
}

findPools().catch(console.error);
