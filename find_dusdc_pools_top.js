import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });

async function findPools() {
    try {
        const res = await fetch("https://deepbook-indexer.testnet.mystenlabs.com/pool_created");
        const data = await res.json();
        console.log(`Found ${data.length} total pools in indexer.`);

        for (let i = 0; i < Math.min(data.length, 20); i++) {
            const poolEvent = data[i];
            const poolId = poolEvent.pool_id;
            const pool = await client.getObject({ id: poolId, options: { showType: true } });
            if (pool.data.type.includes("DUSDC")) {
                console.log(`FOUND DUSDC POOL: ${poolId}, Type: ${pool.data.type}`);
            }
        }
    } catch (err) {
        console.error("Error:", err);
    }
}

findPools().catch(console.error);
