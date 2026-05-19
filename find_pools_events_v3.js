import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const PACKAGE = "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982";
const SUI = "0x2::sui::SUI";
const DUSDC = "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a::dusdc::DUSDC";
const DEEP = "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP";

async function findPools() {
    console.log("Searching for PoolCreated events on Original ID...");
    const queries = [
        `${PACKAGE}::pool::PoolCreated<${SUI}, ${DUSDC}>`,
        `${PACKAGE}::pool::PoolCreated<${DUSDC}, ${SUI}>`,
        `${PACKAGE}::pool::PoolCreated<${SUI}, ${DEEP}>`,
        `${PACKAGE}::pool::PoolCreated<${DEEP}, ${SUI}>`
    ];

    for (const q of queries) {
        console.log(`Checking ${q}...`);
        try {
            const events = await client.queryEvents({
                query: { MoveEventType: q }
            });
            console.log(`Found ${events.data.length} events for ${q}.`);
            events.data.forEach(e => {
                console.log(`Pool: ${e.parsedJson.pool_id}`);
                console.log(`JSON: ${JSON.stringify(e.parsedJson)}`);
            });
        } catch (err) {
            console.error(`Error for ${q}:`, err.message);
        }
    }
}

findPools().catch(console.error);
