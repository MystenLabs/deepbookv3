// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { execSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { coinWithBalance, Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner } from "../utils/utils.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..");
const DEPLOYMENT_JSON = resolve(
  REPO_ROOT,
  "packages",
  "predict",
  "deployment",
  "deployment.testnet.json",
);

const SUI = process.env.SUI_BINARY ?? "sui";
const GAS_BUDGET = BigInt(process.env.GAS_BUDGET ?? "1000000000");
const MIN_MARKET_LEAD_MS = Number(process.env.MIN_MARKET_LEAD_MS ?? "90000");

const LIFECYCLE_CAP_RECIPIENT =
  "0xc230d3a341a4fddd752979fbac7625fb2b302ea28202d218a81b007653380c82";

const CLOCK_ID = "0x6";
const ACCUMULATOR_ROOT_ID = "0xacc";
const NETWORK = "testnet" as const;

const DUSDC_DECIMALS = 1_000_000n;
const LOCK_CAPITAL_AMOUNT = 10n * DUSDC_DECIMALS;
const BOOTSTRAP_SUPPLY_AMOUNT = 10_000_000n * DUSDC_DECIMALS;
const TICK_SIZE = 1_000_000_000n;
const ADMISSION_TICK_SIZE = 10n * TICK_SIZE;

const ASSET = {
  name: "BTC_USD",
  propbookUnderlyingId: 1,
  pythLazerFeedId: 1,
  blockScholesSourceId: 1,
} as const;

const CADENCES = [
  {
    id: 1,
    name: "5m",
    periodMs: 5 * 60_000,
    windowSize: 3n,
    marketsToCreate: 3,
    tickSize: TICK_SIZE,
    admissionTickSize: ADMISSION_TICK_SIZE,
    initialExpiryCash: 10_000n * DUSDC_DECIMALS,
    maxExpiryAllocation: 50_000n * DUSDC_DECIMALS,
  },
  {
    id: 2,
    name: "1h",
    periodMs: 60 * 60_000,
    windowSize: 3n,
    marketsToCreate: 3,
    tickSize: TICK_SIZE,
    admissionTickSize: ADMISSION_TICK_SIZE,
    initialExpiryCash: 50_000n * DUSDC_DECIMALS,
    maxExpiryAllocation: 250_000n * DUSDC_DECIMALS,
  },
] as const;

interface DeploymentJson {
  network: string;
  deployer: string;
  packages: Record<string, string>;
  linked: Record<string, string>;
  sharedObjects: Record<string, Record<string, string>>;
  ownedCaps: Record<string, Record<string, string>>;
  wiring?: WiringState;
}

interface WiringState {
  version: number;
  network: "testnet";
  operator: string;
  updatedAt: string;
  lifecycleCap?: {
    id: string;
    recipient: string;
    owner: "deployer" | "recipient";
    mintTx?: string;
    transferTx?: string;
  };
  account?: {
    predictAppAuthorized?: boolean;
    authorizeTx?: string;
    accountWrapperId?: string;
    createAccountTx?: string;
  };
  asset?: {
    name: string;
    propbookUnderlyingId: number;
    pythLazerFeedId: number;
    blockScholesSourceId: number;
    pythFeedId?: string;
    blockScholesSpotFeedId?: string;
    blockScholesForwardFeedId?: string;
    blockScholesSviFeedId?: string;
    globalFeedsCreatedTx?: string;
    globalFeedsBoundTx?: string;
    surfaceFeedsCreatedTx?: string;
    surfaceFeedsBoundTx?: string;
  };
  cadences?: Array<{
    id: number;
    name: string;
    tickSize: string;
    admissionTickSize: string;
    maxExpiryAllocation: string;
    initialExpiryCash: string;
    windowSize: string;
    setTx?: string;
  }>;
  bootstrap?: {
    lockCapitalAmount: string;
    supplyAmount: string;
    lockCapitalTx?: string;
    supplyRequestTx?: string;
    flushTx?: string;
  };
}

interface Receipt {
  digest: string;
  events: any[];
  objectChanges: any[];
  effects: any;
}

const client = getClient(NETWORK);
const signer = getSigner();
const sender = signer.getPublicKey().toSuiAddress();

function activeEnv(): string {
  return execSync(`${SUI} client active-env`, { encoding: "utf8" }).trim();
}

function readDeployment(): DeploymentJson {
  const deployment = JSON.parse(
    readFileSync(DEPLOYMENT_JSON, "utf8"),
  ) as DeploymentJson;
  deployment.wiring ??= {
    version: 1,
    network: NETWORK,
    operator: sender,
    updatedAt: new Date().toISOString(),
  };
  deployment.wiring.version = 1;
  deployment.wiring.network = NETWORK;
  deployment.wiring.operator = sender;
  deployment.wiring.updatedAt = new Date().toISOString();
  return deployment;
}

function writeDeployment(deployment: DeploymentJson): void {
  deployment.wiring ??= {
    version: 1,
    network: NETWORK,
    operator: sender,
    updatedAt: new Date().toISOString(),
  };
  deployment.wiring.updatedAt = new Date().toISOString();
  writeFileSync(DEPLOYMENT_JSON, `${JSON.stringify(deployment, null, 2)}\n`);
}

function predictPackage(deployment: DeploymentJson): string {
  return deployment.packages.predict;
}

function propbookPackage(deployment: DeploymentJson): string {
  return deployment.packages.propbook;
}

function accountPackage(deployment: DeploymentJson): string {
  return deployment.packages.account;
}

function dusdcType(deployment: DeploymentJson): string {
  return `${deployment.linked.dusdc}::dusdc::DUSDC`;
}

function predictTarget(
  deployment: DeploymentJson,
  module: string,
  fn: string,
): string {
  return `${predictPackage(deployment)}::${module}::${fn}`;
}

function propbookTarget(
  deployment: DeploymentJson,
  module: string,
  fn: string,
): string {
  return `${propbookPackage(deployment)}::${module}::${fn}`;
}

function accountTarget(
  deployment: DeploymentJson,
  module: string,
  fn: string,
): string {
  return `${accountPackage(deployment)}::${module}::${fn}`;
}

function registryId(deployment: DeploymentJson): string {
  return deployment.sharedObjects.predict["registry::Registry"];
}

function protocolConfigId(deployment: DeploymentJson): string {
  return deployment.sharedObjects.predict["protocol_config::ProtocolConfig"];
}

function poolVaultId(deployment: DeploymentJson): string {
  return deployment.sharedObjects.predict["plp::PoolVault"];
}

function oracleRegistryId(deployment: DeploymentJson): string {
  return deployment.sharedObjects.propbook["registry::OracleRegistry"];
}

function accountRegistryId(deployment: DeploymentJson): string {
  return deployment.sharedObjects.account["account_registry::AccountRegistry"];
}

function adminCapId(deployment: DeploymentJson): string {
  return deployment.ownedCaps.predict["admin::AdminCap"];
}

function oracleRegistryAdminCapId(deployment: DeploymentJson): string {
  return deployment.ownedCaps.propbook["registry::RegistryAdminCap"];
}

function accountAdminCapId(deployment: DeploymentJson): string {
  return deployment.ownedCaps.account["account_registry::AccountAdminCap"];
}

function predictAppType(deployment: DeploymentJson): string {
  return `${predictPackage(deployment)}::predict_account::PredictApp`;
}

function isSuccessStatus(status: any): boolean {
  return status?.status === "success" || status?.success === true;
}

function statusError(status: any, fallback: string): string {
  return status?.error ?? fallback;
}

async function getTransactionBlockWithRetry(digest: string): Promise<any> {
  let lastError: unknown;
  for (let attempt = 0; attempt < 20; attempt++) {
    try {
      return await client.getTransactionBlock({
        digest,
        options: {
          showEffects: true,
          showEvents: true,
          showObjectChanges: true,
        },
      });
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }
  throw lastError;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function execute(label: string, tx: Transaction): Promise<Receipt> {
  tx.setSender(sender);
  tx.setGasBudget(GAS_BUDGET);

  let raw: any;
  try {
    raw = await client.signAndExecuteTransaction({
      transaction: tx,
      signer,
      options: { showEffects: true, showEvents: true, showObjectChanges: true },
    });
  } catch (error) {
    let dryRunSummary = "";
    try {
      const bytes = await tx.build({ client });
      const dryRun = await client.dryRunTransactionBlock({
        transactionBlock: bytes,
      });
      dryRunSummary = ` dryRun=${JSON.stringify(dryRun).slice(0, 1200)}`;
    } catch (dryRunError) {
      dryRunSummary = ` dryRun_error=${String(dryRunError)}`;
    }
    throw new Error(`${label} rpc failure: ${String(error)}${dryRunSummary}`);
  }

  const status = raw.effects?.status;
  if (!isSuccessStatus(status)) {
    throw new Error(
      `${label} failed: ${statusError(status, JSON.stringify(raw).slice(0, 500))}`,
    );
  }

  const settled = await getTransactionBlockWithRetry(raw.digest);
  console.log(`[wire] ${label}: ${raw.digest}`);
  return {
    digest: raw.digest,
    events: settled.events ?? raw.events ?? [],
    objectChanges: settled.objectChanges ?? raw.objectChanges ?? [],
    effects: settled.effects ?? raw.effects,
  };
}

function createdObjectId(receipt: Receipt, objectTypeIncludes: string): string {
  const change = receipt.objectChanges.find(
    (objectChange: any) =>
      objectChange.type === "created" &&
      typeof objectChange.objectType === "string" &&
      objectChange.objectType.includes(objectTypeIncludes),
  );
  if (!change?.objectId) {
    throw new Error(
      `missing created object containing type ${objectTypeIncludes}`,
    );
  }
  return change.objectId;
}

function eventByName(receipt: Receipt, name: string): any | undefined {
  return receipt.events.find((event: any) => event.type?.endsWith(`::${name}`));
}

async function devInspectReturn(
  tx: Transaction,
  label: string,
): Promise<number[] | undefined> {
  const res: any = await client.devInspectTransactionBlock({
    sender,
    transactionBlock: tx,
  });
  if (res.error) {
    throw new Error(`${label} devInspect failed: ${res.error}`);
  }
  return res.results?.[0]?.returnValues?.[0]?.[0];
}

function parseOptionId(bytes: number[] | undefined): string | null {
  if (!bytes || bytes.length === 0 || bytes[0] === 0) return null;
  if (bytes[0] !== 1 || bytes.length < 33) return null;
  return `0x${bytes
    .slice(1, 33)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("")}`;
}

function parseAddress(bytes: number[] | undefined): string {
  if (!bytes || bytes.length < 32) {
    throw new Error("missing address return value");
  }
  return `0x${bytes
    .slice(0, 32)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("")}`;
}

function parseBool(bytes: number[] | undefined): boolean {
  return bytes?.[0] === 1;
}

function parseU64(bytes: number[] | undefined): bigint {
  if (!bytes || bytes.length < 8) return 0n;
  let value = 0n;
  for (let i = 7; i >= 0; i--) {
    value = (value << 8n) + BigInt(bytes[i]);
  }
  return value;
}

async function inspectBool(
  label: string,
  build: (tx: Transaction) => void,
): Promise<boolean> {
  const tx = new Transaction();
  build(tx);
  return parseBool(await devInspectReturn(tx, label));
}

async function inspectU64(
  label: string,
  build: (tx: Transaction) => void,
): Promise<bigint> {
  const tx = new Transaction();
  build(tx);
  return parseU64(await devInspectReturn(tx, label));
}

async function currentClockMs(): Promise<number> {
  return Number(
    await inspectU64("clock_timestamp_ms", (tx) => {
      tx.moveCall({
        target: "0x2::clock::timestamp_ms",
        arguments: [tx.object(CLOCK_ID)],
      });
    }),
  );
}

async function waitForCadenceLead(
  cadence: (typeof CADENCES)[number],
): Promise<void> {
  const nowMs = await currentClockMs();
  const nextExpiryMs =
    (Math.floor(nowMs / cadence.periodMs) + 1) * cadence.periodMs;
  const leadMs = nextExpiryMs - nowMs;
  if (leadMs >= MIN_MARKET_LEAD_MS) return;

  const waitMs = leadMs + 2_000;
  console.log(
    `[wire] ${cadence.name} next slot is only ${leadMs}ms away; waiting ${waitMs}ms before creating market`,
  );
  await sleep(waitMs);
}

async function inspectOptionId(
  label: string,
  build: (tx: Transaction) => void,
): Promise<string | null> {
  const tx = new Transaction();
  build(tx);
  return parseOptionId(await devInspectReturn(tx, label));
}

async function inspectAddress(
  label: string,
  build: (tx: Transaction) => void,
): Promise<string> {
  const tx = new Transaction();
  build(tx);
  return parseAddress(await devInspectReturn(tx, label));
}

async function ensurePredictAppAuthorized(
  deployment: DeploymentJson,
): Promise<void> {
  const authorized = await inspectBool("is_app_authorized", (tx) => {
    tx.moveCall({
      target: accountTarget(
        deployment,
        "account_registry",
        "is_app_authorized",
      ),
      typeArguments: [predictAppType(deployment)],
      arguments: [tx.object(accountRegistryId(deployment))],
    });
  });
  if (authorized) {
    deployment.wiring!.account ??= {};
    deployment.wiring!.account.predictAppAuthorized = true;
    writeDeployment(deployment);
    console.log("[wire] Predict app already authorized in account registry");
    return;
  }

  const tx = new Transaction();
  tx.moveCall({
    target: accountTarget(deployment, "account_registry", "authorize_app"),
    typeArguments: [predictAppType(deployment)],
    arguments: [
      tx.object(accountRegistryId(deployment)),
      tx.object(accountAdminCapId(deployment)),
    ],
  });
  const receipt = await execute("authorize_predict_app", tx);
  deployment.wiring!.account ??= {};
  deployment.wiring!.account.predictAppAuthorized = true;
  deployment.wiring!.account.authorizeTx = receipt.digest;
  writeDeployment(deployment);
}

async function ensureLifecycleCap(deployment: DeploymentJson): Promise<string> {
  if (deployment.wiring?.lifecycleCap?.id) {
    console.log(
      `[wire] Lifecycle cap already recorded: ${deployment.wiring.lifecycleCap.id}`,
    );
    return deployment.wiring.lifecycleCap.id;
  }

  const tx = new Transaction();
  const cap = tx.moveCall({
    target: predictTarget(deployment, "registry", "mint_lifecycle_cap"),
    arguments: [
      tx.object(registryId(deployment)),
      tx.object(protocolConfigId(deployment)),
      tx.object(adminCapId(deployment)),
    ],
  });
  tx.transferObjects([cap], tx.pure.address(sender));
  const receipt = await execute("mint_lifecycle_cap_to_deployer", tx);
  const capId = createdObjectId(
    receipt,
    "market_lifecycle_cap::MarketLifecycleCap",
  );

  deployment.wiring!.lifecycleCap = {
    id: capId,
    recipient: LIFECYCLE_CAP_RECIPIENT,
    owner: "deployer",
    mintTx: receipt.digest,
  };
  writeDeployment(deployment);
  return capId;
}

async function ensureGlobalFeeds(deployment: DeploymentJson): Promise<{
  pythFeedId: string;
  blockScholesSpotFeedId: string;
}> {
  deployment.wiring!.asset ??= {
    name: ASSET.name,
    propbookUnderlyingId: ASSET.propbookUnderlyingId,
    pythLazerFeedId: ASSET.pythLazerFeedId,
    blockScholesSourceId: ASSET.blockScholesSourceId,
  };

  let pythFeedId =
    deployment.wiring!.asset.pythFeedId ??
    (await inspectOptionId("propbook_pyth_id_for_source", (tx) => {
      tx.moveCall({
        target: propbookTarget(
          deployment,
          "registry",
          "propbook_pyth_id_for_source",
        ),
        arguments: [
          tx.object(oracleRegistryId(deployment)),
          tx.pure.u32(ASSET.pythLazerFeedId),
        ],
      });
    }));

  let blockScholesSpotFeedId =
    deployment.wiring!.asset.blockScholesSpotFeedId ??
    (await inspectOptionId(
      "propbook_block_scholes_spot_id_for_source",
      (tx) => {
        tx.moveCall({
          target: propbookTarget(
            deployment,
            "registry",
            "propbook_block_scholes_spot_id_for_source",
          ),
          arguments: [
            tx.object(oracleRegistryId(deployment)),
            tx.pure.u32(ASSET.blockScholesSourceId),
          ],
        });
      },
    ));

  if (!pythFeedId || !blockScholesSpotFeedId) {
    const tx = new Transaction();
    if (!pythFeedId) {
      tx.moveCall({
        target: propbookTarget(
          deployment,
          "registry",
          "create_and_share_pyth_feed",
        ),
        arguments: [
          tx.object(oracleRegistryId(deployment)),
          tx.pure.u32(ASSET.pythLazerFeedId),
        ],
      });
    }
    if (!blockScholesSpotFeedId) {
      tx.moveCall({
        target: propbookTarget(
          deployment,
          "registry",
          "create_and_share_block_scholes_spot_feed",
        ),
        arguments: [
          tx.object(oracleRegistryId(deployment)),
          tx.pure.u32(ASSET.blockScholesSourceId),
        ],
      });
    }
    const receipt = await execute("create_global_propbook_feeds", tx);
    if (!pythFeedId)
      pythFeedId = createdObjectId(receipt, "pyth_feed::PythFeed");
    if (!blockScholesSpotFeedId) {
      blockScholesSpotFeedId = createdObjectId(
        receipt,
        "block_scholes_spot_feed::BlockScholesSpotFeed",
      );
    }
    deployment.wiring!.asset.globalFeedsCreatedTx = receipt.digest;
  }

  deployment.wiring!.asset.pythFeedId = pythFeedId;
  deployment.wiring!.asset.blockScholesSpotFeedId = blockScholesSpotFeedId;
  writeDeployment(deployment);

  const pythBound = await inspectOptionId(
    "propbook_pyth_id_for_underlying",
    (tx) => {
      tx.moveCall({
        target: propbookTarget(
          deployment,
          "registry",
          "propbook_pyth_id_for_underlying",
        ),
        arguments: [
          tx.object(oracleRegistryId(deployment)),
          tx.pure.u32(ASSET.propbookUnderlyingId),
        ],
      });
    },
  );
  const spotBound = await inspectOptionId(
    "propbook_bs_spot_id_for_underlying",
    (tx) => {
      tx.moveCall({
        target: propbookTarget(
          deployment,
          "registry",
          "propbook_block_scholes_spot_id_for_underlying",
        ),
        arguments: [
          tx.object(oracleRegistryId(deployment)),
          tx.pure.u32(ASSET.propbookUnderlyingId),
        ],
      });
    },
  );

  if (pythBound === pythFeedId && spotBound === blockScholesSpotFeedId) {
    console.log("[wire] Global Propbook feeds already bound to underlying");
    return { pythFeedId, blockScholesSpotFeedId };
  }

  const tx = new Transaction();
  if (pythBound !== pythFeedId) {
    tx.moveCall({
      target: propbookTarget(deployment, "registry", "bind_pyth_to_underlying"),
      arguments: [
        tx.object(oracleRegistryId(deployment)),
        tx.object(oracleRegistryAdminCapId(deployment)),
        tx.object(pythFeedId),
        tx.pure.u32(ASSET.propbookUnderlyingId),
      ],
    });
  }
  if (spotBound !== blockScholesSpotFeedId) {
    tx.moveCall({
      target: propbookTarget(
        deployment,
        "registry",
        "bind_block_scholes_spot_to_underlying",
      ),
      arguments: [
        tx.object(oracleRegistryId(deployment)),
        tx.object(oracleRegistryAdminCapId(deployment)),
        tx.object(blockScholesSpotFeedId),
        tx.pure.u32(ASSET.propbookUnderlyingId),
      ],
    });
  }
  const receipt = await execute("bind_global_propbook_feeds", tx);
  deployment.wiring!.asset.globalFeedsBoundTx = receipt.digest;
  writeDeployment(deployment);

  return { pythFeedId, blockScholesSpotFeedId };
}

async function ensureBlockScholesSurfaceFeeds(
  deployment: DeploymentJson,
): Promise<{
  blockScholesForwardFeedId: string;
  blockScholesSviFeedId: string;
}> {
  deployment.wiring!.asset ??= {
    name: ASSET.name,
    propbookUnderlyingId: ASSET.propbookUnderlyingId,
    pythLazerFeedId: ASSET.pythLazerFeedId,
    blockScholesSourceId: ASSET.blockScholesSourceId,
  };

  let blockScholesForwardFeedId =
    deployment.wiring!.asset.blockScholesForwardFeedId ??
    (await inspectOptionId(
      "propbook_block_scholes_forward_id_for_source",
      (tx) => {
        tx.moveCall({
          target: propbookTarget(
            deployment,
            "registry",
            "propbook_block_scholes_forward_id_for_source",
          ),
          arguments: [
            tx.object(oracleRegistryId(deployment)),
            tx.pure.u32(ASSET.blockScholesSourceId),
          ],
        });
      },
    ));

  let blockScholesSviFeedId =
    deployment.wiring!.asset.blockScholesSviFeedId ??
    (await inspectOptionId("propbook_block_scholes_svi_id_for_source", (tx) => {
      tx.moveCall({
        target: propbookTarget(
          deployment,
          "registry",
          "propbook_block_scholes_svi_id_for_source",
        ),
        arguments: [
          tx.object(oracleRegistryId(deployment)),
          tx.pure.u32(ASSET.blockScholesSourceId),
        ],
      });
    }));

  if (!blockScholesForwardFeedId || !blockScholesSviFeedId) {
    const tx = new Transaction();
    if (!blockScholesForwardFeedId) {
      tx.moveCall({
        target: propbookTarget(
          deployment,
          "registry",
          "create_and_share_block_scholes_forward_feed",
        ),
        arguments: [
          tx.object(oracleRegistryId(deployment)),
          tx.pure.u32(ASSET.blockScholesSourceId),
        ],
      });
    }
    if (!blockScholesSviFeedId) {
      tx.moveCall({
        target: propbookTarget(
          deployment,
          "registry",
          "create_and_share_block_scholes_svi_feed",
        ),
        arguments: [
          tx.object(oracleRegistryId(deployment)),
          tx.pure.u32(ASSET.blockScholesSourceId),
        ],
      });
    }
    const receipt = await execute("create_bs_surface_feeds", tx);
    if (!blockScholesForwardFeedId) {
      blockScholesForwardFeedId = createdObjectId(
        receipt,
        "block_scholes_forward_feed::BlockScholesForwardFeed",
      );
    }
    if (!blockScholesSviFeedId) {
      blockScholesSviFeedId = createdObjectId(
        receipt,
        "block_scholes_svi_feed::BlockScholesSVIFeed",
      );
    }
    deployment.wiring!.asset.surfaceFeedsCreatedTx = receipt.digest;
  }

  deployment.wiring!.asset.blockScholesForwardFeedId =
    blockScholesForwardFeedId;
  deployment.wiring!.asset.blockScholesSviFeedId = blockScholesSviFeedId;
  writeDeployment(deployment);

  const boundForward = await inspectOptionId(
    "propbook_block_scholes_forward_id_for_underlying",
    (tx) => {
      tx.moveCall({
        target: propbookTarget(
          deployment,
          "registry",
          "propbook_block_scholes_forward_id_for_underlying",
        ),
        arguments: [
          tx.object(oracleRegistryId(deployment)),
          tx.pure.u32(ASSET.propbookUnderlyingId),
        ],
      });
    },
  );
  const boundSvi = await inspectOptionId(
    "propbook_block_scholes_svi_id_for_underlying",
    (tx) => {
      tx.moveCall({
        target: propbookTarget(
          deployment,
          "registry",
          "propbook_block_scholes_svi_id_for_underlying",
        ),
        arguments: [
          tx.object(oracleRegistryId(deployment)),
          tx.pure.u32(ASSET.propbookUnderlyingId),
        ],
      });
    },
  );

  if (
    boundForward === blockScholesForwardFeedId &&
    boundSvi === blockScholesSviFeedId
  ) {
    console.log(
      "[wire] Block Scholes surface feeds already bound to underlying",
    );
    return { blockScholesForwardFeedId, blockScholesSviFeedId };
  }
  if (boundForward || boundSvi) {
    throw new Error(
      `Block Scholes surface binding mismatch: forward=${boundForward} svi=${boundSvi}`,
    );
  }

  const tx = new Transaction();
  tx.moveCall({
    target: propbookTarget(
      deployment,
      "registry",
      "bind_block_scholes_surface_to_underlying",
    ),
    arguments: [
      tx.object(oracleRegistryId(deployment)),
      tx.object(oracleRegistryAdminCapId(deployment)),
      tx.object(blockScholesForwardFeedId),
      tx.object(blockScholesSviFeedId),
      tx.pure.u32(ASSET.propbookUnderlyingId),
    ],
  });
  const receipt = await execute("bind_bs_surface_feeds", tx);
  deployment.wiring!.asset.surfaceFeedsBoundTx = receipt.digest;
  writeDeployment(deployment);

  return { blockScholesForwardFeedId, blockScholesSviFeedId };
}

async function registerUnderlying(deployment: DeploymentJson): Promise<void> {
  // The underlying registration has no public getter; this flag means this script
  // got through the one-time registration step during the current deployment wiring.
  if ((deployment.wiring?.asset as any)?.predictUnderlyingRegistered) {
    console.log("[wire] Predict underlying already recorded as registered");
    return;
  }

  const tx = new Transaction();
  tx.moveCall({
    target: predictTarget(deployment, "registry", "register_underlying"),
    arguments: [
      tx.object(registryId(deployment)),
      tx.object(protocolConfigId(deployment)),
      tx.object(adminCapId(deployment)),
      tx.pure.u32(ASSET.propbookUnderlyingId),
    ],
  });
  const receipt = await execute("register_predict_underlying", tx);
  (deployment.wiring!.asset as any).predictUnderlyingRegistered = true;
  (deployment.wiring!.asset as any).predictUnderlyingRegisteredTx =
    receipt.digest;
  writeDeployment(deployment);
}

async function configureCadences(deployment: DeploymentJson): Promise<void> {
  const tx = new Transaction();
  for (const cadence of CADENCES) {
    tx.moveCall({
      target: predictTarget(deployment, "registry", "set_cadence_config"),
      arguments: [
        tx.object(registryId(deployment)),
        tx.object(protocolConfigId(deployment)),
        tx.object(adminCapId(deployment)),
        tx.pure.u8(cadence.id),
        tx.pure.u64(cadence.tickSize),
        tx.pure.u64(cadence.admissionTickSize),
        tx.pure.u64(cadence.maxExpiryAllocation),
        tx.pure.u64(cadence.initialExpiryCash),
        tx.pure.u64(cadence.windowSize),
      ],
    });
  }
  const receipt = await execute("set_cadence_configs", tx);
  deployment.wiring!.cadences = CADENCES.map((cadence) => ({
    id: cadence.id,
    name: cadence.name,
    tickSize: cadence.tickSize.toString(),
    admissionTickSize: cadence.admissionTickSize.toString(),
    maxExpiryAllocation: cadence.maxExpiryAllocation.toString(),
    initialExpiryCash: cadence.initialExpiryCash.toString(),
    windowSize: cadence.windowSize.toString(),
    setTx: receipt.digest,
  }));
  writeDeployment(deployment);
}

async function ensureAccountWrapper(
  deployment: DeploymentJson,
): Promise<string> {
  if (deployment.wiring?.account?.accountWrapperId) {
    console.log(
      `[wire] Account wrapper already recorded: ${deployment.wiring.account.accountWrapperId}`,
    );
    return deployment.wiring.account.accountWrapperId;
  }

  const exists = await inspectBool("derived_wrapper_exists", (tx) => {
    tx.moveCall({
      target: accountTarget(
        deployment,
        "account_registry",
        "derived_wrapper_exists",
      ),
      arguments: [
        tx.object(accountRegistryId(deployment)),
        tx.pure.address(sender),
      ],
    });
  });
  if (exists) {
    const accountWrapperId = await inspectAddress(
      "derived_wrapper_address",
      (tx) => {
        tx.moveCall({
          target: accountTarget(
            deployment,
            "account_registry",
            "derived_wrapper_address",
          ),
          arguments: [
            tx.object(accountRegistryId(deployment)),
            tx.pure.address(sender),
          ],
        });
      },
    );
    deployment.wiring!.account ??= {};
    deployment.wiring!.account.accountWrapperId = accountWrapperId;
    writeDeployment(deployment);
    console.log(`[wire] Reusing existing account wrapper: ${accountWrapperId}`);
    return accountWrapperId;
  }

  const tx = new Transaction();
  const wrapper = tx.moveCall({
    target: accountTarget(deployment, "account_registry", "new"),
    arguments: [tx.object(accountRegistryId(deployment))],
  });
  tx.moveCall({
    target: accountTarget(deployment, "account", "share"),
    arguments: [wrapper],
  });
  const receipt = await execute("create_deployer_account", tx);
  const accountWrapperId = createdObjectId(receipt, "account::AccountWrapper");

  deployment.wiring!.account ??= {};
  deployment.wiring!.account.accountWrapperId = accountWrapperId;
  deployment.wiring!.account.createAccountTx = receipt.digest;
  writeDeployment(deployment);
  return accountWrapperId;
}

function auth(deployment: DeploymentJson, tx: Transaction) {
  return tx.moveCall({
    target: accountTarget(deployment, "account", "generate_auth"),
    arguments: [],
  });
}

async function ensureBootstrap(
  deployment: DeploymentJson,
  lifecycleCapId: string,
  accountWrapperId: string,
): Promise<void> {
  deployment.wiring!.bootstrap ??= {
    lockCapitalAmount: LOCK_CAPITAL_AMOUNT.toString(),
    supplyAmount: BOOTSTRAP_SUPPLY_AMOUNT.toString(),
  };

  const totalSupply = await inspectU64("plp_total_supply", (tx) => {
    tx.moveCall({
      target: predictTarget(deployment, "plp", "plp_total_supply"),
      arguments: [tx.object(poolVaultId(deployment))],
    });
  });

  if (totalSupply === 0n) {
    const balance = await client.getBalance({
      owner: sender,
      coinType: dusdcType(deployment),
    });
    if (
      BigInt(balance.totalBalance) <
      LOCK_CAPITAL_AMOUNT + BOOTSTRAP_SUPPLY_AMOUNT
    ) {
      throw new Error(
        `insufficient deployer DUSDC: have ${balance.totalBalance}, need ${
          LOCK_CAPITAL_AMOUNT + BOOTSTRAP_SUPPLY_AMOUNT
        }`,
      );
    }

    const tx = new Transaction();
    const payment = coinWithBalance({
      type: dusdcType(deployment),
      balance: LOCK_CAPITAL_AMOUNT,
      useGasCoin: false,
    })(tx);
    tx.moveCall({
      target: predictTarget(deployment, "plp", "lock_capital"),
      arguments: [
        tx.object(poolVaultId(deployment)),
        tx.object(protocolConfigId(deployment)),
        tx.object(adminCapId(deployment)),
        payment,
      ],
    });
    const receipt = await execute("lock_bootstrap_capital", tx);
    deployment.wiring!.bootstrap.lockCapitalTx = receipt.digest;
    writeDeployment(deployment);
  } else {
    console.log(
      `[wire] Pool already bootstrapped with total supply ${totalSupply}`,
    );
  }

  const refreshedSupply = await inspectU64(
    "plp_total_supply_after_lock",
    (tx) => {
      tx.moveCall({
        target: predictTarget(deployment, "plp", "plp_total_supply"),
        arguments: [tx.object(poolVaultId(deployment))],
      });
    },
  );
  const pendingSupply = await inspectU64("supply_requests_pending", (tx) => {
    tx.moveCall({
      target: predictTarget(deployment, "plp", "supply_requests_pending"),
      arguments: [tx.object(poolVaultId(deployment))],
    });
  });

  if (refreshedSupply <= LOCK_CAPITAL_AMOUNT && pendingSupply === 0n) {
    const tx = new Transaction();
    const payment = coinWithBalance({
      type: dusdcType(deployment),
      balance: BOOTSTRAP_SUPPLY_AMOUNT,
      useGasCoin: false,
    })(tx);
    const depositAuth = auth(deployment, tx);
    tx.moveCall({
      target: accountTarget(deployment, "account", "deposit_funds"),
      typeArguments: [dusdcType(deployment)],
      arguments: [
        tx.object(accountWrapperId),
        depositAuth,
        payment,
        tx.object(ACCUMULATOR_ROOT_ID),
        tx.object(CLOCK_ID),
      ],
    });
    const supplyAuth = auth(deployment, tx);
    tx.moveCall({
      target: predictTarget(deployment, "plp", "request_supply"),
      arguments: [
        tx.object(poolVaultId(deployment)),
        tx.object(accountWrapperId),
        supplyAuth,
        tx.object(protocolConfigId(deployment)),
        tx.pure.u64(BOOTSTRAP_SUPPLY_AMOUNT),
        tx.object(ACCUMULATOR_ROOT_ID),
        tx.object(CLOCK_ID),
      ],
    });
    const receipt = await execute("request_bootstrap_supply", tx);
    deployment.wiring!.bootstrap.supplyRequestTx = receipt.digest;
    writeDeployment(deployment);
  } else {
    console.log(
      `[wire] Bootstrap supply already queued or filled (totalSupply=${refreshedSupply}, pendingSupply=${pendingSupply})`,
    );
  }

  const pendingAfterRequest = await inspectU64(
    "supply_requests_pending_after_request",
    (tx) => {
      tx.moveCall({
        target: predictTarget(deployment, "plp", "supply_requests_pending"),
        arguments: [tx.object(poolVaultId(deployment))],
      });
    },
  );
  if (pendingAfterRequest > 0n) {
    const tx = new Transaction();
    const proof = tx.moveCall({
      target: predictTarget(deployment, "registry", "generate_lifecycle_proof"),
      arguments: [tx.object(registryId(deployment)), tx.object(lifecycleCapId)],
    });
    const valuation = tx.moveCall({
      target: predictTarget(deployment, "plp", "start_pool_valuation"),
      arguments: [
        tx.object(protocolConfigId(deployment)),
        tx.object(poolVaultId(deployment)),
        proof,
      ],
    });
    tx.moveCall({
      target: predictTarget(deployment, "plp", "finish_flush"),
      arguments: [
        valuation,
        tx.object(poolVaultId(deployment)),
        tx.object(protocolConfigId(deployment)),
        tx.pure.option("u64", null),
        tx.pure.option("u64", null),
      ],
    });
    const receipt = await execute("flush_bootstrap_supply", tx);
    deployment.wiring!.bootstrap.flushTx = receipt.digest;
    writeDeployment(deployment);
  } else {
    console.log("[wire] No pending bootstrap supply to flush");
  }
}

async function createMarkets(
  deployment: DeploymentJson,
  lifecycleCapId: string,
  pythFeedId: string,
): Promise<void> {
  if (deployment.wiring?.lifecycleCap?.owner === "recipient") {
    console.log(
      "[wire] Lifecycle cap already transferred; skipping market creation",
    );
    return;
  }

  const createdCounts = new Map<number, number>();

  for (const cadence of CADENCES) {
    while ((createdCounts.get(cadence.id) ?? 0) < cadence.marketsToCreate) {
      await waitForCadenceLead(cadence);

      const tx = new Transaction();
      tx.moveCall({
        target: predictTarget(deployment, "registry", "create_expiry_market"),
        arguments: [
          tx.object(registryId(deployment)),
          tx.object(poolVaultId(deployment)),
          tx.object(protocolConfigId(deployment)),
          tx.object(oracleRegistryId(deployment)),
          tx.object(lifecycleCapId),
          tx.pure.u32(ASSET.propbookUnderlyingId),
          tx.pure.u8(cadence.id),
          tx.object(CLOCK_ID),
        ],
      });
      let receipt: Receipt;
      try {
        receipt = await execute(`create_${cadence.name}_market`, tx);
      } catch (error) {
        const message = String(error);
        if (
          message.includes("market_manager") &&
          message.includes("}, 5)")
        ) {
          console.log(
            `[wire] ${cadence.name} cadence window is full; stopping market creation for this cadence`,
          );
          break;
        }
        throw error;
      }
      const expiryMarketId = createdObjectId(
        receipt,
        "expiry_market::ExpiryMarket",
      );
      const marketCreated = eventByName(receipt, "MarketCreated");
      const expiryMs = Number(marketCreated?.parsedJson?.expiry);
      if (!expiryMs) {
        throw new Error(`MarketCreated expiry missing for ${expiryMarketId}`);
      }

      const rebalanceTx = new Transaction();
      rebalanceTx.moveCall({
        target: predictTarget(deployment, "plp", "rebalance_expiry_cash"),
        arguments: [
          rebalanceTx.object(poolVaultId(deployment)),
          rebalanceTx.object(expiryMarketId),
          rebalanceTx.object(protocolConfigId(deployment)),
          rebalanceTx.object(oracleRegistryId(deployment)),
          rebalanceTx.object(pythFeedId),
          rebalanceTx.object(CLOCK_ID),
        ],
      });
      const rebalanceReceipt = await execute(
        `rebalance_${cadence.name}_market_${expiryMs}`,
        rebalanceTx,
      );

      createdCounts.set(cadence.id, (createdCounts.get(cadence.id) ?? 0) + 1);
      console.log(
        `[wire] ${cadence.name} market ready: expiry=${new Date(
          expiryMs,
        ).toISOString()} market=${expiryMarketId} create=${receipt.digest} rebalance=${
          rebalanceReceipt.digest
        }`,
      );
    }
  }
}

async function transferLifecycleCap(
  deployment: DeploymentJson,
  lifecycleCapId: string,
): Promise<void> {
  if (deployment.wiring?.lifecycleCap?.owner === "recipient") {
    console.log(
      "[wire] Lifecycle cap already recorded as transferred to recipient",
    );
    return;
  }

  const tx = new Transaction();
  tx.transferObjects(
    [tx.object(lifecycleCapId)],
    tx.pure.address(LIFECYCLE_CAP_RECIPIENT),
  );
  const receipt = await execute("transfer_lifecycle_cap_to_operator", tx);
  deployment.wiring!.lifecycleCap = {
    ...(deployment.wiring!.lifecycleCap ?? {
      id: lifecycleCapId,
      recipient: LIFECYCLE_CAP_RECIPIENT,
    }),
    id: lifecycleCapId,
    recipient: LIFECYCLE_CAP_RECIPIENT,
    owner: "recipient",
    transferTx: receipt.digest,
  };
  writeDeployment(deployment);
}

async function main(): Promise<void> {
  if (activeEnv() !== NETWORK) {
    throw new Error(
      `active Sui env must be ${NETWORK}; current env is ${activeEnv()}`,
    );
  }

  const deployment = readDeployment();
  if (deployment.network !== NETWORK) {
    throw new Error(
      `${DEPLOYMENT_JSON} is for ${deployment.network}, expected ${NETWORK}`,
    );
  }
  if (deployment.deployer !== sender) {
    throw new Error(
      `active signer ${sender} does not match deployment deployer ${deployment.deployer}`,
    );
  }

  console.log(`[wire] sender=${sender}`);
  console.log(`[wire] deployment=${DEPLOYMENT_JSON}`);

  await ensurePredictAppAuthorized(deployment);
  const lifecycleCapId = await ensureLifecycleCap(deployment);
  const { pythFeedId } = await ensureGlobalFeeds(deployment);
  await ensureBlockScholesSurfaceFeeds(deployment);
  await registerUnderlying(deployment);
  await configureCadences(deployment);
  const accountWrapperId = await ensureAccountWrapper(deployment);
  await ensureBootstrap(deployment, lifecycleCapId, accountWrapperId);
  await createMarkets(deployment, lifecycleCapId, pythFeedId);
  await transferLifecycleCap(deployment, lifecycleCapId);

  console.log("[wire] Predict testnet wiring complete");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
