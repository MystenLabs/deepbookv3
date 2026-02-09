// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { execSync, spawn, ChildProcess } from 'child_process';
import { Transaction } from '@mysten/sui/transactions';
import { getActiveAddress, getClient, getSigner } from '../utils/utils';
import path from 'path';

const FULLNODE_URL = 'http://127.0.0.1:9000';
const FAUCET_URL = 'http://127.0.0.1:9123/gas';
const PREDICT_PATH = path.resolve(__dirname, '../../packages/predict');
const POLL_INTERVAL_MS = 1000;
const STARTUP_TIMEOUT_MS = 60_000;

let localnetProcess: ChildProcess | null = null;

function cleanup() {
	if (localnetProcess) {
		console.log('\nShutting down localnet...');
		localnetProcess.kill('SIGTERM');
		localnetProcess = null;
	}
}

process.on('SIGINT', () => {
	cleanup();
	process.exit(0);
});
process.on('exit', cleanup);

async function waitForLocalnet(): Promise<void> {
	const start = Date.now();
	while (Date.now() - start < STARTUP_TIMEOUT_MS) {
		try {
			const res = await fetch(FULLNODE_URL, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ jsonrpc: '2.0', method: 'sui_getLatestCheckpointSequenceNumber', id: 1 }),
			});
			if (res.ok) return;
		} catch {
			// not ready yet
		}
		await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
	}
	throw new Error(`Localnet did not start within ${STARTUP_TIMEOUT_MS / 1000}s`);
}

function startLocalnet(): ChildProcess {
	console.log('Starting localnet...');
	const child = spawn('sui', ['start', '--with-faucet', '--force-regenesis'], {
		stdio: 'ignore',
		detached: true,
	});
	child.unref();
	return child;
}

function configureClient() {
	try {
		execSync('sui client new-env --alias local --rpc http://127.0.0.1:9000', {
			stdio: 'ignore',
		});
	} catch {
		// env may already exist
	}
	execSync('sui client switch --env local', { stdio: 'ignore' });
	console.log('Switched to local env');
}

async function waitForFaucet(): Promise<void> {
	console.log('Waiting for faucet...');
	const start = Date.now();
	while (Date.now() - start < STARTUP_TIMEOUT_MS) {
		try {
			const res = await fetch(FAUCET_URL, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
			// Any response (even 4xx) means faucet is up
			return;
		} catch {
			// not ready yet
		}
		await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
	}
	throw new Error(`Faucet did not start within ${STARTUP_TIMEOUT_MS / 1000}s`);
}

async function fundAddress(address: string) {
	console.log(`Requesting faucet funds for ${address}...`);
	const res = await fetch(FAUCET_URL, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ FixedAmountRequest: { recipient: address } }),
	});
	if (!res.ok) throw new Error(`Faucet request failed: ${res.statusText}`);
	console.log('Faucet funded successfully');
}

(async () => {
	// 1. Start localnet
	localnetProcess = startLocalnet();
	await waitForLocalnet();
	console.log('Localnet RPC is ready');
	await waitForFaucet();
	console.log('Faucet is ready');

	// 2. Configure client
	configureClient();

	// 3. Fund deployer
	const address = getActiveAddress();
	console.log(`Active address: ${address}`);
	await fundAddress(address);

	// Wait a moment for funds to be available
	await new Promise((r) => setTimeout(r, 2000));

	// 4. Publish predict package via test-publish
	// Remove stale ephemeral pub files from previous localnet runs
	const repoRoot = path.resolve(__dirname, '../..');
	try { execSync(`find ${repoRoot} -name "Pub.local.toml" -delete`, { stdio: 'ignore' }); } catch {}

	console.log('\nPublishing predict package...');
	const publishOutput = execSync(
		`sui client test-publish --with-unpublished-dependencies --json --skip-dependency-verification --build-env local ${PREDICT_PATH}`,
		{ encoding: 'utf-8', maxBuffer: 10 * 1024 * 1024 },
	);
	const publishResult = JSON.parse(publishOutput);

	if (publishResult.effects?.status?.status !== 'success') {
		console.error('Publish failed:', publishResult.effects?.status);
		process.exit(1);
	}

	// 5. Parse created objects
	const objectChanges = publishResult.objectChanges ?? [];
	const created = objectChanges.filter((c: any) => c.type === 'created');
	const published = objectChanges.filter((c: any) => c.type === 'published');

	let registryId = '';
	let adminCapId = '';
	let predictPackageId = '';

	for (const obj of created) {
		if (obj.objectType?.includes('::registry::Registry')) registryId = obj.objectId;
		if (obj.objectType?.includes('::registry::AdminCap')) adminCapId = obj.objectId;
	}

	for (const p of published) {
		if (p.modules?.some((m: string) => m === 'registry')) {
			predictPackageId = p.packageId;
		}
	}

	console.log('\n=== Published Packages ===');
	for (const p of published) {
		console.log(`  Package: ${p.packageId} (modules: ${p.modules?.join(', ')})`);
	}
	console.log('\n=== Created Objects ===');
	console.log(`  Registry: ${registryId}`);
	console.log(`  AdminCap: ${adminCapId}`);

	if (!registryId || !adminCapId || !predictPackageId) {
		console.error('Missing required objects from publish');
		process.exit(1);
	}

	// 6. Post-publish setup: create_predict<SUI>
	console.log('\nCreating Predict<SUI> object...');
	const client = getClient('localnet');
	const signer = getSigner();

	const setupTx = new Transaction();
	setupTx.moveCall({
		target: `${predictPackageId}::registry::create_predict`,
		typeArguments: ['0x2::sui::SUI'],
		arguments: [setupTx.object(registryId), setupTx.object(adminCapId)],
	});

	const setupResult = await client.signAndExecuteTransaction({
		transaction: setupTx,
		signer,
		options: {
			showEffects: true,
			showObjectChanges: true,
		},
	});

	if (setupResult.effects?.status.status !== 'success') {
		console.error('Setup failed:', setupResult.effects?.status);
		process.exit(1);
	}

	let predictId = '';
	const setupCreated = setupResult.objectChanges?.filter((c) => c.type === 'created') ?? [];
	for (const obj of setupCreated) {
		if (obj.type !== 'created') continue;
		if (obj.objectType.includes('::predict::Predict')) {
			predictId = obj.objectId;
		}
	}

	console.log(`  Predict<SUI>: ${predictId}`);

	// 7. Print summary
	console.log('\n========== DEPLOYMENT SUMMARY ==========');
	console.log(`Package ID:   ${predictPackageId}`);
	console.log(`Registry:     ${registryId}`);
	console.log(`AdminCap:     ${adminCapId}`);
	console.log(`Predict<SUI>: ${predictId}`);
	console.log(`Deployer:     ${address}`);
	console.log('=========================================');
	console.log('\nLocalnet running. Press Ctrl+C to stop.');

	// Keep process alive
	await new Promise(() => {});
})();
