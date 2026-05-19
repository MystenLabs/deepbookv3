const { execSync } = require('child_process');

const SUI_BIN = './sui.exe';

function runSui(args) {
    try {
        return execSync(`& "${SUI_BIN}" client ${args}`, { shell: 'powershell.exe', encoding: 'utf8' });
    } catch (e) {
        return null;
    }
}

console.log("Searching for DeepBook V3 Pools...");

// We'll search for objects of type pool::Pool
// On Testnet, DeepBook V3 package is often 0x74cd5657843c627f3d80f713b71e9f895bbbeb470956d8a8e1185badf6cc77c8
const PACKAGE_ID = "0x74cd5657843c627f3d80f713b71e9f895bbbeb470956d8a8e1185badf6cc77c8";

// Since we can't easily search globally by type without a full indexer, 
// let's try to find if there are any pool objects owned by the active address or shared.
// Actually, pools are shared objects.

// We can try to use 'sui client call' to get the pool id from the registry if we find the registry.
// But first, let's try to see if there's any pool mentioned in events.

console.log("Checking events for PoolCreated...");
const events = runSui(`events --query-all --json`);
if (events) {
    const data = JSON.parse(events);
    const poolCreated = data.filter(e => e.type.includes("PoolCreated"));
    console.log(`Found ${poolCreated.length} PoolCreated events.`);
    poolCreated.forEach(e => {
        console.log(`Pool: ${e.parsedJson.pool_id}, Base: ${e.type.split('<')[1].split(',')[0]}, Quote: ${e.type.split(',')[1].split('>')[0].trim()}`);
    });
} else {
    console.log("Failed to fetch events.");
}
