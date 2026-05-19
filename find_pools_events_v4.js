import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const PACKAGE = "0x74cd5657843c627f3d80f713b71e9f895bbbeb470956d8a8e1185badf6cc77c8";

async function findPools() {
    console.log("Searching for PoolCreated events via MoveModule...");
    try {
        const events = await client.queryEvents({
            query: { MoveModule: { package: PACKAGE, module: "pool" } }
        });
        console.log(`Found ${events.data.length} events.`);
        events.data.forEach(e => {
            if (e.type.includes("PoolCreated")) {
                console.log(`Type: ${e.type}`);
                console.log(`Pool: ${e.parsedJson.pool_id}`);
                console.log(`JSON: ${JSON.stringify(e.parsedJson)}`);
            }
        });
    } catch (err) {
        console.error("Error:", err);
    }
}

findPools().catch(console.error);
