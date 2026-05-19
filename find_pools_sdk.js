import { SuiJsonRpcClient, getJsonRpcFullnodeUrl } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient(getJsonRpcFullnodeUrl('testnet'));

const DUSDC = "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC";
const SUI = "0x2::sui::SUI";
const DEEP = "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP";
const DEEPBOOK_PACKAGE = "0x74cd5657843c627f3d80f713b71e9f895bbbeb470956d8a8e1185badf6cc77c8";

async function findPools() {
    console.log("Searching for DeepBook V3 Pools on Testnet...");
    
    const pairs = [
        { base: SUI, quote: DUSDC, name: "SUI/DUSDC" },
        { base: DUSDC, quote: SUI, name: "DUSDC/SUI" },
        { base: SUI, quote: DEEP, name: "SUI/DEEP" },
        { base: DEEP, quote: SUI, name: "DEEP/SUI" }
    ];

    for (const pair of pairs) {
        const poolType = `${DEEPBOOK_PACKAGE}::pool::Pool<${pair.base}, ${pair.quote}>`;
        console.log(`Checking ${pair.name}...`);
        try {
            // queryObjects might not exist on SuiJsonRpcClient if it's very different.
            // Let's check available methods by logging the client or just trying.
            const res = await client.queryObjects({
                filter: { StructType: poolType },
                options: { showContent: true }
            });
            if (res.data.length > 0) {
                console.log(`FOUND ${pair.name}: ${res.data[0].data.objectId}`);
            } else {
                console.log(`NOT FOUND ${pair.name}`);
            }
        } catch (e) {
            console.error(`Error querying ${pair.name}:`, e.message);
        }
    }
}

findPools().catch(console.error);
