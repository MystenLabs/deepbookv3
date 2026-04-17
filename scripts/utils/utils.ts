// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { execFileSync } from 'child_process';
import fs, { readFileSync } from 'fs';
import { homedir } from 'os';
import path from 'path';
import { getJsonRpcFullnodeUrl, SuiJsonRpcClient } from '@mysten/sui/jsonRpc';
import { decodeSuiPrivateKey } from '@mysten/sui/cryptography';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Secp256k1Keypair } from '@mysten/sui/keypairs/secp256k1';
import { Secp256r1Keypair } from '@mysten/sui/keypairs/secp256r1';
import { Transaction } from '@mysten/sui/transactions';
import { fromBase64, toBase64 } from '@mysten/sui/utils';

export type Network = 'mainnet' | 'testnet' | 'devnet' | 'localnet';

type ResolveSuiBinaryOptions = {
	envBinary?: string;
	candidates?: string[];
	getVersion?: (binary: string) => string | null;
};

const parseSuiVersion = (raw: string): [number, number, number] | null => {
	const match = raw.match(/sui\s+(\d+)\.(\d+)\.(\d+)/i);
	if (!match) return null;
	return [Number(match[1]), Number(match[2]), Number(match[3])];
};

const compareSuiVersions = (
	left: [number, number, number],
	right: [number, number, number],
): number => {
	for (let i = 0; i < left.length; i += 1) {
		if (left[i] !== right[i]) return left[i] - right[i];
	}
	return 0;
};

export const resolveSuiBinary = ({
	envBinary = process.env.SUI_BINARY,
	candidates = [path.join(homedir(), '.local', 'bin', 'sui'), path.join(homedir(), '.cargo', 'bin', 'sui'), 'sui'],
	getVersion = (binary) => {
		try {
			return execFileSync(binary, ['--version'], { encoding: 'utf8' }).trim();
		} catch {
			return null;
		}
	},
}: ResolveSuiBinaryOptions = {}): string => {
	if (envBinary) return envBinary;

	let best: { binary: string; version: [number, number, number] } | null = null;
	for (const binary of [...new Set(candidates)]) {
		const version = getVersion(binary);
		if (!version) continue;
		const parsed = parseSuiVersion(version);
		if (!parsed) continue;
		if (!best || compareSuiVersions(parsed, best.version) > 0) {
			best = { binary, version: parsed };
		}
	}

	return best?.binary ?? 'sui';
};

const SUI = resolveSuiBinary();

export const getActiveAddress = () => {
	return execFileSync(SUI, ['client', 'active-address'], { encoding: 'utf8' }).trim();
};

/// Replace the value of `export const <name> = { ..., <network>: "..." }` in
/// a constants.ts-shaped source string. Throws if the constant's network entry
/// is missing — surfacing format drift loudly rather than silently writing an
/// empty-string ID.
export const updateConstant = (
	content: string,
	name: string,
	network: string,
	value: string,
): string => {
	const regex = new RegExp(`(export const ${name} = \\{[^}]*${network}:\\s*)"[^"]*"`);
	if (!regex.test(content)) {
		throw new Error(
			`updateConstant: no match for ${name}[${network}] in constants — check that the constant exists and the file format hasn't drifted`,
		);
	}
	return content.replace(regex, `$1"${value}"`);
};

export const publishPackage = (txb: Transaction, path: string, configPath?: string) => {
	const command = [
		'move',
		...(configPath ? ['--client.config', configPath] : []),
		'build',
		'--dump-bytecode-as-base64',
		'--path',
		path,
	];

	const { modules, dependencies } = JSON.parse(
		execFileSync(SUI, command, {
			encoding: 'utf-8',
		}),
	);

	const cap = txb.publish({
		modules,
		dependencies,
	});

	const sender = txb.moveCall({
		target: `0x2::tx_context::sender`,
	});

	// Transfer the upgrade capability to the sender so they can upgrade the package later if they want.
	txb.transferObjects([cap], sender);
};

/// Returns a signer based on the active address of system's sui.
export const getSigner = () => {
	if (process.env.PRIVATE_KEY) {
		console.log('Using supplied private key.');
		const { schema, secretKey } = decodeSuiPrivateKey(process.env.PRIVATE_KEY);

		// @mysten/sui >= 2.x stopped populating `schema` on decoded
		// `suiprivkey…` strings — default to Ed25519 when omitted.
		if (schema === undefined || schema === 'ED25519') return Ed25519Keypair.fromSecretKey(secretKey);
		if (schema === 'Secp256k1') return Secp256k1Keypair.fromSecretKey(secretKey);
		if (schema === 'Secp256r1') return Secp256r1Keypair.fromSecretKey(secretKey);

		throw new Error(`Keypair scheme not supported: ${schema}`);
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
};

/// Get the client for the specified network.
export const getClient = (network: Network) => {
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
};

/// Builds a transaction (unsigned) and saves it on `setup/tx/tx-data.txt` (on production)
/// or `setup/src/tx-data.local.txt` on mainnet.
export const prepareMultisigTx = async (
	tx: Transaction,
	network: Network,
	address?: string,
) => {
	const adminAddress = address ?? getActiveAddress();
	const client = getClient(network);
	const gasObjectId = process.env.GAS_OBJECT;

	// enabling the gas Object check only on mainnet, to allow testnet multisig tests.
	if (!gasObjectId) throw new Error('No gas object supplied for a mainnet transaction');

	// Set epoch-based expiration to avoid ValidDuring which older tools don't support.
	// Use current reference gas price with 20% buffer to account for potential RGP increases
	// between transaction generation and execution (e.g., across epoch boundaries).
	const { epoch, referenceGasPrice } = await client.getLatestSuiSystemState();
	const gasPriceWithBuffer = (BigInt(referenceGasPrice) * 120n) / 100n;
	tx.setGasPrice(gasPriceWithBuffer);
	tx.setExpiration({ Epoch: Number(epoch) + 5 });

	// set the sender to be the admin address from config.
	tx.setSender(adminAddress as string);

	// setting up gas object for the multi-sig transaction
	if (gasObjectId) await setupGasPayment(tx, gasObjectId, client);

	// first do a dryRun, to make sure we are getting a success.
	const dryRun = await inspectTransaction(tx, client);

	if (!dryRun) throw new Error('This transaction failed.');

	tx.build({
		client: client,
	}).then((bytes) => {
		let serializedBase64 = toBase64(bytes);

		const output_location =
			process.env.NODE_ENV === 'development' ? './tx/tx-data-local.txt' : './tx/tx-data.txt';

		fs.writeFileSync(output_location, serializedBase64);
	});
};

/// Fetch the gas Object and setup the payment for the tx.
async function setupGasPayment(tx: Transaction, gasObjectId: string, client: SuiJsonRpcClient) {
	const gasObject = await client.getObject({
		id: gasObjectId,
	});

	if (!gasObject.data) throw new Error('Invalid Gas Object supplied.');

	// set the gas payment.
	tx.setGasPayment([
		{
			objectId: gasObject.data.objectId,
			version: gasObject.data.version,
			digest: gasObject.data.digest,
		},
	]);
}

/// A helper to dev inspect a transaction.
async function inspectTransaction(tx: Transaction, client: SuiJsonRpcClient) {
	const result = await client.dryRunTransactionBlock({
		transactionBlock: await tx.build({ client: client }),
	});
	// log the result.
	console.dir(result, { depth: null });

	return result.effects.status.status === 'success';
}
