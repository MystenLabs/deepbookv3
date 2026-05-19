import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });

async function findPredict() {
    console.log(`Searching for Predict shared objects...`);
    try {
        // We'll search for objects with type containing '::predict::Predict'
        // Since we don't know the package, we'll try to find it from the user's past transactions or common ones.
        
        // Let's try to query all objects that are shared.
        // Actually, we can't query all shared objects.
        
        // But wait! I saw 0x8903... earlier in the user's activity.
        // Let's check THAT package.
        const pkgId = "0x8903298ba49a8e83d438e014b2cfd18404324f3a0274b9507b520d5745b85208";
        const pkg = await client.getObject({ id: pkgId, options: { showContent: true } });
        console.log(`Package 0x8903... details:`, pkg.data.type);
        
    } catch (err) {
        console.error("Error:", err);
    }
}

findPredict().catch(console.error);
