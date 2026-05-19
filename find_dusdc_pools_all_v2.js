import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });

async function findPools() {
    try {
        const res = await fetch("https://deepbook-indexer.testnet.mystenlabs.com/pool_created");
        const data = await res.json();
        console.log(`Found ${data.length} total pools in indexer.`);

        const ids = data.map(p => p.pool_id);
        const chunk1 = ids.slice(0, 50);
        const chunk2 = ids.slice(50);

        const pools1 = await client.multiGetObjects({
            ids: chunk1,
            options: { showType: true }
        });
        const pools2 = await client.multiGetObjects({
            ids: chunk2,
            options: { showType: true }
        });

        const allPools = [...pools1, ...pools2];

        for (const pool of allPools) {
            if (pool.data && pool.data.type && pool.data.type.includes("DUSDC")) {
                console.log(`FOUND DUSDC POOL: ${pool.data.objectId}, Type: ${pool.data.type}`);
            }
        }
    } catch (err) {
        console.error("Error:", err);
    }
}

findPools().catch(console.error);
