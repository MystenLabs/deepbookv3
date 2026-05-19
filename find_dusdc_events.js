import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const DUSDC_PACKAGE = "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a";

async function findEvents() {
    console.log("Searching for events from DUSDC package...");
    try {
        const events = await client.queryEvents({
            query: { MoveModule: { package: DUSDC_PACKAGE, module: "dusdc" } }
        });
        console.log(`Found ${events.data.length} events.`);
        events.data.forEach(e => {
            console.log(`Type: ${e.type}`);
        });
    } catch (err) {
        console.error("Error:", err);
    }
}

findEvents().catch(console.error);
