import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const PACKAGE = "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982";
const SUI = "0x2::sui::SUI";
const DEEP = "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP";

async function findDeepPool() {
    console.log("Searching for SUI/DEEP pool...");
    try {
        // Query events specifically for DEEP
        const events = await client.queryEvents({
            query: { MoveEventType: `${PACKAGE}::order_info::OrderPlaced` }
        });
        
        for (const e of events.data) {
            const poolId = e.parsedJson.pool_id;
            const pool = await client.getObject({ id: poolId, options: { showType: true } });
            const type = pool.data.type;
            if (type.includes(SUI) && type.includes(DEEP)) {
                console.log(`FOUND SUI/DEEP POOL: ${poolId}`);
                console.log(`Type: ${type}`);
                return;
            }
        }
        console.log("NOT FOUND SUI/DEEP POOL in recent events.");
    } catch (err) {
        console.error("Error:", err);
    }
}

findDeepPool().catch(console.error);
