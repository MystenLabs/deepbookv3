#!/usr/bin/env -S npx tsx
/**
 * Testnet deploy for the `account` package.
 *
 * account is a leaf (only std/sui deps). On publish, `account_registry::init` shares the
 * `AccountRegistry` and transfers an `AccountAdminCap` to the deployer. This script:
 *   1. Publishes account.
 *   2. Records account_package_id + AccountRegistry (shared) + AccountAdminCap (owned).
 *   3. Writes packages/account/Published.toml so the predict publish LINKS this on-chain
 *      account package instead of republishing it.
 *
 * Idempotent: ids persist to deployment.testnet.json and the publish is short-circuited by the
 * committed Published.toml. Active env MUST be testnet.
 */
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

const SCRIPT_DIR = __dirname;
const ACCOUNT_DIR = path.resolve(SCRIPT_DIR, "..");
const STATE_JSON = path.join(SCRIPT_DIR, "deployment.testnet.json");
const PUBLISHED_TOML = path.join(ACCOUNT_DIR, "Published.toml");

const EXPECTED_ENV = "testnet";
const GAS_BUDGET = process.env.GAS_BUDGET ?? "500000000";
const SUI = process.env.SUI_BINARY ?? "sui";

type State = Record<string, any>;
const loadState = (): State => (fs.existsSync(STATE_JSON) ? JSON.parse(fs.readFileSync(STATE_JSON, "utf8")) : {});
const writeState = (s: State) => fs.writeFileSync(STATE_JSON, JSON.stringify(s, null, 2) + "\n");

function sui(args: string[], opts: { json?: boolean } = {}): any {
  const out = execFileSync(SUI, args, { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
  return opts.json ? JSON.parse(out) : out.trim();
}
function publishedPackageId(changes: any): string {
  const pub = (changes.objectChanges ?? []).filter((c: any) => c.type === "published");
  return pub.length ? pub[pub.length - 1].packageId : "";
}
function createdObjectId(changes: any, needle: string): string {
  for (const c of changes.objectChanges ?? []) {
    if (c.type === "created" && (c.objectType ?? "").includes(needle)) return c.objectId;
  }
  return "";
}
function require_(v: string, msg: string): string {
  if (!v) {
    console.error(`ERROR: ${msg}`);
    process.exit(1);
  }
  return v;
}
function publishedTomlId(): string {
  if (!fs.existsSync(PUBLISHED_TOML)) return "";
  const m = fs.readFileSync(PUBLISHED_TOML, "utf8").match(/\[published\.testnet\][\s\S]*?published-at\s*=\s*"(0x[0-9a-fA-F]+)"/);
  return m ? m[1] : "";
}
function writePublishedToml(pkgId: string): void {
  const chainId = sui(["client", "chain-identifier"]);
  fs.writeFileSync(
    PUBLISHED_TOML,
    `[published.testnet]\nchain-id = "${chainId}"\npublished-at = "${pkgId}"\noriginal-id = "${pkgId}"\nversion = 1\n`,
  );
}

function main(): void {
  const state = loadState();

  console.log("==> Preflight");
  const activeEnv = sui(["client", "active-env"]);
  const activeAddr = sui(["client", "active-address"]);
  if (activeEnv !== EXPECTED_ENV) {
    console.error(`ERROR: active env is '${activeEnv}', expected '${EXPECTED_ENV}'.`);
    process.exit(1);
  }
  console.log(`    env=${activeEnv}  deployer=${activeAddr}`);
  state.network = EXPECTED_ENV;
  state.deployer = activeAddr;
  writeState(state);

  console.log("==> Publish account");
  if (state.account_package_id && state.account_registry_shared_object_id && state.account_admin_cap_object_id) {
    console.log(`    [skip] account = ${state.account_package_id}`);
  } else {
    const existing = publishedTomlId();
    if (existing && !state.account_registry_shared_object_id) {
      console.error(`ERROR: account already published (${existing}) but registry ids are missing from ${STATE_JSON}.`);
      process.exit(1);
    }
    const out = sui(
      ["client", "publish", "--skip-dependency-verification", "--gas-budget", GAS_BUDGET, "--json", ACCOUNT_DIR],
      { json: true },
    );
    const pkg = require_(publishedPackageId(out), "account publish returned no packageId");
    const reg = require_(createdObjectId(out, "account_registry::AccountRegistry"), "AccountRegistry not created");
    const cap = require_(createdObjectId(out, "account_registry::AccountAdminCap"), "AccountAdminCap not created");
    state.account_package_id = pkg;
    state.account_registry_shared_object_id = reg;
    state.account_admin_cap_object_id = cap;
    writeState(state);
    writePublishedToml(pkg);
    console.log(`    [done] account = ${pkg}\n           AccountRegistry = ${reg}\n           AccountAdminCap = ${cap}`);
    console.log(`    wrote ${PUBLISHED_TOML} (so predict links this account package)`);
  }

  console.log("\n==> Account testnet deployment complete.");
  console.log(`    State: ${STATE_JSON}`);
  console.log(fs.readFileSync(STATE_JSON, "utf8"));
}

main();
