import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const DUSDC = "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC";

async function checkPools() {
    console.log(`Searching for pools with DUSDC (${DUSDC})...`);
    try {
        const res = await fetch("https://deepbook-indexer.testnet.mystenlabs.com/pool_created");
        const data = await res.json();
        
        for (const poolEvent of data) {
            const poolId = poolEvent.pool_id;
            try {
                const pool = await client.getObject({ id: poolId, options: { showType: true } });
                const type = pool.data.type;
                if (type.includes(DUSDC)) {
                    console.log(`FOUND DUSDC POOL: ${poolId}, Type: ${type}`);
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
