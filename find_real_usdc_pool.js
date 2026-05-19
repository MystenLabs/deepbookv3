import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const TYPES = [
    "0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC",
    "0xea10912247c015ead590e481ae8545ff1518492dee41d6d03abdad828c1d2bde::usdc::USDC"
];

async function findPools() {
    console.log(`Searching for pools with USDC types...`);
    try {
        const res = await fetch("https://deepbook-indexer.testnet.mystenlabs.com/pool_created");
        const data = await res.json();

        for (const poolEvent of data) {
            const poolId = poolEvent.pool_id;
            try {
                const pool = await client.getObject({ id: poolId, options: { showType: true } });
                const type = pool.data.type;
                for (const t of TYPES) {
                    if (type.includes(t)) {
                        console.log(`FOUND POOL: ${poolId}, Type: ${type}`);
                    }
                }
            } catch (e) {
                // skip
            }
        }
    } catch (err) {
        console.error("Error:", err);
    }
}

findPools().catch(console.error);
