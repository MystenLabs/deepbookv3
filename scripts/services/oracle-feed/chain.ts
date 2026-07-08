// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import type { SuiClientTypes } from "@mysten/sui/client";
import type { Keypair } from "@mysten/sui/cryptography";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import type { Transaction } from "@mysten/sui/transactions";
import { normalizeSuiAddress } from "@mysten/sui/utils";
import type { Config } from "./config";

export type ChainObject = {
  objectId: string;
  version: string;
  digest: string;
  owner: SuiClientTypes.ObjectOwner;
  type: string;
  json?: Record<string, unknown> | null;
  content?: Uint8Array;
};

export type ChainCoin = {
  coinObjectId: string;
  balance: string;
  version: string;
  digest: string;
};

export type ChainDynamicField = {
  name: {
    type: string;
    bcs: Uint8Array;
  };
};

export type ChainChangedObject = {
  objectId: string;
  outputState: string;
  outputVersion: string | null;
  outputDigest: string | null;
};

export type ChainEvent = {
  eventType: string;
  json: Record<string, unknown> | null;
  bcs: Uint8Array;
};

export type ChainTxResponse = {
  digest: string;
  success: boolean;
  status: SuiClientTypes.ExecutionStatus;
  changedObjects: ChainChangedObject[];
  events: ChainEvent[];
};

export type ChainClient = {
  getObject(objectId: string, include?: { json?: boolean; content?: boolean }): Promise<ChainObject>;
  getObjects(
    objectIds: string[],
    include?: { json?: boolean; content?: boolean },
  ): Promise<ChainObject[]>;
  listOwnedObjects(input: {
    owner: string;
    type?: string;
    cursor?: string | null;
  }): Promise<{ objects: ChainObject[]; hasNextPage: boolean; cursor: string | null }>;
  listCoins(input: {
    owner: string;
    coinType?: string;
    cursor?: string | null;
  }): Promise<{ coins: ChainCoin[]; hasNextPage: boolean; cursor: string | null }>;
  listDynamicFields(input: {
    parentId: string;
    cursor?: string | null;
  }): Promise<{ dynamicFields: ChainDynamicField[]; hasNextPage: boolean; cursor: string | null }>;
  simulateReturnValues(tx: Transaction, sender?: string): Promise<Uint8Array[][]>;
  signAndExecuteTransaction(input: {
    transaction: Transaction;
    signer: Keypair;
    includeEvents?: boolean;
  }): Promise<ChainTxResponse>;
  waitForTransaction(input: { digest: string }): Promise<void>;
};

export function makeChainClient(config: Config): ChainClient {
  return new GrpcChainClient(
    new SuiGrpcClient({
      network: config.network,
      baseUrl: config.suiRpcUrl,
    }),
  );
}

class GrpcChainClient implements ChainClient {
  constructor(private readonly client: SuiGrpcClient) {}

  async getObject(
    objectId: string,
    include: { json?: boolean; content?: boolean } = {},
  ): Promise<ChainObject> {
    const resp = await this.client.getObject({
      objectId,
      include,
    });
    return mapObject(resp.object);
  }

  async getObjects(
    objectIds: string[],
    include: { json?: boolean; content?: boolean } = {},
  ): Promise<ChainObject[]> {
    const resp = await this.client.getObjects({
      objectIds,
      include,
    });
    return resp.objects.map((object) => {
      if (object instanceof Error) throw object;
      return mapObject(object);
    });
  }

  async listOwnedObjects(input: {
    owner: string;
    type?: string;
    cursor?: string | null;
  }): Promise<{ objects: ChainObject[]; hasNextPage: boolean; cursor: string | null }> {
    const resp = await this.client.listOwnedObjects({
      owner: input.owner,
      type: input.type,
      cursor: input.cursor,
    });
    return {
      objects: resp.objects.map(mapObject),
      hasNextPage: resp.hasNextPage,
      cursor: resp.cursor,
    };
  }

  async listCoins(input: {
    owner: string;
    coinType?: string;
    cursor?: string | null;
  }): Promise<{ coins: ChainCoin[]; hasNextPage: boolean; cursor: string | null }> {
    const resp = await this.client.listCoins({
      owner: input.owner,
      coinType: input.coinType,
      cursor: input.cursor,
    });
    return {
      coins: resp.objects.map((coin) => ({
        coinObjectId: coin.objectId,
        balance: coin.balance,
        version: coin.version,
        digest: coin.digest,
      })),
      hasNextPage: resp.hasNextPage,
      cursor: resp.cursor,
    };
  }

  async listDynamicFields(input: {
    parentId: string;
    cursor?: string | null;
  }): Promise<{ dynamicFields: ChainDynamicField[]; hasNextPage: boolean; cursor: string | null }> {
    const resp = await this.client.listDynamicFields({
      parentId: input.parentId,
      cursor: input.cursor,
    });
    return {
      dynamicFields: resp.dynamicFields.map((field) => ({
        name: field.name,
      })),
      hasNextPage: resp.hasNextPage,
      cursor: resp.cursor,
    };
  }

  async simulateReturnValues(
    tx: Transaction,
    sender: string = normalizeSuiAddress("0x0"),
  ): Promise<Uint8Array[][]> {
    tx.setSender(sender);
    const resp = await this.client.simulateTransaction<{ commandResults: true }>({
      transaction: tx,
      checksEnabled: false,
      include: { commandResults: true },
    });
    if (resp.$kind === "FailedTransaction") {
      throw new Error(
        resp.FailedTransaction.status.error?.message ?? "simulateTransaction failed",
      );
    }
    return (resp.commandResults ?? []).map((command) =>
      command.returnValues.map((returnValue) => returnValue.bcs),
    );
  }

  async signAndExecuteTransaction(input: {
    transaction: Transaction;
    signer: Keypair;
    includeEvents?: boolean;
  }): Promise<ChainTxResponse> {
    const resp = await this.client.signAndExecuteTransaction({
      transaction: input.transaction,
      signer: input.signer,
      include: { effects: true, events: !!input.includeEvents },
    });
    const tx =
      resp.$kind === "Transaction" ? resp.Transaction : resp.FailedTransaction;
    return {
      digest: tx.digest,
      success: resp.$kind === "Transaction" && tx.status.success,
      status: tx.status,
      changedObjects: (tx.effects?.changedObjects ?? []).map((object) => ({
        objectId: object.objectId,
        outputState: object.outputState,
        outputVersion: object.outputVersion,
        outputDigest: object.outputDigest,
      })),
      events: tx.events ?? [],
    };
  }

  async waitForTransaction(input: { digest: string }): Promise<void> {
    await this.client.waitForTransaction({ digest: input.digest });
  }
}

function mapObject(object: SuiClientTypes.Object<any>): ChainObject {
  return {
    objectId: object.objectId,
    version: object.version,
    digest: object.digest,
    owner: object.owner,
    type: object.type,
    json: object.json,
    content: object.content,
  };
}
