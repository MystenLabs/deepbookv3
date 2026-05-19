import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });

async function findPools() {
    try {
        const res = await fetch("https://deepbook-indexer.testnet.mystenlabs.com/pool_created");
        const data = await res.json();
        console.log(`Found ${data.length} total pools in indexer.`);

        const pools = await client.multiGetObjects({
            ids: data.map(p => p.pool_id),
            options: { showType: true }
        });

        for (const pool of pools) {
            if (pool.data && pool.data.type && pool.data.type.includes("DUSDC")) {
                console.log(`FOUND DUSDC POOL: ${pool.data.objectId}, Type: ${pool.data.type}`);
            }
        }
    } catch (err) {
        console.error("Error:", err);
    }
}

findPools().catch(console.error);
