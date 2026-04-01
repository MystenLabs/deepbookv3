// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

import { execFileSync, execSync } from 'child_process';
import { readFileSync } from 'fs';
import { homedir } from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { getJsonRpcFullnodeUrl, SuiJsonRpcClient } from '@mysten/sui/jsonRpc';
import { decodeSuiPrivateKey } from '@mysten/sui/cryptography';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Secp256k1Keypair } from '@mysten/sui/keypairs/secp256k1';
import { Secp256r1Keypair } from '@mysten/sui/keypairs/secp256r1';
import { Transaction } from '@mysten/sui/transactions';
import { fromBase64, normalizeSuiAddress } from '@mysten/sui/utils';

type Network = 'mainnet' | 'testnet' | 'devnet' | 'localnet';

interface BuiltMovePackage {
	modules: string[];
	dependencies: string[];
	digest?: string;
}

const SUI = process.env.SUI_BINARY ?? 'sui';
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const network: Network = 'mainnet';
const mvrPackageName = process.env.DEEPBOOK_MVR_PACKAGE_NAME ?? '@deepbook/core';
const packagePath = path.resolve(__dirname, '..');
const deepbookPublishedPath = path.resolve(__dirname, '../../deepbook/Published.toml');
const dryRun = process.argv.includes('--dry-run');

function getActiveAddress() {
	return execSync(`${SUI} client active-address`, { encoding: 'utf8' }).trim();
}

function getSigner() {
	if (process.env.PRIVATE_KEY) {
		console.log('Using supplied private key.');
		const { schema, secretKey } = decodeSuiPrivateKey(process.env.PRIVATE_KEY);

		if (schema === 'ED25519') return Ed25519Keypair.fromSecretKey(secretKey);
		if (schema === 'Secp256k1') return Secp256k1Keypair.fromSecretKey(secretKey);
		if (schema === 'Secp256r1') return Secp256r1Keypair.fromSecretKey(secretKey);

		throw new Error('Keypair not supported.');
	}

	const sender = getActiveAddress();
	const keystore = JSON.parse(
		readFileSync(path.join(homedir(), '.sui', 'sui_config', 'sui.keystore'), 'utf8'),
	);

	for (const priv of keystore) {
		const raw = fromBase64(priv);
		if (raw[0] !== 0) {
			continue;
		}

		const pair = Ed25519Keypair.fromSecretKey(raw.slice(1));
		if (pair.getPublicKey().toSuiAddress() === sender) {
			return pair;
		}
	}

	throw new Error(`keypair not found for sender: ${sender}`);
}

function getClient(network: Network) {
	const url = process.env.RPC_URL || getJsonRpcFullnodeUrl(network);
	const mvrUrl =
		network === 'mainnet'
			? 'https://mainnet.mvr.mystenlabs.com'
			: network === 'testnet'
				? 'https://testnet.mvr.mystenlabs.com'
				: undefined;

	return new SuiJsonRpcClient({
		url,
		network,
		mvr: mvrUrl ? { url: mvrUrl } : undefined,
	});
}

function buildMovePackage(packagePath: string, buildEnv: Network): BuiltMovePackage {
	const command = [
		'move',
		'build',
		'--dump-bytecode-as-base64',
		'--build-env',
		buildEnv,
		'--path',
		packagePath,
	];

	return JSON.parse(
		execFileSync(SUI, command, {
			encoding: 'utf-8',
		}),
	) as BuiltMovePackage;
}

function publishPackage(transaction: Transaction, packagePath: string, buildEnv: Network) {
	const { modules, dependencies } = buildMovePackage(packagePath, buildEnv);
	const cap = transaction.publish({
		modules,
		dependencies,
	});
	const sender = transaction.moveCall({
		target: `0x2::tx_context::sender`,
	});

	transaction.transferObjects([cap], sender);

	return { modules, dependencies };
}

function readPublishedAddress(tomlPath: string, env: Network) {
	const contents = readFileSync(tomlPath, 'utf8');
	const section = new RegExp(
		String.raw`\[published\.${env}\][\s\S]*?published-at = "([^"]+)"`,
	).exec(contents);

	if (!section?.[1]) {
		throw new Error(`Failed to find published-at for ${env} in ${tomlPath}`);
	}

	return normalizeSuiAddress(section[1]);
}

function getPublishedPackageId(result: {
	objectChanges?: Array<{ type: string; packageId?: string }>;
}) {
	return result.objectChanges?.find((change) => change.type === 'published')?.packageId;
}

function getUpgradeCapId(result: {
	objectChanges?: Array<{ type: string; objectType?: string; objectId?: string }>;
}) {
	return result.objectChanges?.find(
		(change) =>
			change.type === 'created' &&
			change.objectType === '0x2::package::UpgradeCap',
	)?.objectId;
}

(async () => {
	const client = getClient(network);
	const signer = getSigner();

	const resolvedDeepbook = normalizeSuiAddress(
		(await client.mvr.resolvePackage({ package: mvrPackageName })).package,
	);
	const expectedDeepbook = readPublishedAddress(deepbookPublishedPath, network);

	if (resolvedDeepbook !== expectedDeepbook) {
		throw new Error(
			[
				`MVR resolved ${mvrPackageName} to ${resolvedDeepbook},`,
				`but packages/deepbook/Published.toml pins mainnet to ${expectedDeepbook}.`,
				`Refresh main before publishing so the wrapper compiles against the current DeepBook package.`,
			].join(' '),
		);
	}

	const built = buildMovePackage(packagePath, network);
	const normalizedDependencies = new Set(
		built.dependencies.map((dependency) => normalizeSuiAddress(dependency)),
	);

	if (!normalizedDependencies.has(expectedDeepbook)) {
		throw new Error(
			`Wrapper build dependencies do not include DeepBook mainnet package ${expectedDeepbook}.`,
		);
	}

	console.log(
		JSON.stringify(
			{
				network,
				deepbookMvrName: mvrPackageName,
				deepbookPackage: expectedDeepbook,
				wrapperPackagePath: packagePath,
				mode: dryRun ? 'dry-run' : 'publish',
			},
			null,
			2,
		),
	);

	if (dryRun) {
		return;
	}

	const transaction = new Transaction();
	transaction.setGasBudget(200_000_000);
	transaction.setSender(signer.toSuiAddress());

	publishPackage(transaction, packagePath, network);

	const result = await client.signAndExecuteTransaction({
		transaction,
		signer,
		options: {
			showEffects: true,
			showObjectChanges: true,
		},
	});

	if (result.effects?.status.status !== 'success') {
		throw new Error(`Publish failed: ${result.effects?.status.error ?? 'unknown error'}`);
	}

	console.log(
		JSON.stringify(
			{
				digest: result.digest,
				packageId: getPublishedPackageId(result),
				upgradeCapId: getUpgradeCapId(result),
				deepbookPackage: expectedDeepbook,
			},
			null,
			2,
		),
	);
})().catch((error: unknown) => {
	console.error(error);
	process.exitCode = 1;
});
