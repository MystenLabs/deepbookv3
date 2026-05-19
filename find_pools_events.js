import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });

async function findPools() {
    console.log("Searching for PoolCreated events...");
    try {
        const events = await client.queryEvents({
            query: { MoveEventType: '0x74cd5657843c627f3d80f713b71e9f895bbbeb470956d8a8e1185badf6cc77c8::pool::PoolCreated' }
        });
        console.log(`Found ${events.data.length} events.`);
        events.data.forEach(e => {
            console.log(`Pool: ${e.parsedJson.pool_id}`);
            console.log(`Type: ${e.type}`);
            console.log(`JSON: ${JSON.stringify(e.parsedJson)}`);
        });
    } catch (err) {
        console.error("Error:", err);
    }
}

findPools().catch(console.error);
