import { Transaction } from "@mysten/sui/transactions";
import {
  GAS_POOL_BUFFER,
  GAS_COIN_AMOUNT,
  ORACLES_PER_PACKAGE,
  MINTS_PER_ORACLE,
} from "./config.js";
import {
  getClient,
  getMinterKeypair,
  getMinterAddress,
  executeTransaction,
} from "./sui-helpers.js";
import { Logger } from "./logger.js";
import { readManifest } from "./manifest.js";

const SUI_COIN_TYPE = "0x2::sui::SUI";

export class GasPool {
  private available: string[] = [];
  private logger: Logger;

  constructor() {
    this.logger = new Logger("gas-pool");
  }

  /**
   * Initialize the gas pool by reading the manifest, computing the required
   * pool size, and ensuring we have enough pre-split SUI coins.
   */
  async initialize(activePackageCount: number): Promise<void> {
    const poolSize =
      activePackageCount * ORACLES_PER_PACKAGE * MINTS_PER_ORACLE +
      GAS_POOL_BUFFER;

    this.logger.info("Initializing gas pool", {
      activePackageCount,
      poolSize,
      targetCoinAmount: GAS_COIN_AMOUNT.toString(),
    });

    const minterAddress = getMinterAddress();
    const client = getClient();

    // Fetch all SUI coins owned by minter
    const coins = await this.fetchAllCoins(minterAddress);

    this.logger.info(`Found ${coins.length} existing SUI coins`);

    if (coins.length === 0) {
      this.logger.warn(
        "No SUI coins found for minter wallet. Fund the wallet before running the fuzz worker.",
      );
      return;
    }

    if (coins.length >= poolSize) {
      // Already have enough coins — just populate the queue
      this.available = coins.slice(0, poolSize).map((c) => c.coinObjectId);
      this.logger.info(`Pool populated with ${this.available.length} existing coins`);
      return;
    }

    // Not enough coins — merge all into primary, then split
    this.logger.info(
      `Need ${poolSize} coins but only have ${coins.length}. Merging and splitting...`,
    );

    const tx = new Transaction();

    // Merge all non-primary coins into the gas coin (coin[0] is used as gas)
    if (coins.length > 1) {
      const mergeTargets = coins.slice(1).map((c) => c.coinObjectId);
      tx.mergeCoins(
        tx.gas,
        mergeTargets.map((id) => tx.object(id)),
      );
    }

    // Split into poolSize coins of TARGET_COIN_AMOUNT each
    const splitAmounts = Array.from({ length: poolSize }, () =>
      tx.pure.u64(GAS_COIN_AMOUNT),
    );
    const splitResult = tx.splitCoins(tx.gas, splitAmounts);

    // We need to transfer each split coin back to ourselves so they become
    // independent objects we can reference by ID later.
    for (let i = 0; i < poolSize; i++) {
      tx.transferObjects([splitResult[i]], tx.pure.address(minterAddress));
    }

    const keypair = getMinterKeypair();
    const result = await executeTransaction(tx, keypair);

    // Extract created coin object IDs from the transaction result
    const created = (result.objectChanges ?? []).filter(
      (c: any) =>
        c.type === "created" &&
        c.objectType?.includes("0x2::coin::Coin<0x2::sui::SUI>"),
    );

    this.available = created.map((c: any) => c.objectId as string);

    this.logger.info(`Pool initialized with ${this.available.length} coins`, {
      requested: poolSize,
      created: this.available.length,
    });
  }

  /**
   * Check out a gas coin from the pool.
   * Returns null if the pool is empty.
   */
  checkout(): string | null {
    return this.available.pop() ?? null;
  }

  /**
   * Return a gas coin to the pool after use.
   */
  checkin(coinId: string): void {
    this.available.push(coinId);
  }

  /**
   * Current number of available coins in the pool.
   */
  get size(): number {
    return this.available.length;
  }

  /**
   * Fetch all SUI coins for a given address, handling pagination.
   */
  private async fetchAllCoins(
    owner: string,
  ): Promise<Array<{ coinObjectId: string; balance: string }>> {
    const client = getClient();
    const allCoins: Array<{ coinObjectId: string; balance: string }> = [];
    let cursor: string | null | undefined = undefined;
    let hasNext = true;

    while (hasNext) {
      const page = await client.getCoins({
        owner,
        coinType: SUI_COIN_TYPE,
        ...(cursor ? { cursor } : {}),
      });

      for (const coin of page.data) {
        allCoins.push({
          coinObjectId: coin.coinObjectId,
          balance: coin.balance,
        });
      }

      hasNext = page.hasNextPage;
      cursor = page.nextCursor;
    }

    return allCoins;
  }
}
