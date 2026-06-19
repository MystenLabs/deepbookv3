#!/usr/bin/env -S npx tsx
/**
 * End-to-end testnet deploy for the `predict` package.
 *
 * Order:
 *   1. Link every on-chain dependency so publish links (not republishes) them:
 *        - local deps via each package's Published.toml: dusdc, account, fixed_math,
 *          block_scholes_oracle, propbook  (the last three are already committed; this
 *          script ensures dusdc + account).
 *        - git deps via a synthesized Published.toml in the resolved git-cache dir:
 *          token (DEEP), pyth_lazer, wormhole  (sui 1.73 ignores the manifest override).
 *   2. Build + publish predict. `init` shares Registry + ProtocolConfig + PoolVault (the PLP
 *      currency is created at init via coin_registry OTW) and transfers AdminCap + CoinMetadata<PLP>
 *      to the deployer.
 *   3. Configure to a working state matching the current setup (DUSDC quote, propbook BTC oracle):
 *        register_underlying  ->  lock_capital (bootstrap pool with DUSDC)  ->  mint_lifecycle_cap
 *        ->  create_expiry_market  ->  rebalance_expiry_cash (make the market mintable).
 *   4. Persist every id to deployment.testnet.json.
 *
 * Idempotent: ids persist to deployment.testnet.json; publish is short-circuited by predict's
 * Published.toml. Active env MUST be testnet, deployer = the canonical propbook-deployer.
 *
 * Env overrides: GAS_BUDGET, MIN_TICK_SIZE, TICK_SIZE, EXPIRY_MS, BOOTSTRAP_DUSDC, UNDERLYING_ID.
 */
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

// --- Paths ---
const SCRIPT_DIR = __dirname;
const PREDICT_DIR = path.resolve(SCRIPT_DIR, "..");
const PACKAGES_DIR = path.resolve(PREDICT_DIR, "..");
const STATE_JSON = path.join(SCRIPT_DIR, "deployment.testnet.json");

// --- Canonical testnet dependency ids (the "current setup" predict links against) ---
const DEPS = {
  dusdc_package_id: "0xe95040085976bfd54a1a07225cd46c8a2b4e8e2b6732f140a0fc49850ba73e1a",
  deep_token_package_id: "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8",
  fixed_math_package_id: "0xab488e225566fcea39a504dfc7bf98c12e9bc99fa5d3684bf6dff5f83807e938",
  block_scholes_oracle_package_id: "0x7ad752f3cf2f8c2c92dab8f53e49b7d4dba4b92b5b56de113e55d55cb4c89a15",
  propbook_package_id: "0xd848f191f5b3619d96e98063d8a3e6b15489b1671118da4ab71938170bcdf892",
  pyth_lazer_package_id: "0xf5bd2141967507050a91b58de3d95e77c432cd90d1799ee46effc27430a68c21",
  wormhole_package_id: "0xd5afd4e456e5451f1ca1e7b3d734ce7a0a3b397811a6cb72a4bd1dfc387839f2",
  oracle_registry_shared_object_id: "0x6c66d10d196eb1b611b6a5ac01362c1edd3f908c9076ef0e7bf61fd54b1a39f6",
  pyth_feed_shared_object_id: "0x2b7b2854cf24273ee30b6ffd5f98bc249f3567da02be3e0fb0b14817a58d7322",
  block_scholes_feed_shared_object_id: "0x06759be7ee0ff532ff5d4c57fb256537bdbd980e5d1f35767681afa6220e026a",
};

// Map of git-cache-resolved deps that publish must LINK (name in Move.lock -> on-chain id).
const GIT_DEPS: Record<string, string> = {
  token: DEPS.deep_token_package_id,
  pyth_lazer: DEPS.pyth_lazer_package_id,
  wormhole: DEPS.wormhole_package_id,
};
// Local deps whose Published.toml this script ensures (others are committed).
const LOCAL_DEP_TOMLS: Array<{ dir: string; id: string }> = [
  { dir: path.join(PACKAGES_DIR, "dusdc"), id: DEPS.dusdc_package_id },
];

// --- Config (env-overridable) ---
const EXPECTED_ENV = "testnet";
const GAS_BUDGET = process.env.GAS_BUDGET ?? "1000000000";
const UNDERLYING_ID = process.env.UNDERLYING_ID ?? "1"; // propbook BTC handle
const MIN_TICK_SIZE = process.env.MIN_TICK_SIZE ?? "1000000000"; // 1e9, must be a multiple of 10_000
const TICK_SIZE = process.env.TICK_SIZE ?? MIN_TICK_SIZE;
// Pool idle must cover each market's expiry_cash_floor (50k DUSDC) that rebalance_expiry_cash pulls,
// else the market funds to < floor and mints abort assert_backing. Default 60k = one market's floor
// + headroom (and >= min_bootstrap_liquidity 10 DUSDC). Raise for multiple markets.
const BOOTSTRAP_DUSDC = process.env.BOOTSTRAP_DUSDC ?? "60000000000";
const CLOCK = "0x6";
const SUI = process.env.SUI_BINARY ?? "sui";
const DUSDC_TYPE = `${DEPS.dusdc_package_id}::dusdc::DUSDC`;

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
function readPublishedTomlId(dir: string): string {
  const toml = path.join(dir, "Published.toml");
  if (!fs.existsSync(toml)) return "";
  const m = fs.readFileSync(toml, "utf8").match(/\[published\.testnet\][\s\S]*?published-at\s*=\s*"(0x[0-9a-fA-F]+)"/);
  return m ? m[1] : "";
}
function ensurePublishedToml(dir: string, id: string, chainId: string): void {
  const toml = path.join(dir, "Published.toml");
  if (readPublishedTomlId(dir) === id) return;
  fs.writeFileSync(toml, `[published.testnet]\nchain-id = "${chainId}"\npublished-at = "${id}"\noriginal-id = "${id}"\nversion = 1\n`);
  console.log(`    wrote ${path.relative(PACKAGES_DIR, toml)} -> ${id}`);
}

/**
 * Synthesize a Published.toml in each git dep's resolved git-cache dir so publish links the
 * on-chain package. Reads rev/subdir from predict's Move.lock [pinned.testnet.<name>]. Requires
 * the deps already fetched (a prior build).
 */
function linkGitDeps(chainId: string): void {
  const lock = fs.readFileSync(path.join(PREDICT_DIR, "Move.lock"), "utf8");
  const gitCache = path.join(os.homedir(), ".move", "git");
  for (const [name, id] of Object.entries(GIT_DEPS)) {
    const pin = lock.match(new RegExp(`\\[pinned\\.testnet\\.${name}\\]\\s*source = \\{([^}]*)\\}`));
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
    const dir = fs.existsSync(gitCache) ? fs.readdirSync(gitCache).find((d) => d.includes(rev[1])) : undefined;
    const moveToml = dir ? path.join(gitCache, dir, sub ? sub[1] : "", "Move.toml") : "";
    if (!moveToml || !fs.existsSync(moveToml)) {
      console.log(`  [warn] ${name}: git cache not found (rev ${rev[1]}); run a build first`);
      continue;
    }
    fs.writeFileSync(
      path.join(path.dirname(moveToml), "Published.toml"),
      `[published.testnet]\nchain-id = "${chainId}"\npublished-at = "${id}"\noriginal-id = "${id}"\nversion = 1\n`,
    );
    console.log(`    linked git dep ${name} -> ${id}`);
  }
}

/** Active-env JSON-RPC URL (the `sui client objects` CLI returns raw BCS, so we query RPC directly). */
function rpcUrl(): string {
  const envs = sui(["client", "envs", "--json"], { json: true });
  const list: any[] = Array.isArray(envs) ? (Array.isArray(envs[0]) ? envs[0] : envs) : envs.envs ?? [];
  const active = Array.isArray(envs) && typeof envs[1] === "string" ? envs[1] : sui(["client", "active-env"]);
  const hit = list.find((e) => e.alias === active) ?? list.find((e) => (e.rpc ?? "").includes("testnet"));
  return hit?.rpc ?? "https://fullnode.testnet.sui.io:443";
}
async function rpc(method: string, params: any[]): Promise<any> {
  const res = await fetch(rpcUrl(), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const j = await res.json();
  if (j.error) throw new Error(`${method}: ${JSON.stringify(j.error)}`);
  return j.result;
}

/** Find the deployer's largest DUSDC coin object id (for the bootstrap split). */
async function largestDusdcCoin(addr: string): Promise<{ id: string; balance: number }> {
  const result = await rpc("suix_getCoins", [addr, DUSDC_TYPE]);
  const coins = (result?.data ?? [])
    .map((c: any) => ({ id: c.coinObjectId as string, balance: Number(c.balance) }))
    .sort((a: any, b: any) => b.balance - a.balance);
  if (!coins.length) {
    console.error(`ERROR: deployer ${addr} holds no DUSDC (${DUSDC_TYPE}).`);
    process.exit(1);
  }
  return coins[0];
}

async function main(): Promise<void> {
  const state = loadState();

  // === 0. Preflight ===
  console.log("==> Preflight");
  const activeEnv = sui(["client", "active-env"]);
  const activeAddr = sui(["client", "active-address"]);
  const chainId = sui(["client", "chain-identifier"]);
  if (activeEnv !== EXPECTED_ENV) {
    console.error(`ERROR: active env is '${activeEnv}', expected '${EXPECTED_ENV}'.`);
    process.exit(1);
  }
  console.log(`    env=${activeEnv}  deployer=${activeAddr}  chain=${chainId}`);
  state.network = EXPECTED_ENV;
  state.deployer = activeAddr;
  state.dependencies = { ...DEPS };
  writeState(state);

  // === 1. Link dependencies ===
  console.log("==> Phase 1: link on-chain dependencies");
  // account must already be deployed (its Published.toml links it).
  const accountId = readPublishedTomlId(path.join(PACKAGES_DIR, "account"));
  if (!accountId) {
    console.error("ERROR: packages/account/Published.toml missing — run the account deploy first.");
    process.exit(1);
  }
  state.dependencies.account_package_id = accountId;
  for (const { dir, id } of LOCAL_DEP_TOMLS) ensurePublishedToml(dir, id, chainId);
  writeState(state);

  console.log("==> Building predict (fetches git deps into the cache)");
  try {
    sui(["move", "build", "--path", PREDICT_DIR]);
  } catch {
    console.log("    (build reported issues; continuing to link git deps then retry at publish)");
  }
  linkGitDeps(chainId);

  // === 2. Publish predict ===
  console.log("==> Phase 2: publish predict");
  if (state.predict_package_id && state.registry_shared_object_id && state.pool_vault_shared_object_id) {
    console.log(`    [skip] predict = ${state.predict_package_id}`);
  } else {
    const existing = readPublishedTomlId(PREDICT_DIR);
    if (existing && !state.registry_shared_object_id) {
      console.error(`ERROR: predict already published (${existing}) but object ids missing from ${STATE_JSON}.`);
      process.exit(1);
    }
    const out = sui(
      ["client", "publish", "--skip-dependency-verification", "--allow-dirty", "--gas-budget", GAS_BUDGET, "--json", PREDICT_DIR],
      { json: true },
    );
    state.predict_package_id = require_(publishedPackageId(out), "predict publish returned no packageId");
    state.registry_shared_object_id = require_(createdObjectId(out, "registry::Registry"), "Registry not created");
    state.protocol_config_shared_object_id = require_(createdObjectId(out, "protocol_config::ProtocolConfig"), "ProtocolConfig not created");
    state.pool_vault_shared_object_id = require_(createdObjectId(out, "plp::PoolVault"), "PoolVault not created");
    state.admin_cap_object_id = require_(createdObjectId(out, "admin::AdminCap"), "AdminCap not created");
    ensurePublishedToml(PREDICT_DIR, state.predict_package_id, chainId);
    writeState(state);
    console.log(`    [done] predict = ${state.predict_package_id}`);
    console.log(`           Registry = ${state.registry_shared_object_id}`);
    console.log(`           ProtocolConfig = ${state.protocol_config_shared_object_id}`);
    console.log(`           PoolVault = ${state.pool_vault_shared_object_id}`);
    console.log(`           AdminCap = ${state.admin_cap_object_id}`);
  }
  const PKG = state.predict_package_id;
  const REG = state.registry_shared_object_id;
  const CFG = state.protocol_config_shared_object_id;
  const VAULT = state.pool_vault_shared_object_id;
  const ADMIN = state.admin_cap_object_id;

  // === 2.5. authorize PredictApp in the account registry ===
  // mint/redeem generate app auth via account_registry::generate_auth_as_app<PredictApp>, which
  // aborts EAppNotAuthorized until the account admin authorizes the app. One-time, admin-gated.
  console.log("==> Phase 2.5: authorize PredictApp in account registry");
  if (state.predict_app_authorized) {
    console.log("    [skip] PredictApp already authorized");
  } else {
    const acctState = JSON.parse(fs.readFileSync(path.join(PACKAGES_DIR, "account", "deploy", "deployment.testnet.json"), "utf8"));
    sui(["client", "call", "--package", acctState.account_package_id, "--module", "account_registry", "--function", "authorize_app",
      "--type-args", `${PKG}::predict_account::PredictApp`,
      "--args", acctState.account_registry_shared_object_id, acctState.account_admin_cap_object_id,
      "--gas-budget", GAS_BUDGET, "--json"], { json: true });
    state.predict_app_authorized = true;
    writeState(state);
    console.log("    [done] PredictApp authorized");
  }

  // === 2.6. relax oracle freshness for testnet ===
  // The testnet propbook price-pusher refreshes each expiry's Block Scholes surface only ~every
  // 5s, which exceeds the 3s default block_scholes_surface_freshness_ms -> every mint would abort
  // EBlockScholesSurfaceStale. Relax both freshness windows to tolerate the testnet pusher cadence
  // (admin-tunable; mainnet keeps the tighter defaults with a faster pusher).
  const BS_FRESHNESS_MS = process.env.BS_SURFACE_FRESHNESS_MS ?? "30000";
  const PYTH_FRESHNESS_MS = process.env.PYTH_SPOT_FRESHNESS_MS ?? "30000";
  console.log("==> Phase 2.6: relax oracle freshness (testnet pusher cadence)");
  if (state.freshness_relaxed) {
    console.log("    [skip] freshness already relaxed");
  } else {
    sui(["client", "call", "--package", PKG, "--module", "protocol_config", "--function", "set_block_scholes_surface_freshness_ms",
      "--args", CFG, ADMIN, BS_FRESHNESS_MS, "--gas-budget", GAS_BUDGET, "--json"], { json: true });
    sui(["client", "call", "--package", PKG, "--module", "protocol_config", "--function", "set_pyth_spot_freshness_ms",
      "--args", CFG, ADMIN, PYTH_FRESHNESS_MS, "--gas-budget", GAS_BUDGET, "--json"], { json: true });
    state.freshness_relaxed = true;
    writeState(state);
    console.log(`    [done] BS surface freshness=${BS_FRESHNESS_MS}ms, pyth spot freshness=${PYTH_FRESHNESS_MS}ms`);
  }

  // === 3. register_underlying ===
  console.log(`==> Phase 3: register_underlying ${UNDERLYING_ID} (min_tick_size=${MIN_TICK_SIZE})`);
  if (state.underlying_registered) {
    console.log("    [skip] underlying already registered");
  } else {
    sui(["client", "call", "--package", PKG, "--module", "registry", "--function", "register_underlying",
      "--args", REG, CFG, ADMIN, UNDERLYING_ID, MIN_TICK_SIZE, "--gas-budget", GAS_BUDGET, "--json"], { json: true });
    state.underlying_registered = true;
    state.min_tick_size = Number(MIN_TICK_SIZE);
    writeState(state);
    console.log("    [done] underlying registered");
  }

  // === 4. lock_capital (bootstrap pool) ===
  console.log(`==> Phase 4: lock_capital (bootstrap ${BOOTSTRAP_DUSDC} DUSDC units)`);
  if (state.bootstrapped) {
    console.log("    [skip] pool already bootstrapped");
  } else {
    const coin = await largestDusdcCoin(activeAddr);
    if (coin.balance < Number(BOOTSTRAP_DUSDC)) {
      console.error(`ERROR: largest DUSDC coin ${coin.id} has ${coin.balance} < bootstrap ${BOOTSTRAP_DUSDC}.`);
      process.exit(1);
    }
    sui(["client", "ptb",
      "--split-coins", `@${coin.id}`, `[${BOOTSTRAP_DUSDC}]`, "--assign", "boot",
      "--move-call", `${PKG}::plp::lock_capital`, `@${VAULT}`, `@${CFG}`, `@${ADMIN}`, "boot.0",
      "--gas-budget", GAS_BUDGET, "--json"], { json: true });
    state.bootstrapped = true;
    state.bootstrap_locked_dusdc = Number(BOOTSTRAP_DUSDC);
    writeState(state);
    console.log("    [done] pool bootstrapped");
  }

  // === 5. mint_lifecycle_cap ===
  // Returns a MarketLifecycleCap (no `drop`), so it must be captured + transferred in a PTB;
  // plain `sui client call` aborts with UnusedValueWithoutDrop on the unused return.
  console.log("==> Phase 5: mint_lifecycle_cap");
  if (state.market_lifecycle_cap_object_id) {
    console.log(`    [skip] MarketLifecycleCap = ${state.market_lifecycle_cap_object_id}`);
  } else {
    const out = sui(["client", "ptb",
      "--move-call", `${PKG}::registry::mint_lifecycle_cap`, `@${REG}`, `@${CFG}`, `@${ADMIN}`, "--assign", "cap",
      "--transfer-objects", "[cap]", `@${activeAddr}`,
      "--gas-budget", GAS_BUDGET, "--json"], { json: true });
    state.market_lifecycle_cap_object_id = require_(createdObjectId(out, "MarketLifecycleCap"), "MarketLifecycleCap not created");
    writeState(state);
    console.log(`    [done] MarketLifecycleCap = ${state.market_lifecycle_cap_object_id}`);
  }
  const LIFECYCLE = state.market_lifecycle_cap_object_id;

  // === 6. create_expiry_market (+ rebalance) ===
  // EXPIRY_MS must be > now and a multiple of resolution_period_ms (60_000). A market is only
  // mintable while the propbook price-pusher writes a FRESH Block Scholes surface for its expiry,
  // and the pusher keeps the next 30 one-minute boundaries hot (config.testnet expiry_market_count=30,
  // duration=1m). So the default is a near-future minute boundary ~20 min out (mid-window): far enough
  // to trade, comfortably inside the hot window. Override EXPIRY_MS for a specific market.
  const PERIOD = 60_000;
  const firstBoundary = Math.floor(Date.now() / PERIOD) * PERIOD + PERIOD;
  const defaultExpiry = firstBoundary + 20 * PERIOD;
  state.markets = state.markets ?? {};
  // Idempotency: the default expiry is time-dependent, so a bare re-run must NOT keep minting new
  // markets. Only create when EXPIRY_MS is explicitly set, or when no market exists yet. Each
  // market permanently locks `expiry_cash_floor` (50k DUSDC) from pool idle, so duplicates are costly.
  const explicitExpiry = process.env.EXPIRY_MS;
  if (!explicitExpiry && Object.keys(state.markets).length > 0) {
    console.log(`==> Phase 6: skip create_expiry_market (markets exist; set EXPIRY_MS to add another)`);
    console.log("\n==> Predict testnet deployment complete.");
    console.log(`    State: ${STATE_JSON}`);
    console.log(fs.readFileSync(STATE_JSON, "utf8"));
    return;
  }
  const EXPIRY_MS = String(explicitExpiry ?? defaultExpiry);
  console.log(`==> Phase 6: create_expiry_market expiry=${EXPIRY_MS} tick_size=${TICK_SIZE}`);
  if (state.markets[EXPIRY_MS]) {
    console.log(`    [skip] market(${EXPIRY_MS}) = ${state.markets[EXPIRY_MS]}`);
  } else {
    const out = sui(["client", "call", "--package", PKG, "--module", "registry", "--function", "create_expiry_market",
      "--args", REG, VAULT, CFG, DEPS.oracle_registry_shared_object_id, LIFECYCLE, UNDERLYING_ID, EXPIRY_MS, TICK_SIZE, CLOCK,
      "--gas-budget", GAS_BUDGET, "--json"], { json: true });
    const marketId = require_(createdObjectId(out, "expiry_market::ExpiryMarket"), "ExpiryMarket not created");
    state.markets[EXPIRY_MS] = marketId;
    writeState(state);
    console.log(`    [done] market(${EXPIRY_MS}) = ${marketId}`);

    console.log("    rebalance_expiry_cash (make market mintable)");
    sui(["client", "call", "--package", PKG, "--module", "plp", "--function", "rebalance_expiry_cash",
      "--args", VAULT, marketId, CFG, DEPS.oracle_registry_shared_object_id, DEPS.pyth_feed_shared_object_id, CLOCK,
      "--gas-budget", GAS_BUDGET, "--json"], { json: true });
    console.log("    [done] rebalanced");
  }

  console.log("\n==> Predict testnet deployment complete.");
  console.log(`    State: ${STATE_JSON}`);
  console.log(fs.readFileSync(STATE_JSON, "utf8"));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
