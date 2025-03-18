import * as parquet from "parquetjs";
import fs from "fs";

// Function to read and display Parquet data
async function readParquetFile(filePath: string) {
  if (!fs.existsSync(filePath)) {
    console.error(`File not found: ${filePath}`);
    return;
  }

  try {
    const reader = await parquet.ParquetReader.openFile(filePath);
    const cursor = reader.getCursor();

    let record;
    while ((record = await cursor.next())) {
      console.log(record); // Display each row
    }

    await reader.close();
  } catch (error) {
    console.error("Error reading Parquet file:", error);
  }
}

// Call the function
readParquetFile("orderbook_SUI_USDC.parquet"); // Replace with actual file name
