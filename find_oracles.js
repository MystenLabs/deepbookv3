import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });

async function findOracles() {
    console.log(`Searching for OracleSVI shared objects...`);
    try {
        // Search for objects of type containing OracleSVI
        // We'll try to find the package ID by searching for common module name
        const events = await client.queryEvents({
            query: { MoveEventModule: { package: "0x74cd5657843c627f3d80f713b71e9f895bbbeb470956d8a8e1185badf6cc77c8", module: "oracle" } },
            limit: 10,
        });
        console.log(`Found ${events.data.length} events from package 0x74cd...`);
        for (const e of events.data) {
            console.log(`Event Type: ${e.type}`);
        }
        
    } catch (err) {
        console.error("Error:", err);
    }
}

findOracles().catch(console.error);
