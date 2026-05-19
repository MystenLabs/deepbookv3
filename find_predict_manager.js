import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const ADDRESS = "0x55fee70acf52cfaa295c3d995264bfeec53d7db0be3040e2c1e3eac017251e49";

async function findPredictManager() {
    console.log(`Searching for PredictManager for address: ${ADDRESS}`);
    try {
        // Search for shared objects of type PredictManager
        // Since we don't know the package ID, we'll try to find it from the log truncation if possible
        // Actually, let's just search for all objects owned by the address first to see if we missed any
        const objects = await client.getOwnedObjects({
            owner: ADDRESS,
            options: { showType: true, showContent: true }
        });
        
        console.log(`Found ${objects.data.length} owned objects.`);
        for (const obj of objects.data) {
            console.log(`Object: ${obj.data.objectId}, Type: ${obj.data.type}`);
        }
        
    } catch (err) {
        console.error("Error:", err);
    }
}

findPredictManager().catch(console.error);
