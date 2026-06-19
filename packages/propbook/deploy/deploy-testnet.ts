#!/usr/bin/env -S npx tsx
/**
 * End-to-end testnet deploy for Propbook + its Pyth and Block Scholes oracle lanes.
 *
 * Order:
 *   1. Publish fixed_math            (leaf)
 *   2. Publish block_scholes_oracle  (leaf, stub BS verifier)
 *   3. Publish propbook              (creates the shared OracleRegistry + RegistryAdminCap)
 *   4. create_and_share_pyth_feed              -> shared PythFeed
 *   5. create_and_share_block_scholes_feed     -> shared BlockScholesFeed
 *   6. bind_pyth_to_underlying + bind_block_scholes_to_underlying  (admin-gated)
 *   7. Read back + verify, then write deployment.testnet.json
 *
 * Create + bind only: NO observation writes (the live Pyth write path is out of scope here).
 *
 * Idempotent/resumable: every produced id is persisted to deployment.testnet.json and reused
 * on re-run; publishes are additionally short-circuited by each package's committed
 * Published.toml. Delete the json (and the relevant Published.toml) to force a clean redeploy.
 *
 * The deployer is whatever `sui client active-address` is; the active env MUST be testnet.
 * pyth_lazer + wormhole are linked on-chain via propbook's [dep-replacements.testnet]; this
 * toolchain (sui 1.73) ignores the manifest published-at for a direct dep, so we synthesize a
 * Published.toml in each dep's git-cache dir to make publish LINK the on-chain packages.
 */
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

// --- Paths ---
const SCRIPT_DIR = __dirname;
const PROPBOOK_DIR = path.resolve(SCRIPT_DIR, "..");
const PACKAGES_DIR = path.resolve(PROPBOOK_DIR, "..");
const FIXED_MATH_DIR = path.join(PACKAGES_DIR, "fixed_math");
const BS_ORACLE_DIR = path.join(PACKAGES_DIR, "block_scholes_oracle");
const STATE_JSON = path.join(SCRIPT_DIR, "deployment.testnet.json");

// --- Config (env-overridable) ---
const EXPECTED_ENV = "testnet";
const GAS_BUDGET = process.env.GAS_BUDGET ?? "500000000";
const PROPBOOK_UNDERLYING_ID = process.env.PROPBOOK_UNDERLYING_ID ?? "1"; // canonical "BTC" handle
const PYTH_SOURCE_ID = process.env.PYTH_SOURCE_ID ?? "1"; // Pyth Lazer feed id (1 = BTC/USD)
const BS_SOURCE_ID = process.env.BS_SOURCE_ID ?? "1"; // Block Scholes source id

// --- deployment.testnet.json layout (the file IS the state; grouped + ordered) ---
const TOP = ["network", "deployer"] as const;
const GROUPS: Record<string, string[]> = {
  packages: ["fixed_math_package_id", "propbook_package_id"],
  verifier_packages: [
    "block_scholes_verifier_package_id",
    "pyth_lazer_verifier_package_id",
    "wormhole_verifier_package_id",
  ],
  shared_objects: [
    "oracle_registry_shared_object_id",
    "pyth_feed_shared_object_id",
    "block_scholes_feed_shared_object_id",
    "pyth_lazer_state_shared_object_id",
    "wormhole_state_shared_object_id",
  ],
  capabilities: ["registry_admin_cap_object_id"],
  bindings: ["propbook_underlying_id", "pyth_source_id", "bs_source_id", "pyth_bound", "block_scholes_bound"],
};

type State = Record<string, any>;

function loadState(): State {
  return fs.existsSync(STATE_JSON) ? JSON.parse(fs.readFileSync(STATE_JSON, "utf8")) : {};
}
function get(state: State, key: string): string {
  if (key in state && typeof state[key] !== "object") return String(state[key]);
  for (const v of Object.values(state)) {
    if (v && typeof v === "object" && key in (v as object)) return String((v as any)[key]);
  }
  return "";
}
function set(state: State, key: string, raw: string | number): void {
  const val = typeof raw === "number" ? raw : /^-?\d+$/.test(raw) ? Number(raw) : raw;
  if ((TOP as readonly string[]).includes(key)) {
    state[key] = val;
  } else {
    const grp = Object.keys(GROUPS).find((g) => GROUPS[g].includes(key)) ?? "other";
    if (!state[grp] || typeof state[grp] !== "object") state[grp] = {};
    state[grp][key] = val;
  }
  writeState(state);
}
function writeState(state: State): void {
  const out: State = {};
  for (const k of TOP) if (k in state) out[k] = state[k];
  for (const [g, keys] of Object.entries(GROUPS)) {
    const sub = state[g];
    if (sub && typeof sub === "object" && Object.keys(sub).length) {
      out[g] = {};
      for (const k of keys) if (k in sub) out[g][k] = sub[k];
      for (const [k, v] of Object.entries(sub)) if (!(k in out[g])) out[g][k] = v;
    }
  }
  for (const [k, v] of Object.entries(state)) if (!(k in out) && !(TOP as readonly string[]).includes(k)) out[k] = v;
  fs.writeFileSync(STATE_JSON, JSON.stringify(out, null, 2) + "\n");
}

// --- sui helpers ---
const SUI = process.env.SUI_BINARY ?? "sui";
function sui(args: string[], opts: { json?: boolean } = {}): any {
  const out = execFileSync(SUI, args, { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
  return opts.json ? JSON.parse(out) : out.trim();
}
function publishedPackageId(changes: any): string {
  const pub = (changes.objectChanges ?? []).filter((c: any) => c.type === "published");
  return pub.length ? pub[pub.length - 1].packageId : "";
}
function createdObjectId(changes: any, ...needles: string[]): string {
  for (const c of changes.objectChanges ?? []) {
    const ot = c.objectType ?? "";
    if (c.type === "created" && needles.every((n) => ot.includes(n))) return c.objectId;
  }
  return "";
}
function publishedTomlId(dir: string): string {
  const toml = path.join(dir, "Published.toml");
  if (!fs.existsSync(toml)) return "";
  const t = fs.readFileSync(toml, "utf8");
  const m = t.match(/\[published\.testnet\]([\s\S]*?)(\n\[|$)/);
  if (!m) return "";
  const pa = m[1].match(/published-at\s*=\s*"(0x[0-9a-fA-F]+)"/);
  return pa ? pa[1] : "";
}
function require_(v: string, msg: string): string {
  if (!v) {
    console.error(`ERROR: ${msg}`);
    process.exit(1);
  }
  return v;
}

/**
 * Link propbook's already-on-chain git deps (pyth_lazer, wormhole). This toolchain resolves a
 * dependency's published address from a Published.toml inside the dep's resolved git-cache dir,
 * NOT from the manifest's published-at override. We synthesize that file from propbook's committed
 * [dep-replacements.testnet] (addresses) + Move.lock (pinned rev/subdir). Requires deps fetched
 * first (a build).
 */
function linkOnchainDeps(): void {
  const chainId = sui(["client", "chain-identifier"]);
  const T = fs.readFileSync(path.join(PROPBOOK_DIR, "Move.toml"), "utf8");
  const L = fs.readFileSync(path.join(PROPBOOK_DIR, "Move.lock"), "utf8");
  const blk = (T.match(/\[dep-replacements\.testnet\]([\s\S]*)$/) ?? [, ""])[1] as string;
  const gitCache = path.join(os.homedir(), ".move", "git");
  const wrote: string[] = [];
  for (const dm of blk.matchAll(/(\w+)\s*=\s*\{([^}]*)\}/g)) {
    const name = dm[1];
    const body = dm[2];
    const pa = body.match(/published-at\s*=\s*"(0x[0-9a-fA-F]+)"/);
    const oi = body.match(/original-id\s*=\s*"(0x[0-9a-fA-F]+)"/);
    if (!pa || !oi) continue;
    const pin = L.match(new RegExp(`\\[pinned\\.testnet\\.${name}\\]\\s*source = \\{([^}]*)\\}`));
    if (!pin) {
      console.log(`  [warn] ${name}: no pinned source in Move.lock`);
      continue;
    }
    const rev = pin[1].match(/rev = "([0-9a-fA-F]+)"/);
    const sub = pin[1].match(/subdir = "([^"]+)"/);
    if (!rev) {
      console.log(`  [warn] ${name}: no pinned rev`);
      continue;
    }
    const dir = fs.existsSync(gitCache)
      ? fs.readdirSync(gitCache).find((d) => d.includes(rev[1]))
      : undefined;
    const moveToml = dir ? path.join(gitCache, dir, sub ? sub[1] : "", "Move.toml") : "";
    if (!moveToml || !fs.existsSync(moveToml)) {
      console.log(`  [warn] ${name}: git cache not found (rev ${rev[1]}); run a build first`);
      continue;
    }
    fs.writeFileSync(
      path.join(path.dirname(moveToml), "Published.toml"),
      `[published.testnet]\nchain-id = "${chainId}"\npublished-at = "${pa[1]}"\noriginal-id = "${oi[1]}"\nversion = 1\n`,
    );
    wrote.push(name);
  }
  console.log(`    linked on-chain deps: ${wrote.length ? wrote.join(", ") : "(none)"}`);
}

function ensureLeaf(state: State, dir: string, key: string, label: string): void {
  if (get(state, key)) return console.log(`    [skip] ${label} = ${get(state, key)}`);
  const existing = publishedTomlId(dir);
  if (existing) {
    set(state, key, existing);
    return console.log(`    [reuse Published.toml] ${label} = ${existing}`);
  }
  console.log(`    publishing ${label} ...`);
  const out = sui(
    ["client", "publish", "--skip-dependency-verification", "--gas-budget", GAS_BUDGET, "--json", dir],
    { json: true },
  );
  const pid = require_(publishedPackageId(out), `${label} publish returned no packageId`);
  set(state, key, pid);
  console.log(`    [done] ${label} = ${pid}`);
}

function main(): void {
  const state = loadState();

  // === 0. Preflight ===
  console.log("==> Preflight");
  const activeEnv = sui(["client", "active-env"]);
  const activeAddr = sui(["client", "active-address"]);
  if (activeEnv !== EXPECTED_ENV) {
    console.error(`ERROR: active env is '${activeEnv}', expected '${EXPECTED_ENV}'.`);
    process.exit(1);
  }
  const gas = sui(["client", "gas", "--json"], { json: true });
  const gasTotal = gas.reduce((s: number, c: any) => s + Number(c.mistBalance ?? c.gasBalance ?? 0), 0);
  console.log(`    env=${activeEnv}  deployer=${activeAddr}  gas=${(gasTotal / 1e9).toFixed(2)} SUI`);
  if (gasTotal <= 0) {
    console.error("ERROR: deployer has no gas.");
    process.exit(1);
  }
  console.log(`    underlying=${PROPBOOK_UNDERLYING_ID}  pyth_source=${PYTH_SOURCE_ID}  bs_source=${BS_SOURCE_ID}`);
  set(state, "network", EXPECTED_ENV);
  set(state, "deployer", activeAddr);
  set(state, "propbook_underlying_id", PROPBOOK_UNDERLYING_ID);
  set(state, "pyth_source_id", PYTH_SOURCE_ID);
  set(state, "bs_source_id", BS_SOURCE_ID);

  // Resolve leaves + fetch on-chain pyth/wormhole into the git cache.
  console.log("==> Building propbook (resolves leaves + fetches deps)");
  try {
    sui(["move", "build", "--path", PROPBOOK_DIR]);
  } catch {
    console.log("    (build deferred until leaves are published)");
  }

  // === 1-2. Publish leaf packages ===
  console.log("==> Phase 1: fixed_math");
  ensureLeaf(state, FIXED_MATH_DIR, "fixed_math_package_id", "fixed_math");
  console.log("==> Phase 2: block_scholes_oracle (BS verifier stub)");
  ensureLeaf(state, BS_ORACLE_DIR, "block_scholes_verifier_package_id", "block_scholes_verifier");

  // === 3. Publish propbook ===
  console.log("==> Phase 3: propbook");
  if (get(state, "propbook_package_id") && get(state, "oracle_registry_shared_object_id") && get(state, "registry_admin_cap_object_id")) {
    console.log(`    [skip] propbook = ${get(state, "propbook_package_id")}`);
  } else {
    const existing = publishedTomlId(PROPBOOK_DIR);
    if (existing && !get(state, "oracle_registry_shared_object_id")) {
      console.error(`ERROR: propbook already published (${existing}) but registry ids are missing from ${STATE_JSON}.`);
      process.exit(1);
    }
    linkOnchainDeps();
    console.log("    publishing propbook ...");
    const out = sui(
      ["client", "publish", "--skip-dependency-verification", "--allow-dirty", "--gas-budget", GAS_BUDGET, "--json", PROPBOOK_DIR],
      { json: true },
    );
    const pkg = require_(publishedPackageId(out), "propbook publish returned no packageId");
    const reg = require_(createdObjectId(out, "registry::OracleRegistry"), "OracleRegistry not created");
    const cap = require_(createdObjectId(out, "registry::RegistryAdminCap"), "RegistryAdminCap not created");
    set(state, "propbook_package_id", pkg);
    set(state, "oracle_registry_shared_object_id", reg);
    set(state, "registry_admin_cap_object_id", cap);
    console.log(`    [done] propbook = ${pkg}\n           OracleRegistry = ${reg}\n           RegistryAdminCap = ${cap}`);
  }
  const PKG = get(state, "propbook_package_id");
  const REG = get(state, "oracle_registry_shared_object_id");
  const CAP = get(state, "registry_admin_cap_object_id");

  // === 4. Create + share feeds (permissionless) ===
  console.log("==> Phase 4: create + share feeds");
  if (get(state, "pyth_feed_shared_object_id")) {
    console.log(`    [skip] PythFeed = ${get(state, "pyth_feed_shared_object_id")}`);
  } else {
    const out = sui(
      ["client", "call", "--package", PKG, "--module", "registry", "--function", "create_and_share_pyth_feed",
        "--args", REG, PYTH_SOURCE_ID, "--gas-budget", GAS_BUDGET, "--json"], { json: true });
    const fid = require_(createdObjectId(out, "pyth_feed::PythFeed"), "PythFeed not created");
    set(state, "pyth_feed_shared_object_id", fid);
    console.log(`    [done] PythFeed = ${fid}`);
  }
  if (get(state, "block_scholes_feed_shared_object_id")) {
    console.log(`    [skip] BlockScholesFeed = ${get(state, "block_scholes_feed_shared_object_id")}`);
  } else {
    const out = sui(
      ["client", "call", "--package", PKG, "--module", "registry", "--function", "create_and_share_block_scholes_feed",
        "--args", REG, BS_SOURCE_ID, "--gas-budget", GAS_BUDGET, "--json"], { json: true });
    const fid = require_(createdObjectId(out, "block_scholes_feed::BlockScholesFeed"), "BlockScholesFeed not created");
    set(state, "block_scholes_feed_shared_object_id", fid);
    console.log(`    [done] BlockScholesFeed = ${fid}`);
  }
  const PYTH_FEED = get(state, "pyth_feed_shared_object_id");
  const BS_FEED = get(state, "block_scholes_feed_shared_object_id");

  // === 5. Bind feeds to the canonical underlying (admin-gated) ===
  console.log(`==> Phase 5: bind feeds to underlying ${PROPBOOK_UNDERLYING_ID}`);
  if (get(state, "pyth_bound") === "1") {
    console.log("    [skip] pyth already bound");
  } else {
    sui(["client", "call", "--package", PKG, "--module", "registry", "--function", "bind_pyth_to_underlying",
      "--args", REG, CAP, PYTH_FEED, PROPBOOK_UNDERLYING_ID, "--gas-budget", GAS_BUDGET, "--json"], { json: true });
    set(state, "pyth_bound", 1);
    console.log("    [done] pyth bound");
  }
  if (get(state, "block_scholes_bound") === "1") {
    console.log("    [skip] block_scholes already bound");
  } else {
    sui(["client", "call", "--package", PKG, "--module", "registry", "--function", "bind_block_scholes_to_underlying",
      "--args", REG, CAP, BS_FEED, PROPBOOK_UNDERLYING_ID, "--gas-budget", GAS_BUDGET, "--json"], { json: true });
    set(state, "block_scholes_bound", 1);
    console.log("    [done] block_scholes bound");
  }

  // === 5b. Record linked on-chain dep references (verifier ids from dep-replacements) ===
  const T = fs.readFileSync(path.join(PROPBOOK_DIR, "Move.toml"), "utf8");
  const blk = (T.match(/\[dep-replacements\.testnet\]([\s\S]*)$/) ?? [, ""])[1] as string;
  for (const [name, key] of [
    ["pyth_lazer", "pyth_lazer_verifier_package_id"],
    ["wormhole", "wormhole_verifier_package_id"],
  ] as const) {
    const m = blk.match(new RegExp(`${name}\\s*=\\s*\\{([^}]*)\\}`));
    const pa = m && m[1].match(/published-at\s*=\s*"(0x[0-9a-fA-F]+)"/);
    if (pa) set(state, key, pa[1]);
  }

  // === 6. Verify ===
  console.log("==> Phase 6: verify");
  const verifyFeedSource = (id: string, field: string, expected: string, label: string) => {
    const obj = sui(["client", "object", id, "--json"], { json: true });
    const got = String(obj?.content?.fields?.[field] ?? obj?.content?.[field] ?? "");
    console.log(got === expected ? `    [ok] ${label} ${field}=${got}` : `    [FAIL] ${label} ${field}=${got} expected=${expected}`);
  };
  verifyFeedSource(PYTH_FEED, "pyth_source_id", PYTH_SOURCE_ID, "PythFeed");
  verifyFeedSource(BS_FEED, "bs_source_id", BS_SOURCE_ID, "BlockScholesFeed");

  console.log("\n==> Propbook testnet deployment complete.");
  console.log(`    State: ${STATE_JSON}`);
  console.log(fs.readFileSync(STATE_JSON, "utf8"));
}

main();
