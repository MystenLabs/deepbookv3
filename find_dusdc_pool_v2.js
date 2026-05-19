import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const PACKAGE = "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982";
const DUSDC = "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC";

async function findPools() {
    console.log("Searching for DUSDC pools in OrderPlaced events...");
    try {
        let cursor = null;
        for (let i = 0; i < 10; i++) {
            const events = await client.queryEvents({
                query: { MoveEventType: `${PACKAGE}::order_info::OrderPlaced` },
                cursor: cursor,
                limit: 100
            });
            console.log(`Page ${i}: Found ${events.data.length} events.`);
            for (const e of events.data) {
                const poolId = e.parsedJson.pool_id;
                const pool = await client.getObject({ id: poolId, options: { showType: true } });
                const type = pool.data.type;
                if (type.includes(DUSDC)) {
                    console.log(`FOUND DUSDC POOL: ${poolId}`);
                    console.log(`Type: ${type}`);
                    return;
                }
            }
            if (!events.hasNextPage) break;
            cursor = events.nextCursor;
        }
        console.log("NOT FOUND DUSDC POOL in recent events.");
    } catch (err) {
        console.error("Error:", err);
    }
}

findPools().catch(console.error);
