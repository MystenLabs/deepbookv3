// Live-testnet smoke suite — the SDK's first contact with the real deployment.
// Network-gated: runs only under `pnpm test:testnet` (PREDICT_SDK_TESTNET=1).
//
// What this proves that the offline suite cannot:
//  1. The real gRPC SimulateTransactionResult shape matches what reads/inspect.ts
//     codes against (commandResults[i].returnValues[j].bcs).
//  2. Every config object id resolves on chain (a read returning data uses the
//     registry, pool vault, feeds, protocol config, and the DUSDC coin type).
//  3. The arity guard: our mint/redeem builders execute against the DEPLOYED
//     entrypoints far enough that any failure is a semantic Move abort — never a
//     VM verification / argument-arity error. This detects deployed-surface
//     signature drift (argument count/type). It cannot detect swaps between
//     same-typed arguments; those are pinned by the offline slot tests.
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";
import { describe, expect, test } from "vitest";
import {
	PredictClient,
	PredictMoveError,
	TESTNET_CONFIG,
	accountTarget,
	mintExactQuantity,
	redeemLive,
} from "../../src/index.js";

const TESTNET_GRPC_URL = "https://fullnode.testnet.sui.io:443";

// A fixed, arbitrary sender for dry-runs. Deliberately not the zero address so
// `account_registry::new` derives a wrapper id no real user owns.
const SMOKE_SENDER = "0x51de1e01c51dc51dc51dc51dc51dc51dc51dc51dc51dc51dc51dc51dc51dc51d";

const cfg = TESTNET_CONFIG;
const client = new SuiGrpcClient({ network: "testnet", baseUrl: TESTNET_GRPC_URL });
const predict = new PredictClient({ network: "testnet", client });

// Shared across tests (vitest runs a file's tests sequentially by default).
let liveMarkets: Awaited<ReturnType<typeof predict.read.markets>> = [];

// Build a PTB that creates a FRESH AccountWrapper and threads it straight into a
// trade builder, then shares it. The facade derives wrapper ids for existing
// accounts, which a throwaway sender does not have — simulation would then fail at
// input resolution, before the VM ever checks the call's arity. Creating the
// wrapper in-PTB guarantees execution reaches the deployed Move entrypoint.
// `tx.object()` passes a result handle through unchanged, so the primitives accept
// it at runtime; the cast bridges their string-typed wrapperId.
function freshWrapperTx(): { tx: Transaction; wrapper: string } {
	const tx = new Transaction();
	const wrapper = tx.moveCall({
		target: accountTarget(cfg, "account_registry", "new"),
		arguments: [tx.object(cfg.objects.accountRegistry)],
	});
	return { tx, wrapper: wrapper as unknown as string };
}

function shareWrapper(tx: Transaction, wrapper: string): void {
	tx.moveCall({
		target: accountTarget(cfg, "account", "share"),
		arguments: [tx.object(wrapper)],
	});
}

// Simulate and classify the failure. Returns null on success, the error otherwise.
async function simulate(tx: Transaction): Promise<unknown> {
	tx.setSender(SMOKE_SENDER);
	try {
		const result = await client.simulateTransaction({
			transaction: tx,
			checksEnabled: false,
		});
		return result.$kind === "FailedTransaction" ? result.FailedTransaction : null;
	} catch (e) {
		return e;
	}
}

// The guard: a failure is acceptable only if it is a semantic Move abort (or a
// typed PredictMoveError our own plumbing decoded). Arity/type drift surfaces as
// VMVerificationOrDeserializationError / CommandArgumentError instead — fail loud.
function expectSemanticOrSuccess(outcome: unknown, label: string): void {
	if (outcome === null) return; // full success is also proof of matching arity
	const text =
		outcome instanceof PredictMoveError
			? `MoveAbort:${outcome.module}:${outcome.code}`
			: JSON.stringify(outcome, (_, v) => (typeof v === "bigint" ? v.toString() : v));
	expect(text, `${label}: expected semantic Move abort, got: ${text}`).not.toMatch(
		/VMVerificationOrDeserialization|CommandArgumentError|InvalidPublicFunctionReturnType|arity|number of arguments/i,
	);
	expect(text, `${label}: expected a Move abort, got: ${text}`).toMatch(/MoveAbort/i);
}

describe("testnet smoke (live deployment)", () => {
	test("read.markets() — tradeable summaries, simulate plumbing end-to-end", async () => {
		liveMarkets = await predict.read.markets();
		expect(Array.isArray(liveMarkets)).toBe(true);
		for (const m of liveMarkets) {
			expect(m.id).toMatch(/^0x[0-9a-f]{64}$/);
			expect(m.expiryMs > 0n).toBe(true);
			expect(m.tickSize).toBeGreaterThan(0);
			expect(typeof m.mintPaused).toBe("boolean");
			// Option parse validated live: unset → null, seeded → a positive USD price.
			if (m.referencePrice !== null) expect(m.referencePrice).toBeGreaterThan(0);
		}
	});

	test("read.pool() — pool objects resolve, pool is bootstrapped", async () => {
		const pool = await predict.read.pool();
		expect(pool.plpTotalSupply > 0n).toBe(true);
		expect(pool.idleUsdc).toBeGreaterThanOrEqual(0);
		expect(pool.supplyPending).toBeGreaterThanOrEqual(0);
		expect(pool.withdrawPending).toBeGreaterThanOrEqual(0);
	});

	test("registry mapping agrees with the summary for a live market", async () => {
		if (liveMarkets.length === 0) return; // no live expiry right now — skip
		const m = liveMarkets[0];
		// BTC is the only registered underlying on testnet, so the registry must map
		// (BTC, this expiry) back to this exact market object.
		const summary = await predict.read.market({ underlying: "BTC", expiryMs: m.expiryMs });
		expect(summary?.id).toBe(m.id);
		expect(summary!.nav).toBeGreaterThanOrEqual(0);
		expect(summary!.tickSize).toBe(m.tickSize);
	});

	test("arity guard: mint_exact_quantity matches the deployed surface", async () => {
		if (liveMarkets.length === 0) return;
		const id = liveMarkets[0].id;
		const { tx, wrapper } = freshWrapperTx();
		mintExactQuantity(cfg, tx, {
			expiryMarketId: id,
			wrapperId: wrapper,
			// tick 1_000 is deep in the finite domain for any sane tick size
			lowerTick: 1_000n,
			higherTick: 1_001n,
			quantityRaw: 1_000_000n, // $1 payout, 100 lots
			leverageRaw: 1_000_000_000n, // 1x
			...predictFeeds(),
		});
		shareWrapper(tx, wrapper);
		expectSemanticOrSuccess(await simulate(tx), `mint on ${id}`);
	});

	test("arity guard: redeem_live matches the deployed surface", async () => {
		if (liveMarkets.length === 0) return;
		const { tx, wrapper } = freshWrapperTx();
		redeemLive(cfg, tx, {
			expiryMarketId: liveMarkets[0].id,
			wrapperId: wrapper,
			orderId: 1n, // no such order for a fresh account — semantic abort expected
			closeQuantityRaw: 10_000n,
			...predictFeeds(),
		});
		shareWrapper(tx, wrapper);
		expectSemanticOrSuccess(await simulate(tx), "redeem_live");
	});

	test("read.price: live both-sides pricing for a grid strike", async () => {
		if (liveMarkets.length === 0) return;
		const m = liveMarkets[0];
		// A deep-ITM-for-UP strike: 1000 ticks above zero — any grid point works,
		// the assertion is on plumbing + probability domain, not on moneyness.
		const strike = m.tickSize * 1_000;
		const p = await predict.read.price({
			underlying: "BTC",
			expiryMs: m.expiryMs,
			strike,
		});
		expect(p.up).toBeGreaterThanOrEqual(0);
		expect(p.up).toBeLessThanOrEqual(1);
		expect(p.down).toBeGreaterThanOrEqual(0);
		expect(p.down).toBeLessThanOrEqual(1);
		// Complementary within chain rounding.
		expect(Math.abs(p.up + p.down - 1)).toBeLessThan(0.05);
	});

	test("read.quoteMint: unfunded owner fails as a typed semantic abort (preflight)", async () => {
		if (liveMarkets.length === 0) return;
		const m = liveMarkets[0];
		// SMOKE_SENDER never onboarded, so its derived wrapper doesn't exist:
		// the dry-run fails at input resolution ("Object 0x… " from the node) —
		// while a funded-but-broke owner would surface a typed Move abort. Either
		// way the quote fails EXACTLY like the real trade would (preflight), and
		// this proves the build → simulate-with-events → error path live.
		await expect(
			predict.read.quoteMint(
				SMOKE_SENDER,
				{ underlying: "BTC", expiryMs: m.expiryMs, strike: m.tickSize * 1_000, side: "up" },
				{ quantity: 1 },
			),
		).rejects.toThrow(/Object|Move abort|aborted|not found|no market/i);
	});

	test("createManager simulates clean AND its real event decodes", async () => {
		const tx = predict.tx.createManager();
		tx.setSender(SMOKE_SENDER);
		// include events: this validates decode.createManager against a REAL
		// emitted event (BCS layout, type matching, byte handling) — the live
		// anchor for the decoder layer's field-order assumptions.
		const result = await client.simulateTransaction({
			transaction: tx,
			checksEnabled: false,
			include: { events: true },
		});
		expect(result.$kind).toBe("Transaction"); // fresh sender: create+share succeeds
		const receipt = predict.decode.createManager({
			events: result.Transaction?.events ?? [],
		});
		expect(receipt.owner).toBe(SMOKE_SENDER);
		// The decoded on-chain wrapper id must equal the client-side derivation.
		expect(receipt.wrapperId).toBe(predict.wrapperIdFor(SMOKE_SENDER));
	});
});

function predictFeeds() {
	const u = cfg.underlyings.BTC;
	return {
		pythFeedId: u.pythFeedId,
		bsSpotFeedId: u.bsSpotFeedId,
		bsForwardFeedId: u.bsForwardFeedId,
		bsSviFeedId: u.bsSviFeedId,
	};
}
