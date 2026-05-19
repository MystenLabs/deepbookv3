import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const PACKAGE = "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982";
const POOL_ID = "0x1c19362ca52b8ffd7a33cee805a67d40f31e6ba303753fd3a4cfdfacea7163a5";

async function checkBids() {
    console.log(`Checking bids for Pool: ${POOL_ID}`);
    try {
        const events = await client.queryEvents({
            query: { MoveEventType: `${PACKAGE}::order_info::OrderPlaced` },
            limit: 100
        });
        
        let bids = events.data.filter(e => e.parsedJson.pool_id === POOL_ID && e.parsedJson.is_bid === true);
        console.log(`Found ${bids.length} recent bid orders for this pool.`);
        
        if (bids.length > 0) {
            console.log("Sample bid:", JSON.stringify(bids[0].parsedJson, null, 2));
        }
    } catch (err) {
        console.error("Error:", err);
    }
}

checkBids().catch(console.error);
