// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Workshop step 6 (LP demo): redeem PLP shares back to DUSDC via predict::withdraw.
//
// By default the script auto-discovers the active address's PLP coin(s),
// merges them, and burns the entire balance. Override PLP_COIN in CONFIG (or
// as an env var) to burn a specific coin, or set AMOUNT to burn only part.

import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner } from '../../utils/utils.js';
import {
	dusdcPackageID,
	predictObjectID,
	predictPackageID,
} from '../../config/constants.js';

// === Optional overrides =============================================
// PLP_COIN: null  → auto-find the LP's PLP coin(s) and burn them.
// AMOUNT:   null  → burn the full balance. Set a number (PLP units, ×1e6)
//                   to burn only part.
const CONFIG = {
	PLP_COIN: null as string | null,
	AMOUNT:   null as number | null,
};
// Env vars PLP_COIN / AMOUNT override CONFIG.
// ====================================================================

const network = 'testnet' as const;
const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;
const PLP_TYPE = `${predictPackageID[network]}::plp::PLP`;
const CLOCK = '0x6';
const PLP_SCALE = 1_000_000n;

(async () => {
	const client = getClient(network);
	const signer = getSigner();
	const address = getActiveAddress();

	const plpCoinOverride = process.env.PLP_COIN ?? CONFIG.PLP_COIN;
	const amountUnits = process.env.AMOUNT
		? BigInt(process.env.AMOUNT)
		: CONFIG.AMOUNT === null
			? null
			: BigInt(CONFIG.AMOUNT);

	const tx = new Transaction();
	let coinArg;
	let burnLabel: string;

	if (plpCoinOverride) {
		// Explicit coin id supplied. Split AMOUNT off it, or burn whole.
		const amountScaled = amountUnits === null ? null : amountUnits * PLP_SCALE;
		coinArg = amountScaled === null
			? tx.object(plpCoinOverride)
			: tx.splitCoins(tx.object(plpCoinOverride), [tx.pure.u64(amountScaled)]);
		burnLabel = amountScaled === null
			? `entire balance of ${plpCoinOverride}`
			: `${amountUnits} PLP from ${plpCoinOverride}`;
	} else {
		// Auto-discover PLP coins owned by the active address.
		const coins = await client.getCoins({ owner: address, coinType: PLP_TYPE });
		if (coins.data.length === 0) {
			console.error(`No PLP coins found for ${address}. Run pnpm predict-deposit first.`);
			process.exit(1);
		}
		const total = coins.data.reduce((s, c) => s + BigInt(c.balance), 0n);

		const primary = tx.object(coins.data[0].coinObjectId);
		if (coins.data.length > 1) {
			tx.mergeCoins(
				primary,
				coins.data.slice(1).map((c) => tx.object(c.coinObjectId)),
			);
		}

		if (amountUnits === null) {
			coinArg = primary;
			burnLabel = `entire balance (${Number(total) / 1e6} PLP across ${coins.data.length} coin${coins.data.length === 1 ? '' : 's'})`;
		} else {
			const amountScaled = amountUnits * PLP_SCALE;
			if (total < amountScaled) {
				console.error(`Insufficient PLP: have ${Number(total) / 1e6}, need ${amountUnits}`);
				process.exit(1);
			}
			coinArg = tx.splitCoins(primary, [tx.pure.u64(amountScaled)]);
			burnLabel = `${amountUnits} PLP (of ${Number(total) / 1e6} held)`;
		}
	}

	console.log(`LP:    ${address}`);
	console.log(`Burn:  ${burnLabel}\n`);

	const dusdcOut = tx.moveCall({
		target: `${predictPackageID[network]}::predict::withdraw`,
		typeArguments: [DUSDC_TYPE],
		arguments: [tx.object(predictObjectID[network]), coinArg as any, tx.object(CLOCK)],
	});
	tx.transferObjects([dusdcOut], tx.pure.address(address));

	const result = await client.signAndExecuteTransaction({
		transaction: tx,
		signer,
		options: { showEffects: true, showEvents: true },
	});

	if (result.effects?.status.status !== 'success') {
		console.error('withdraw failed:', result.effects?.status);
		process.exit(1);
	}

	const withdrawn = result.events?.find((e) => e.type.endsWith('::predict::Withdrawn'));
	if (withdrawn) {
		console.log('Withdrawn event:');
		console.dir(withdrawn.parsedJson, { depth: null });
	}
	console.log(`\nDigest: ${result.digest}`);
})();
