import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const DUSDC_TYPE = "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC";

async function findDUSDCEvents() {
    console.log(`Searching for events related to DUSDC: ${DUSDC_TYPE}`);
    try {
        // Search for transactions that have DUSDC in their balance changes or move calls
        // This is still hard. Let's try to search for the package ID of DUSDC to see its recent activity.
        const txs = await client.queryTransactionBlocks({
            filter: { InputObject: "0xf3000dff421833d4bb8ed58fac146d691a3aaba2785aa1989af65a7089ca3e9c" }, // DUSDC TreasuryCap or similar?
            limit: 10,
        });
        // Actually, the DUSDC TreasuryCap ID from balance check was 0xf300...
        console.log(`Found ${txs.data.length} transactions for DUSDC related object.`);
        
    } catch (err) {
        console.error("Error:", err);
    }
}

findDUSDCEvents().catch(console.error);
