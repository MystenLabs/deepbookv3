import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const DEEP_PACKAGE = "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8";

async function findEvents() {
    console.log("Searching for events from DEEP package...");
    try {
        const events = await client.queryEvents({
            query: { MoveModule: { package: DEEP_PACKAGE, module: "deep" } }
        });
        console.log(`Found ${events.data.length} events.`);
        events.data.forEach(e => {
            console.log(`Type: ${e.type}`);
            console.log(`JSON: ${JSON.stringify(e.parsedJson)}`);
        });
    } catch (err) {
        console.error("Error:", err);
    }
}

findEvents().catch(console.error);
