import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const DUSDC = "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC";

async function findPredict() {
    console.log(`Searching for Predict objects with DUSDC...`);
    try {
        // Since we don't know the package ID, we search for objects with type containing 'Predict' and the DUSDC type
        // This is hard to do directly with queryObjects without a package ID.
        // But we can check for common shared objects or search events.
        
        // Let's try to find the package ID from recent 'PredictCreated' events if any exist.
        // Or just search for the DUSDC currency registration which might be related.
        
        // Actually, let's look at the simulations/run.sh again to see if it logs any IDs.
        // Wait, I can search for the 'deepbook_predict' package string in the logs.
    } catch (err) {
        console.error("Error:", err);
    }
}

findPredict().catch(console.error);
