import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { DEPLOYER_KEY, ORACLE_KEY, MINTER_KEY, SUI_RPC_URL } from "./config.js";

// Create keypair from suiprivkey bech32 format
export function keypairFromSecretKey(suiPrivKey: string): Ed25519Keypair {
  const { secretKey } = decodeSuiPrivateKey(suiPrivKey);
  return Ed25519Keypair.fromSecretKey(secretKey);
}

// Lazy singletons
let _client: SuiJsonRpcClient | null = null;
let _deployer: Ed25519Keypair | null = null;
let _oracle: Ed25519Keypair | null = null;
let _minter: Ed25519Keypair | null = null;

export function getClient(): SuiJsonRpcClient {
  if (!_client) _client = new SuiJsonRpcClient({ url: SUI_RPC_URL, network: "testnet" });
  return _client;
}

export function getDeployerKeypair(): Ed25519Keypair {
  if (!_deployer) _deployer = keypairFromSecretKey(DEPLOYER_KEY);
  return _deployer;
}

export function getOracleKeypair(): Ed25519Keypair {
  if (!_oracle) _oracle = keypairFromSecretKey(ORACLE_KEY);
  return _oracle;
}

export function getMinterKeypair(): Ed25519Keypair {
  if (!_minter) _minter = keypairFromSecretKey(MINTER_KEY);
  return _minter;
}

export function getDeployerAddress(): string {
  return getDeployerKeypair().getPublicKey().toSuiAddress();
}

export function getOracleAddress(): string {
  return getOracleKeypair().getPublicKey().toSuiAddress();
}

export function getMinterAddress(): string {
  return getMinterKeypair().getPublicKey().toSuiAddress();
}

// Execute transaction with full response
export async function executeTransaction(
  tx: Transaction,
  keypair: Ed25519Keypair,
): Promise<any> {
  const client = getClient();
  const sender = keypair.getPublicKey().toSuiAddress();
  tx.setSender(sender);

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer: keypair,
    options: {
      showEffects: true,
      showEvents: true,
      showObjectChanges: true,
    },
  });

  // Check success
  const status = (result as any).effects?.status;
  if (status?.status !== "success") {
    throw new Error(`Transaction failed: ${status?.error ?? JSON.stringify((result as any).effects).slice(0, 500)}`);
  }

  return result;
}

// Wait for transaction confirmation and get full details
export async function waitForTransaction(digest: string): Promise<any> {
  const client = getClient();
  return client.waitForTransaction({
    digest,
    options: {
      showEffects: true,
      showEvents: true,
      showObjectChanges: true,
    },
  });
}

// Parse created object IDs from transaction result by type substring
export function findCreatedObjects(result: any, typeSubstring?: string): Array<{ objectId: string; type: string; owner: any }> {
  const changes = result.objectChanges ?? [];
  return changes
    .filter((c: any) => c.type === "created" && (!typeSubstring || c.objectType?.includes(typeSubstring)))
    .map((c: any) => ({ objectId: c.objectId, type: c.objectType, owner: c.owner }));
}

// Find published package ID from transaction result
export function findPublishedPackage(result: any): string | null {
  const changes = result.objectChanges ?? [];
  const published = changes.find((c: any) => c.type === "published");
  return published?.packageId ?? null;
}

// Parse events by type substring
export function findEvents(result: any, typeSubstring: string): any[] {
  return (result.events ?? []).filter((e: any) => e.type?.includes(typeSubstring));
}

// Normalize object ID to 0x-prefixed, 64-char hex
export function normId(id: string): string {
  return "0x" + id.replace(/^0x/, "").padStart(64, "0");
}

// Wait for an object's version to advance (e.g., after a tx mutates it)
export async function waitForObjectVersion(objectId: string, maxAttempts = 10, intervalMs = 2000): Promise<void> {
  const client = getClient();
  // First, get the current version
  let initialVersion: string | null = null;
  try {
    const resp = await client.getObject({ id: objectId, options: {} });
    initialVersion = String((resp as any).data?.version ?? "");
  } catch {}

  // Poll until version changes or timeout
  for (let i = 0; i < maxAttempts; i++) {
    await new Promise((r) => setTimeout(r, intervalMs));
    try {
      const resp = await client.getObject({ id: objectId, options: {} });
      const version = String((resp as any).data?.version ?? "");
      if (version && version !== initialVersion) return;
    } catch {}
  }
  // Don't throw — proceed anyway and let the tx fail with a clear error
}

// Wait until an object is available on the RPC node (polls with backoff)
export async function waitForObject(objectId: string, maxAttempts = 30, intervalMs = 1000): Promise<void> {
  const client = getClient();
  for (let i = 0; i < maxAttempts; i++) {
    try {
      const resp = await client.getObject({ id: objectId, options: { showType: true } });
      if ((resp as any).data) return;
    } catch {}
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(`Object ${objectId} not available after ${maxAttempts} attempts`);
}
