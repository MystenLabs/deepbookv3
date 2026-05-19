import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });

async function findAll() {
    console.log(`Searching for Predict related objects...`);
    try {
        // Try some common package IDs or search for the module name
        // We can search for events first to find the package ID
        const events = await client.queryEvents({
            query: { MoveEventModule: { package: "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982", module: "predict" } },
            limit: 10,
        });
        console.log(`Found ${events.data.length} events from package 0xfb28...`);
        for (const e of events.data) {
            console.log(`Event Type: ${e.type}`);
        }
        
    } catch (err) {
        console.error("Error:", err);
    }
}

findAll().catch(console.error);
