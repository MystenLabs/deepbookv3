// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/**
 * Full Predict **testnet package deployment** — packages only (no post-deploy
 * config / market / oracle setup yet).
 *
 * Publishes the in-repo package tree in dependency order via `sui client publish`.
 * Each publish writes that package's `Published.toml` (Move automated address
 * management), so the next package resolves its just-published dependency
 * automatically. (Publishing must be phased — `--with-unpublished-dependencies`
 * collides every unpublished dep at 0x0.)
 *
 * LINKED, not published (see packages/predict/Move.toml [dep-replacements.testnet]
 * and packages/dusdc/Published.toml):
 *   dusdc       0xe9504008…73e1a   existing testnet quote/collateral coin (reused as-is)
 *   DEEP/token  0x36dbef86…58a8    canonical testnet DEEP (reused as-is)
 *   pyth_lazer  0xf5bd2141…68c21
 *   wormhole    0xd5afd4e4…839f2
 *
 * Writes ./deployment.testnet.json: each published package -> id, the shared
 * objects + owned caps each package's `init` created, the linked dependency ids,
 * and the publish tx digests.
 *
 * Run (active sui env must be `testnet`, address funded):
 *   npx tsx deploy.ts
 *   GAS_BUDGET=8000000000 npx tsx deploy.ts
 *
 * Each run is a fresh clean deployment (new package ids) and overwrites
 * deployment.testnet.json.
 */
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..", "..", "..");
const OUT = resolve(HERE, "deployment.testnet.json");
const GAS_BUDGET = process.env.GAS_BUDGET ?? "5000000000";

/** In-repo packages to publish, in dependency order (leaves first, predict last). */
const PACKAGES = ["fixed_math", "block_scholes_oracle", "account", "propbook", "predict"] as const;

/** Depended-on but NOT published here (linked via dep-replacements / Published.toml). */
const LINKED = {
  dusdc: "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a",
  deep: "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8",
  pyth_lazer: "0xf5bd2141967507050a91b58de3d95e77c432cd90d1799ee46effc27430a68c21",
  wormhole: "0xd5afd4e456e5451f1ca1e7b3d734ce7a0a3b397811a6cb72a4bd1dfc387839f2",
} as const;

interface ObjectChange {
  type: string;
  packageId?: string;
  objectId?: string;
  objectType?: string;
  owner?: unknown;
}
interface PublishResult {
  digest?: string;
  effects?: { status?: { status?: string } };
  objectChanges?: ObjectChange[];
}

function sui(args: string[]): string {
  return execFileSync("sui", args, { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
}

/** `0xpkg::module::Type` -> `module::Type` (drop the package prefix). */
function shortType(t: string): string {
  const parts = t.split("::");
  return parts.length >= 3 ? parts.slice(1).join("::") : t;
}

function publish(pkg: string): PublishResult {
  const out = sui([
    "client",
    "publish",
    resolve(REPO_ROOT, "packages", pkg),
    "--skip-dependency-verification",
    "--gas-budget",
    GAS_BUDGET,
    "--json",
  ]);
  const res = JSON.parse(out) as PublishResult;
  const pid = res.objectChanges?.find((c) => c.type === "published")?.packageId;
  if (res.effects?.status?.status !== "success" || !pid) {
    throw new Error(`publish ${pkg} failed: ${JSON.stringify(res.effects?.status)}`);
  }
  return res;
}

function main(): void {
  const env = sui(["client", "active-env"]).trim();
  const deployer = sui(["client", "active-address"]).trim();
  if (env !== "testnet") {
    throw new Error(`active sui env is '${env}', expected 'testnet' — run: sui client switch --env testnet`);
  }
  console.log(`Deployer : ${deployer}`);
  console.log(`Env      : ${env}`);
  console.log(`Publish  : ${PACKAGES.join(", ")}`);
  console.log(`Linked   : dusdc, DEEP, pyth_lazer, wormhole (not published)\n`);

  const packages: Record<string, string> = {};
  const sharedObjects: Record<string, Record<string, string>> = {};
  const ownedCaps: Record<string, Record<string, string>> = {};
  const publishTx: Record<string, string | undefined> = {};

  for (const pkg of PACKAGES) {
    console.log(`==> publishing ${pkg} ...`);
    const res = publish(pkg);
    const changes = res.objectChanges ?? [];
    packages[pkg] = changes.find((c) => c.type === "published")!.packageId!;
    publishTx[pkg] = res.digest;

    const shared: Record<string, string> = {};
    const caps: Record<string, string> = {};
    for (const c of changes) {
      if (c.type !== "created" || !c.objectType || !c.objectId) continue;
      const owner = c.owner;
      const isShared = typeof owner === "object" && owner !== null && "Shared" in owner;
      const key = shortType(c.objectType);
      if (isShared) shared[key] = c.objectId;
      else if (c.objectType.includes("Cap")) caps[key] = c.objectId;
    }
    if (Object.keys(shared).length) sharedObjects[pkg] = shared;
    if (Object.keys(caps).length) ownedCaps[pkg] = caps;
    console.log(`    ${pkg} -> ${packages[pkg]}`);
  }

  const out = {
    network: "testnet",
    chainId: "4c78adac",
    deployer,
    packages,
    linked: LINKED,
    sharedObjects,
    ownedCaps,
    publishTx,
  };
  writeFileSync(OUT, JSON.stringify(out, null, 2) + "\n");
  console.log(`\nWrote ${OUT}`);
}

main();
