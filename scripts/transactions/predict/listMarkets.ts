// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Workshop step 2: discover tradeable oracles via the public indexer.
//
// Hits predict-server for the current Predict object's active oracles and
// prints a short table with the IDs / expiries / spot / strike grids. Pick one
// oracle ID and pass it to mintPosition.ts as ORACLE_ID.
//
// Usage:  pnpm predict-list-markets

import { predictObjectID } from '../../config/constants.js';

const network = 'testnet' as const;
const SERVER = process.env.PREDICT_SERVER ?? 'https://predict-server.testnet.mystenlabs.com';
const PREDICT = predictObjectID[network];

// Strikes / prices are 1e9-scaled. Quantities / DUSDC are 1e6-scaled.
const PRICE_SCALE = 1_000_000_000n;
const fmtPrice = (v: string | number | bigint | null | undefined): string => {
	if (v === null || v === undefined) return '—';
	const n = Number(BigInt(v as any)) / Number(PRICE_SCALE);
	return n.toLocaleString(undefined, { maximumFractionDigits: 2 });
};

const fmtTime = (ms: number | string): string => new Date(Number(ms)).toISOString();

const get = async (path: string) => {
	const res = await fetch(`${SERVER}${path}`);
	if (!res.ok) throw new Error(`GET ${path} → ${res.status} ${res.statusText}`);
	return res.json();
};

(async () => {
	console.log(`Server: ${SERVER}`);
	console.log(`Predict: ${PREDICT}\n`);

	const status = await get('/status');
	console.log(`Server status: ${status.status ?? 'unknown'}\n`);

	const oracles = await get(`/predicts/${PREDICT}/oracles`);
	const all: any[] = Array.isArray(oracles) ? oracles : (oracles.oracles ?? []);

	// Tradeable = status active, not yet expired, no settlement price.
	const now = Date.now();
	const tradeable = all
		.filter((o) => o.status === 'active' && Number(o.expiry) > now && o.settlement_price == null)
		.sort((a, b) => Number(a.expiry) - Number(b.expiry));

	const limit = Number(process.env.LIMIT ?? 10);
	console.log(`Tradeable oracles (${tradeable.length} of ${all.length}, showing first ${limit}):`);
	for (const o of tradeable.slice(0, limit)) {
		console.log(
			`  • ${o.underlying_asset}  exp=${fmtTime(o.expiry)}  min_strike=$${fmtPrice(o.min_strike)}  oracle=${o.oracle_id}`,
		);
	}

	const first = tradeable[0];
	if (!first) {
		console.log('\nNo tradeable oracles found.');
		return;
	}

	const targetId = process.env.ORACLE_ID ?? first.oracle_id;
	console.log(`\nDetail for oracle ${targetId}:`);
	const state = await get(`/oracles/${targetId}/state`);
	const o = state.oracle ?? {};
	const p = state.latest_price ?? {};
	console.log(`  underlying:   ${o.underlying_asset}`);
	console.log(`  status:       ${o.status ?? '?'}`);
	console.log(`  expiry (ms):  ${o.expiry}  (${fmtTime(o.expiry)})`);
	console.log(`  spot:         ${fmtPrice(p.spot)}`);
	console.log(`  forward:      ${fmtPrice(p.forward)}`);
	console.log(`  min strike:   $${fmtPrice(o.min_strike)}`);
	console.log(`  tick size:    ${o.tick_size}  (raw, 1e9-scaled)`);
	if (state.latest_svi) {
		console.log(`  svi:          a=${state.latest_svi.a}, b=${state.latest_svi.b}, sigma=${state.latest_svi.sigma}`);
	}

	console.log('\nExport for the next scripts:');
	console.log(`  export ORACLE_ID=${targetId}`);
	console.log(`  export EXPIRY=${o.expiry}`);
	const sampleStrike = p.spot ? (BigInt(p.spot) / 1_000_000_000n) * 1_000_000_000n : null;
	if (sampleStrike) {
		console.log(`  export STRIKE=${sampleStrike}     # near-the-money, 1e9-scaled (~$${fmtPrice(sampleStrike)})`);
	}
})();
