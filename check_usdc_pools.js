import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });

async function checkPools() {
    console.log("Checking all pools for any USDC-like tokens...");
    try {
        const res = await fetch("https://deepbook-indexer.testnet.mystenlabs.com/pool_created");
        const data = await res.json();
        
        for (const poolEvent of data) {
            const poolId = poolEvent.pool_id;
            try {
                const pool = await client.getObject({ id: poolId, options: { showType: true } });
                const type = pool.data.type;
                if (type.toLowerCase().includes("usdc")) {
                    console.log(`FOUND USDC POOL: ${poolId}, Type: ${type}`);
                }
            } catch (e) {
                // skip errors
            }
        }
    } catch (err) {
        console.error("Error:", err);
    }
}

checkPools().catch(console.error);
