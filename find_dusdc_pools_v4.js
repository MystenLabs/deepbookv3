import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const PACKAGE = "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982";
const DUSDC = "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC";

async function findDUSDCPools() {
    console.log(`Searching for DeepBook V3 Pools with DUSDC...`);
    try {
        // Query events to find PoolCreated events
        const events = await client.queryEvents({
            query: { MoveEventModule: { package: PACKAGE, module: "registry" } },
            limit: 100,
            descendingOrder: true
        });
        
        console.log(`Found ${events.data.length} events from registry.`);
        for (const e of events.data) {
            if (e.type.includes("PoolCreated")) {
                const typeArgs = e.type.split('<')[1].split('>')[0].split(',').map(s => s.trim());
                if (typeArgs.includes(DUSDC)) {
                    console.log(`FOUND POOL: ${e.parsedJson.pool_id}`);
                    console.log(`Base: ${typeArgs[0]}`);
                    console.log(`Quote: ${typeArgs[1]}`);
                }
            }
        }
    } catch (err) {
        console.error("Error:", err);
    }
}

findDUSDCPools().catch(console.error);
