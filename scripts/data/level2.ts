import fetch from "node-fetch";
import * as parquet from "parquetjs";
import fs from "fs-extra";

// API Endpoints
const POOLS_API_URL =
  "https://deepbook-indexer.mainnet.mystenlabs.com/get_pools";
const ORDERBOOK_API_URL =
  "https://deepbook-indexer.mainnet.mystenlabs.com/orderbook";

// Define interface for pool data
interface Pool {
  pool_id: string;
  pool_name: string;
}

// Function to fetch all available pools
async function fetchPools(): Promise<Pool[]> {
  try {
    const response = await fetch(POOLS_API_URL);
    if (!response.ok) throw new Error(`HTTP error! Status: ${response.status}`);

    const pools = (await response.json()) as Pool[];

    if (!Array.isArray(pools)) {
      throw new Error("Invalid data format: Expected an array");
    }

    return pools;
  } catch (error) {
    console.error("Error fetching pools:", error);
    return [];
  }
}

// Function to fetch order book data for a specific pool
async function fetchOrderBook(poolName: string): Promise<any> {
  try {
    const response = await fetch(`${ORDERBOOK_API_URL}/${poolName}?depth=100`);
    if (!response.ok) throw new Error(`HTTP error! Status: ${response.status}`);

    return await response.json();
  } catch (error) {
    console.error(`Error fetching order book for ${poolName}:`, error);
    return null;
  }
}

// Function to save data as a Parquet file (handling append manually)
async function saveAsParquet(poolName: string, data: any) {
  if (!data) {
    console.error(`No data to save for ${poolName}.`);
    return;
  }

  const filePath = `orderbook_${poolName}.parquet`;

  // Define Parquet schema
  const schema = new parquet.ParquetSchema({
    timestamp: { type: "INT64" }, // Order book snapshot timestamp
    pool_name: { type: "UTF8" }, // Pool name for tracking
    price: { type: "DOUBLE" },
    size: { type: "DOUBLE" },
    side: { type: "UTF8" }, // "bid" or "ask"
  });

  const timestamp = parseInt(data.timestamp);

  // Flatten bids and asks with side labels
  const newRows = [
    ...data.bids.map((bid: [string, string]) => ({
      timestamp,
      pool_name: poolName,
      price: parseFloat(bid[0]),
      size: parseFloat(bid[1]),
      side: "bid",
    })),
    ...data.asks.map((ask: [string, string]) => ({
      timestamp,
      pool_name: poolName,
      price: parseFloat(ask[0]),
      size: parseFloat(ask[1]),
      side: "ask",
    })),
  ];

  let existingRows: any[] = [];

  // Check if the Parquet file exists, and read its existing data
  if (fs.existsSync(filePath)) {
    console.log(`Appending to existing file: ${filePath}`);
    const reader = await parquet.ParquetReader.openFile(filePath);
    const cursor = reader.getCursor();
    let record;

    while ((record = await cursor.next())) {
      existingRows.push(record);
    }
    await reader.close();
  }

  // Combine old and new data
  const allRows = [...existingRows, ...newRows];

  // Write the combined data back to the Parquet file
  const writer = await parquet.ParquetWriter.openFile(schema, filePath);
  for (const row of allRows) {
    await writer.appendRow(row);
  }

  await writer.close();
  console.log(`Saved order book for ${poolName} in ${filePath}`);
}

// Main function to fetch and save all pools
async function main() {
  const pools = await fetchPools();
  if (pools.length === 0) {
    console.error("No pools found.");
    return;
  }

  for (const pool of pools) {
    console.log(`Fetching order book for ${pool.pool_name}...`);
    const orderBookData = await fetchOrderBook(pool.pool_name);
    await saveAsParquet(pool.pool_name, orderBookData);
  }
}

main().catch(console.error);
