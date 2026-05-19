import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const PACKAGE = "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982";
const DUSDC = "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC";

async function findPools() {
    console.log("Searching for PoolCreated events for DUSDC...");
    try {
        let cursor = null;
        for (let i = 0; i < 20; i++) { // Search up to 2000 events
            const events = await client.queryEvents({
                query: { MoveEventType: `${PACKAGE}::pool::PoolCreated` },
                cursor: cursor,
                limit: 100
            });
            console.log(`Page ${i}: Found ${events.data.length} events.`);
            for (const e of events.data) {
                if (e.type.includes(DUSDC)) {
                    console.log(`FOUND POOL FOR DUSDC: ${e.parsedJson.pool_id}`);
                    console.log(`Type: ${e.type}`);
                    return;
                }
            }
            if (!events.hasNextPage) break;
            cursor = events.nextCursor;
        }
        console.log("NOT FOUND POOL FOR DUSDC in PoolCreated events.");
    } catch (err) {
        console.error("Error:", err);
    }
}

findPools().catch(console.error);
