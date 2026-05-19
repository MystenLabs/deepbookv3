import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const USDC_MOCK = "0xea10912247c015ead590e481ae8545ff1518492dee41d6d03abdad828c1d2bde::usdc::USDC";

async function findPools() {
    console.log(`Searching for pools with Mock USDC: ${USDC_MOCK}`);
    try {
        const res = await fetch("https://deepbook-indexer.testnet.mystenlabs.com/pool_created");
        const data = await res.json();

        for (const poolEvent of data) {
            const poolId = poolEvent.pool_id;
            try {
                const pool = await client.getObject({ id: poolId, options: { showType: true } });
                const type = pool.data.type;
                if (type.includes(USDC_MOCK)) {
                    console.log(`FOUND POOL: ${poolId}, Type: ${type}`);
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
