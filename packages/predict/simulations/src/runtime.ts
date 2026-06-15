import { bcs } from "@mysten/sui/bcs";
import { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Transaction } from "@mysten/sui/transactions";
import { deriveObjectID } from "@mysten/sui/utils";

import {
    ADMIN_CAP_ID,
    BLOCK_SCHOLES_ORACLE_PACKAGE_ID,
    DUSDC_CURRENCY_ID,
    DUSDC_PACKAGE_ID,
    LOCAL_PYTH_GOVERNANCE_CHAIN,
    LOCAL_PYTH_GOVERNANCE_CONTRACT,
    LOCAL_PYTH_GUARDIAN_PRIVATE_KEY,
    LOCAL_PYTH_RECEIVER_CHAIN,
    LOCAL_PYTH_SIGNER_EXPIRES_AT_SECONDS,
    LOCAL_PYTH_SIGNER_PRIVATE_KEY,
    LOCAL_PYTH_SIGNER_PUBLIC_KEY,
    ORACLE_REGISTRY_ADMIN_CAP_ID,
    ORACLE_REGISTRY_ID,
    PACKAGE_ID,
    POOL_VAULT_ID,
    PROPBOOK_PACKAGE_ID,
    PROTOCOL_CONFIG_ID,
    PYTH_LAZER_PACKAGE_ID,
    PYTH_LAZER_STATE_ID,
    REGISTRY_ID,
    RPC_URL,
    TREASURY_CAP_ID,
    WORMHOLE_PACKAGE_ID,
    WORMHOLE_STATE_ID,
    getSigner,
} from "./env.js";
import {
    type LocalPythConfig,
    lazerUpdateFromConfig,
    updateTrustedSignerVaaFromConfig,
} from "./localPyth.js";

export interface GasUsage {
    computationCost: number;
    storageCost: number;
    storageRebate: number;
    gasTotal: number;
}

export interface ExecutionReceipt {
    digest: string;
    gas: GasUsage;
    events: any[];
    objectChanges: any[];
    effects: any;
}

const DUSDC_TYPE = `${DUSDC_PACKAGE_ID}::dusdc::DUSDC`;
const PLP_TYPE = `${PACKAGE_ID}::plp::PLP`;
const CLOCK_ID = "0x6";
const COIN_REGISTRY_ID = "0xc";
// Sui's singleton balance-accumulator root lives at the reserved address 0xacc
// (object::SUI_ACCUMULATOR_ROOT_OBJECT_ID). The async-LP flush delivers PLP/DUSDC
// fills to a manager's accumulator; `withdraw_settled<T>` reads through this root.
const ACCUMULATOR_ROOT_ID = "0xacc";
// Pyth Lazer feed id (the propbook spot feed key) and the Propbook underlying id.
// The harness binds one market to one Pyth feed + one BS feed for that underlying,
// so a single id serves both.
const PYTH_FEED_ID = 1;
const BS_UNDERLYING_ID = PYTH_FEED_ID;
// Strike range encoding (range_codec / constants.move): two u24 ticks packed
// `lower | (higher << TICK_BITS)`. `raw_strike = tick * tick_size`. Tick 0 is the
// neg-inf sentinel (lower side); `POS_INF_TICK` is the pos-inf sentinel (higher
// side). The harness tick size is $1 (1e9-scaled), mirroring the registered market
// tick size for this Propbook underlying.
const TICK_BITS = 24n;
const POS_INF_TICK = (1n << TICK_BITS) - 1n;
const ORACLE_TICK_SIZE = 1_000_000_000n;
const SETUP_RESPONSE_OPTIONS = {
    showEffects: true,
    showEvents: true,
    showObjectChanges: true,
} as const;
const EXECUTION_RESPONSE_OPTIONS = {
    showEffects: true,
    showEvents: true,
    showObjectChanges: true,
} as const;

export const client = new SuiJsonRpcClient({ url: RPC_URL, network: "localnet" });
export const signer = getSigner();
export const address = signer.getPublicKey().toSuiAddress();
export { POOL_VAULT_ID, PROTOCOL_CONFIG_ID };

const DEFAULT_GAS_BUDGET = 1_000_000_000n;

function isSuccessStatus(status: any): boolean {
    return status?.status === "success" || status?.success === true;
}

function formatStatusError(status: any, fallback: string): string {
    return status?.error ?? fallback;
}

function gasSummaryFromEffects(effects: any): GasUsage {
    const gasUsed = effects?.gasUsed ?? {};
    const computationCost = Number(gasUsed.computationCost ?? 0);
    const storageCost = Number(gasUsed.storageCost ?? 0);
    const storageRebate = Number(gasUsed.storageRebate ?? 0);

    return {
        computationCost,
        storageCost,
        storageRebate,
        gasTotal: computationCost + storageCost - storageRebate,
    };
}

async function getTransactionBlockWithRetry(digest: string): Promise<any> {
    let lastError: unknown;

    for (let attempt = 0; attempt < 20; attempt++) {
        try {
            return await client.getTransactionBlock({
                digest,
                options: { showEvents: true, showObjectChanges: true, showEffects: true },
            });
        } catch (error) {
            lastError = error;
            await new Promise((resolve) => setTimeout(resolve, 250));
        }
    }

    throw lastError;
}

export function target(module: string, fn: string): `${string}::${string}::${string}` {
    return `${PACKAGE_ID}::${module}::${fn}`;
}

// Note: `predict_math` was renamed to `fixed_math`, but the harness no longer makes
// any direct fixed_math/i64 Move call — the old oracle path built SVI `i64`s via
// `i64::from_parts`; the propbook BS update now takes magnitude+sign primitives
// directly (`block_scholes_oracle::update::new_update`). So there is no
// `fixedMathTarget` helper. The rename still matters for the localnet publish flow
// and the named-address dependency (see SIM_STATUS / run.sh).

// propbook owns the extracted Pyth spot feed and Block Scholes surface feed.
function propbookTarget(module: string, fn: string): `${string}::${string}::${string}` {
    return `${PROPBOOK_PACKAGE_ID}::${module}::${fn}`;
}

// `block_scholes_oracle` is the STUB BS signed-data verifier that mints the
// verified `Update` consumed by `block_scholes_feed::update`.
function bsOracleTarget(module: string, fn: string): `${string}::${string}::${string}` {
    return `${BLOCK_SCHOLES_ORACLE_PACKAGE_ID}::${module}::${fn}`;
}

function pythLazerTarget(module: string, fn: string): `${string}::${string}::${string}` {
    return `${PYTH_LAZER_PACKAGE_ID}::${module}::${fn}`;
}

function wormholeTarget(module: string, fn: string): `${string}::${string}::${string}` {
    return `${WORMHOLE_PACKAGE_ID}::${module}::${fn}`;
}

function localPythConfig(): LocalPythConfig {
    return {
        governanceChain: LOCAL_PYTH_GOVERNANCE_CHAIN,
        governanceContract: LOCAL_PYTH_GOVERNANCE_CONTRACT,
        receiverChain: LOCAL_PYTH_RECEIVER_CHAIN,
        guardianPrivateKey: LOCAL_PYTH_GUARDIAN_PRIVATE_KEY,
        signerPrivateKey: LOCAL_PYTH_SIGNER_PRIVATE_KEY,
        signerPublicKey: LOCAL_PYTH_SIGNER_PUBLIC_KEY,
        signerExpiresAtSeconds: LOCAL_PYTH_SIGNER_EXPIRES_AT_SECONDS,
    };
}

let lastSourceTimestampMs = 0n;

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function clockTimestampMs(): Promise<bigint> {
    const object = await client.getObject({
        id: CLOCK_ID,
        options: { showContent: true },
    });
    const timestamp = (object.data?.content as any)?.fields?.timestamp_ms;
    if (timestamp === undefined) {
        throw new Error("unable to read localnet Clock timestamp");
    }
    return BigInt(timestamp);
}

async function nextSourceTimestampMs(): Promise<bigint> {
    for (let attempt = 0; attempt < 50; attempt++) {
        const latestAllowed = (await clockTimestampMs()) - 1n;
        if (latestAllowed > lastSourceTimestampMs) {
            lastSourceTimestampMs = latestAllowed;
            return latestAllowed;
        }
        await sleep(25);
    }

    throw new Error("localnet Clock did not advance enough for a fresh source timestamp");
}

// One oracle refresh now writes BOTH propbook feeds: a permissionless Pyth Lazer
// spot update (PythFeed) and a Block Scholes surface update (BlockScholesFeed) for
// the market's expiry. There is no in-package oracle and no writer cap anymore.
interface OracleRefreshParams {
    pythFeedId: string;
    bsFeedId: string;
    expiry: bigint;
    spot: bigint;
    forward: bigint;
    svi: {
        a: bigint;
        b: bigint;
        rho: bigint;
        rhoNegative: boolean;
        m: bigint;
        mNegative: boolean;
        sigma: bigint;
    };
}

interface MintParams {
    expiryMarketId: string;
    protocolConfigId: string;
    managerId: string;
    pythFeedId: string;
    bsFeedId: string;
    strike: bigint;
    isUp: boolean;
    quantity: bigint;
    leverage: bigint;
}

interface RedeemParams {
    expiryMarketId: string;
    protocolConfigId: string;
    managerId: string;
    pythFeedId: string;
    bsFeedId: string;
    orderId: string;
    closeQuantity: bigint;
}

// Inputs to drive one privileged full-pool flush (the async LP drain).
export interface FlushParams {
    poolVaultId: string;
    protocolConfigId: string;
    expiryMarketId: string;
    pythFeedId: string;
    bsFeedId: string;
    lifecycleCapId: string;
}

// Convert a raw binary-range strike to the `(lower_tick, higher_tick)` pair the
// `mint` entrypoint now takes directly (there is no standalone packed range key).
// An UP order is `(strike, +inf)` -> lower_tick = strike/tick_size, higher_tick =
// POS_INF_TICK; a DOWN order is `(-inf, strike)` -> lower_tick = 0 (neg-inf),
// higher_tick = strike/tick_size.
function binaryRangeTicks(
    strike: bigint,
    isUp: boolean,
): { lowerTick: bigint; higherTick: bigint } {
    const tick = strike / ORACLE_TICK_SIZE;
    if (tick * ORACLE_TICK_SIZE !== strike) {
        throw new Error(`strike ${strike} is not a whole tick multiple of ${ORACLE_TICK_SIZE}`);
    }
    if (tick <= 0n || tick >= POS_INF_TICK) {
        throw new Error(`strike tick ${tick} outside the finite tick domain (1..POS_INF_TICK-1)`);
    }
    return {
        lowerTick: isUp ? tick : 0n,
        higherTick: isUp ? POS_INF_TICK : tick,
    };
}

async function addOracleRefresh(tx: Transaction, params: OracleRefreshParams): Promise<void> {
    const sourceTimestampMs = await nextSourceTimestampMs();
    addPythFeedUpdate(tx, params.pythFeedId, params.spot, sourceTimestampMs);
    addBlockScholesSurfaceUpdate(tx, params, sourceTimestampMs);
}

// Permissionless Pyth Lazer spot update: parse+verify the signed Lazer payload,
// then store it through the propbook PythFeed (no protocol config, no cap).
function addPythFeedUpdate(
    tx: Transaction,
    pythFeedId: string,
    spot: bigint,
    sourceTimestampMs: bigint,
): void {
    const updateBytes = lazerUpdateFromConfig(
        localPythConfig(),
        PYTH_FEED_ID,
        spot,
        sourceTimestampMs,
    );
    const update = tx.moveCall({
        target: pythLazerTarget("pyth_lazer", "parse_and_verify_le_ecdsa_update"),
        arguments: [
            tx.object(PYTH_LAZER_STATE_ID),
            tx.object(CLOCK_ID),
            tx.pure.vector("u8", Array.from(updateBytes)),
        ],
    });
    tx.moveCall({
        target: propbookTarget("pyth_feed", "update"),
        arguments: [tx.object(pythFeedId), update, tx.object(CLOCK_ID)],
    });
}

// Block Scholes surface update for one expiry: build the STUB verified `Update`
// (spot + forward + SVI, carried as magnitude+sign primitives) via
// `block_scholes_oracle::update::new_update`, then ingest it into the propbook
// BlockScholesFeed. There is no writer cap and no separate SVI call anymore.
function addBlockScholesSurfaceUpdate(
    tx: Transaction,
    params: OracleRefreshParams,
    publishedAtMs: bigint,
): void {
    const update = tx.moveCall({
        target: bsOracleTarget("update", "new_update"),
        arguments: [
            tx.pure.u32(BS_UNDERLYING_ID),
            tx.pure.u64(params.expiry),
            tx.pure.u64(publishedAtMs),
            tx.pure.u64(params.spot),
            tx.pure.u64(params.forward),
            tx.pure.u64(params.svi.a),
            tx.pure.u64(params.svi.b),
            tx.pure.u64(params.svi.sigma),
            tx.pure.u64(params.svi.rho),
            tx.pure.bool(params.svi.rhoNegative),
            tx.pure.u64(params.svi.m),
            tx.pure.bool(params.svi.mNegative),
        ],
    });
    tx.moveCall({
        target: propbookTarget("block_scholes_feed", "update"),
        arguments: [tx.object(params.bsFeedId), update, tx.object(CLOCK_ID)],
    });
}

function mintDusdc(tx: Transaction, amount: bigint) {
    const [coin] = tx.moveCall({
        target: "0x2::coin::mint",
        typeArguments: [DUSDC_TYPE],
        arguments: [tx.object(TREASURY_CAP_ID), tx.pure.u64(amount)],
    });
    return coin;
}

// Run one full-pool flush over the single active market in the same PTB: the
// privileged `start_pool_valuation` (started via a market-deployer `MarketLifecycleCap`
// proof — the sole flush authority) -> one `value_expiry` for our market ->
// `finish_flush`, which drains the supply/withdraw request queues at the frozen mark.
// The two `finish_flush` budgets are `None` (drain both queues fully). The harness has
// exactly one expiry market, so the snapshot covers one `value_expiry`. (Multi-market
// topologies must call `value_expiry` once per active market between start and finish.)
function addFlush(tx: Transaction, params: FlushParams): void {
    const proof = tx.moveCall({
        target: target("registry", "generate_lifecycle_proof"),
        arguments: [tx.object(REGISTRY_ID), tx.object(params.lifecycleCapId)],
    });
    const valuation = tx.moveCall({
        target: target("plp", "start_pool_valuation"),
        arguments: [tx.object(params.protocolConfigId), tx.object(params.poolVaultId), proof],
    });
    tx.moveCall({
        target: target("plp", "value_expiry"),
        arguments: [
            valuation,
            tx.object(params.poolVaultId),
            tx.object(params.expiryMarketId),
            tx.object(params.protocolConfigId),
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(params.pythFeedId),
            tx.object(params.bsFeedId),
            tx.object(CLOCK_ID),
        ],
    });
    tx.moveCall({
        target: target("plp", "finish_flush"),
        arguments: [
            valuation,
            tx.object(params.poolVaultId),
            tx.object(params.protocolConfigId),
            tx.pure(bcs.option(bcs.u64()).serialize(null)), // supply_budget: None (drain fully)
            tx.pure(bcs.option(bcs.u64()).serialize(null)), // withdraw_budget: None (drain fully)
        ],
    });
}

function addMint(tx: Transaction, params: MintParams): void {
    const { lowerTick, higherTick } = binaryRangeTicks(params.strike, params.isUp);
    const proof = tx.moveCall({
        target: target("predict_manager", "generate_proof_as_owner"),
        arguments: [tx.object(params.managerId)],
    });
    tx.moveCall({
        target: target("expiry_market", "mint"),
        arguments: [
            tx.object(params.expiryMarketId),
            tx.object(params.managerId),
            proof,
            tx.object(params.protocolConfigId),
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(params.pythFeedId),
            tx.object(params.bsFeedId),
            tx.pure.u64(lowerTick),
            tx.pure.u64(higherTick),
            tx.pure.u64(params.quantity),
            tx.pure.u64(params.leverage),
            tx.object(CLOCK_ID),
        ],
    });
}

function addRedeem(tx: Transaction, params: RedeemParams): void {
    // The sim always acts as the manager owner, so it uses the authorized
    // `redeem` with a proof. Works for live redeems (proof consumed) and
    // settled / liquidated redeems (proof dropped).
    const proof = tx.moveCall({
        target: target("predict_manager", "generate_proof_as_owner"),
        arguments: [tx.object(params.managerId)],
    });
    tx.moveCall({
        target: target("expiry_market", "redeem"),
        arguments: [
            tx.object(params.expiryMarketId),
            tx.object(params.managerId),
            proof,
            tx.object(params.protocolConfigId),
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(params.pythFeedId),
            tx.object(params.bsFeedId),
            tx.pure.u256(BigInt(params.orderId)),
            tx.pure.u64(params.closeQuantity),
            tx.object(CLOCK_ID),
        ],
    });
}

export function finalizeDusdcCurrencyRegistrationTx(): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: "0x2::coin_registry::finalize_registration",
        typeArguments: [DUSDC_TYPE],
        arguments: [tx.object(COIN_REGISTRY_ID), tx.object(DUSDC_CURRENCY_ID)],
    });
    return tx;
}

export function mintLifecycleCapTx(recipient: string): Transaction {
    const tx = new Transaction();
    // MarketLifecycleCap mint moved from `plp` to `registry` (the allowlist now
    // lives on Registry, its sole gating call site being create_expiry_market).
    const cap = tx.moveCall({
        target: target("registry", "mint_lifecycle_cap"),
        arguments: [tx.object(REGISTRY_ID), tx.object(ADMIN_CAP_ID)],
    });
    tx.transferObjects([cap], tx.pure.address(recipient));
    return tx;
}

// Admin-approve one Propbook underlying for Predict (recording the minimum market
// tick size) AND permissionlessly create the two propbook feeds the market binds
// to: the global Pyth spot feed and the per-underlying Block Scholes surface feed.
// Both create calls register into the shared propbook `OracleRegistry`.
export function registerUnderlyingAndCreateFeedsTx(feedId: number, tickSize: bigint): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("registry", "register_underlying"),
        arguments: [
            tx.object(REGISTRY_ID),
            tx.object(ADMIN_CAP_ID),
            tx.pure.u32(BS_UNDERLYING_ID),
            tx.pure.u64(tickSize),
        ],
    });
    tx.moveCall({
        target: propbookTarget("registry", "create_and_share_pyth_feed"),
        arguments: [tx.object(ORACLE_REGISTRY_ID), tx.pure.u32(feedId)],
    });
    tx.moveCall({
        target: propbookTarget("registry", "create_and_share_block_scholes_feed"),
        arguments: [tx.object(ORACLE_REGISTRY_ID), tx.pure.u32(BS_UNDERLYING_ID)],
    });
    return tx;
}

// Admin-bind the Pyth spot feed and the Block Scholes surface feed to one canonical
// propbook underlying, so `create_expiry_market` accepts the pair. Must run AFTER
// the feeds are shared (separate tx from creation) and BEFORE market creation. Uses
// the propbook `RegistryAdminCap`. The Pyth source id doubles as the underlying id
// in this single-underlying harness (see `BS_UNDERLYING_ID`).
export function bindFeedsToUnderlyingTx(params: {
    pythFeedId: string;
    bsFeedId: string;
}): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: propbookTarget("registry", "bind_pyth_to_underlying"),
        arguments: [
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(ORACLE_REGISTRY_ADMIN_CAP_ID),
            tx.object(params.pythFeedId),
            tx.pure.u32(BS_UNDERLYING_ID),
        ],
    });
    tx.moveCall({
        target: propbookTarget("registry", "bind_block_scholes_to_underlying"),
        arguments: [
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(ORACLE_REGISTRY_ADMIN_CAP_ID),
            tx.object(params.bsFeedId),
            tx.pure.u32(BS_UNDERLYING_ID),
        ],
    });
    return tx;
}

export function setTemplateExpiryFeeConfigTx(
    protocolConfigId: string,
    expiryFeeWindowMs: bigint,
    expiryFeeMaxMultiplier: bigint,
): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("protocol_config", "set_template_expiry_fee_window_ms"),
        arguments: [
            tx.object(protocolConfigId),
            tx.object(ADMIN_CAP_ID),
            tx.pure.u64(expiryFeeWindowMs),
        ],
    });
    tx.moveCall({
        target: target("protocol_config", "set_template_expiry_fee_max_multiplier"),
        arguments: [
            tx.object(protocolConfigId),
            tx.object(ADMIN_CAP_ID),
            tx.pure.u64(expiryFeeMaxMultiplier),
        ],
    });
    return tx;
}

export function updatePythTrustedSignerTx(): Transaction {
    const tx = new Transaction();
    const vaaBytes = updateTrustedSignerVaaFromConfig(localPythConfig());
    const vaa = tx.moveCall({
        target: wormholeTarget("vaa", "parse_and_verify"),
        arguments: [
            tx.object(WORMHOLE_STATE_ID),
            tx.pure.vector("u8", Array.from(vaaBytes)),
            tx.object(CLOCK_ID),
        ],
    });
    tx.moveCall({
        target: pythLazerTarget("actions", "update_trusted_signer"),
        arguments: [tx.object(PYTH_LAZER_STATE_ID), vaa],
    });
    return tx;
}

// Seed the Block Scholes surface (and Pyth spot) for the market's expiry. Market
// creation itself reads NO spot now (absolute ticks need no grid centering), but a
// fresh surface must exist before the first mint and before any flush valuation
// can price `current_nav`. Kept as its own tx so it can run before/independently
// of market creation.
export async function seedOracleTx(params: {
    pythFeedId: string;
    bsFeedId: string;
    expiry: bigint;
    spot: bigint;
    forward: bigint;
    svi: OracleRefreshParams["svi"];
}): Promise<Transaction> {
    const tx = new Transaction();
    await addOracleRefresh(tx, params);
    return tx;
}

// Create the expiry market for one Propbook underlying. No spot is read at
// creation. The registry validates, against propbook's canonical binding, that
// Pyth + Block Scholes feeds are bound to `BS_UNDERLYING_ID` (run
// `bindFeedsToUnderlyingTx` first). `create_expiry_market` returns one ID and
// registers the market with the vault as a zero-cash accounting row (not mintable
// until `rebalance_expiry_cash` funds it).
export function createExpiryMarketTx(params: {
    poolVaultId: string;
    protocolConfigId: string;
    lifecycleCapId: string;
    expiry: bigint;
    tickSize: bigint;
}): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("registry", "create_expiry_market"),
        arguments: [
            tx.object(REGISTRY_ID),
            tx.object(params.poolVaultId),
            tx.object(params.protocolConfigId),
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(params.lifecycleCapId),
            tx.pure.u32(BS_UNDERLYING_ID),
            tx.pure.u64(params.expiry),
            tx.pure.u64(params.tickSize),
            tx.object(CLOCK_ID),
        ],
    });
    return tx;
}

// Fund / rebalance one expiry's cash from pool idle toward target. Standalone and
// permissionless; this is what makes a freshly created market mintable. Replaces
// the old setup-only PLP sync.
export function rebalanceExpiryCashTx(params: {
    poolVaultId: string;
    protocolConfigId: string;
    expiryMarketId: string;
    pythFeedId: string;
}): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("plp", "rebalance_expiry_cash"),
        arguments: [
            tx.object(params.poolVaultId),
            tx.object(params.expiryMarketId),
            tx.object(params.protocolConfigId),
            tx.object(ORACLE_REGISTRY_ID),
            tx.object(params.pythFeedId),
            tx.object(CLOCK_ID),
        ],
    });
    return tx;
}

// Queue a supply request: escrow `amount` DUSDC, recorded against the manager as
// the fill recipient. The minted PLP is delivered to the manager (via the balance
// accumulator) at the next flush, NOT returned here. Returns no object.
export function requestSupplyTx(params: {
    poolVaultId: string;
    protocolConfigId: string;
    managerId: string;
    amount: bigint;
}): Transaction {
    const tx = new Transaction();
    const dusdc = mintDusdc(tx, params.amount);
    tx.moveCall({
        target: target("plp", "request_supply"),
        arguments: [
            tx.object(params.poolVaultId),
            tx.object(params.managerId),
            tx.object(params.protocolConfigId),
            dusdc,
        ],
    });
    return tx;
}

// Materialize `shares` PLP from the manager's balance accumulator (the async flush
// delivers PLP fills there, not as a coin), then queue a withdraw request escrowing
// that PLP. `withdraw_settled<PLP>` first settles delivered funds and is owner-gated,
// so the sim's sender-owned manager can call it directly. The DUSDC fill is delivered
// to the manager at the next flush, NOT returned here. One PTB: settle+withdraw+request.
export function withdrawSettledAndRequestTx(params: {
    poolVaultId: string;
    protocolConfigId: string;
    managerId: string;
    shares: bigint;
}): Transaction {
    const tx = new Transaction();
    const [lpCoin] = tx.moveCall({
        target: target("predict_manager", "withdraw_settled"),
        typeArguments: [PLP_TYPE],
        arguments: [
            tx.object(params.managerId),
            tx.object(ACCUMULATOR_ROOT_ID),
            tx.pure.u64(params.shares),
        ],
    });
    tx.moveCall({
        target: target("plp", "request_withdraw"),
        arguments: [
            tx.object(params.poolVaultId),
            tx.object(params.managerId),
            tx.object(params.protocolConfigId),
            lpCoin,
        ],
    });
    return tx;
}

// Refresh the oracle, then run one privileged full-pool flush that drains both LP
// request queues at the frozen mark. The drain happens inside `finish_flush`; no
// per-LP coin is returned (fills land on the manager via the accumulator).
export async function refreshOracleAndFlushTx(
    params: OracleRefreshParams & FlushParams,
): Promise<Transaction> {
    const tx = new Transaction();
    await addOracleRefresh(tx, params);
    addFlush(tx, params);
    return tx;
}

export function createManagerTx(): Transaction {
    const tx = new Transaction();
    tx.moveCall({
        target: target("registry", "create_and_share_manager"),
        arguments: [tx.object(REGISTRY_ID)],
    });
    return tx;
}

// === Derived object IDs ===

const PredictManagerKeyBcs = bcs.struct("PredictManagerKey", {
    pos0: bcs.Address,
    pos1: bcs.u64(),
});

export function deriveManagerId(owner: string, index: bigint = 0n): string {
    const key = PredictManagerKeyBcs.serialize({ pos0: owner, pos1: index }).toBytes();
    return deriveObjectID(REGISTRY_ID, `${PACKAGE_ID}::predict_manager::PredictManagerKey`, key);
}

export function depositToManagerTx(managerId: string, amount: bigint): Transaction {
    const tx = new Transaction();
    const coin = mintDusdc(tx, amount);
    tx.moveCall({
        target: target("predict_manager", "deposit"),
        arguments: [tx.object(managerId), coin],
    });
    return tx;
}

export async function refreshOracleAndMintTx(
    params: OracleRefreshParams & MintParams,
): Promise<Transaction> {
    const tx = new Transaction();
    await addOracleRefresh(tx, params);
    addMint(tx, params);
    return tx;
}

export async function refreshOracleAndRedeemTx(
    params: OracleRefreshParams & RedeemParams,
): Promise<Transaction> {
    const tx = new Transaction();
    await addOracleRefresh(tx, params);
    addRedeem(tx, params);
    return tx;
}

export async function executeAndWait(
    tx: Transaction,
    label = "transaction",
    gasBudget = DEFAULT_GAS_BUDGET,
): Promise<any> {
    tx.setSender(address);
    tx.setGasBudget(gasBudget);

    let execution: any;
    try {
        execution = await client.signAndExecuteTransaction({
            transaction: tx,
            signer,
            options: SETUP_RESPONSE_OPTIONS,
        });
    } catch (error) {
        let dryRunSummary = "";
        try {
            const bytes = await tx.build({ client });
            const dryRun = await client.dryRunTransactionBlock({ transactionBlock: bytes });
            dryRunSummary = ` dryRun=${JSON.stringify(dryRun).slice(0, 1000)}`;
        } catch (dryRunError) {
            dryRunSummary = ` dryRun_error=${String(dryRunError)}`;
        }
        throw new Error(`${label} rpc failure: ${String(error)}${dryRunSummary}`);
    }

    const status = (execution as any).effects?.status;
    if (!isSuccessStatus(status)) {
        throw new Error(
            `${label} failed: ${formatStatusError(status, JSON.stringify(execution).slice(0, 300))}`,
        );
    }

    return getTransactionBlockWithRetry(execution.digest);
}

const EXECUTE_MAX_ATTEMPTS = 5;
const EXECUTE_RETRY_DELAY_MS = 1000;

export async function execute(
    buildTx: Transaction | (() => Transaction | Promise<Transaction>),
    label = "transaction",
): Promise<ExecutionReceipt> {
    let lastError: unknown;
    for (let attempt = 0; attempt < EXECUTE_MAX_ATTEMPTS; attempt++) {
        try {
            // Build a fresh transaction on each attempt so object versions are re-resolved.
            const tx = typeof buildTx === "function" ? await buildTx() : buildTx;
            tx.setSender(address);
            tx.setGasBudget(DEFAULT_GAS_BUDGET);

            const raw: any = await client.signAndExecuteTransaction({
                transaction: tx,
                signer,
                options: EXECUTION_RESPONSE_OPTIONS,
            });

            const status = raw.effects?.status;
            if (!isSuccessStatus(status)) {
                throw new Error(
                    `${label} failed: ${formatStatusError(status, JSON.stringify(raw).slice(0, 300))}`,
                );
            }

            const settled = await getTransactionBlockWithRetry(raw.digest);
            return {
                digest: raw.digest,
                gas: gasSummaryFromEffects(settled.effects ?? raw.effects),
                events: settled.events ?? raw.events ?? [],
                objectChanges: settled.objectChanges ?? raw.objectChanges ?? [],
                effects: settled.effects ?? raw.effects,
            };
        } catch (error) {
            lastError = error;
            const msg = String(error);
            // Retry on transient object version / input errors.
            if (msg.includes("Object ID") || msg.includes("TransactionExecutionClientError")) {
                if (attempt < EXECUTE_MAX_ATTEMPTS - 1) {
                    const delay = EXECUTE_RETRY_DELAY_MS * (attempt + 1);
                    process.stdout.write(
                        `[retry] ${label} attempt ${attempt + 1} failed, retrying in ${delay}ms...\n`,
                    );
                    await new Promise((r) => setTimeout(r, delay));
                    continue;
                }
            }
            throw error;
        }
    }
    throw lastError;
}
