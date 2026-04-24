// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { Transaction } from '@mysten/sui/transactions';
import { getClient, getSigner } from '../utils/utils.js';

const DEEPBOOK_PACKAGE_ID = '0x337f4f4f6567fcd778d5454f27c16c70e2f274cc6377ea6249ddf491482ef497';
const REGISTRY_ID = '0xaf16199a2dff736e9f07a845f23c5da6df6f756eddb631aed9d24a93efc4549d';
const SIGNER = process.env.SIGNER;
const GAS_OBJECT = process.env.GAS_OBJECT;
if (!SIGNER) throw new Error('set SIGNER env var to the sender address');
if (!GAS_OBJECT) throw new Error('set GAS_OBJECT env var to a SUI coin object id owned by SIGNER');

const POOL_IDS = [
	'0xb04a92daba7e164a0eb31d13f642d3de50233b07c09637698de6ee376beb5c4a',
	'0xe27e7b52677f2d20b2a3b51b14e4435307a2376f150a1341dd7d4c6ffe22173e',
	'0x38df72f5d07607321d684ed98c9a6c411c0b8968e100a1cd90a996f912cd6ce1',
	'0xd5b08fe0efd6d14cf6505648b8d7e0a7a1efcf6cbee36f83395a7fed05943e83',
	'0x826eeacb2799726334aa580396338891205a41cf9344655e526aae6ddd5dc03f',
	'0xa374264d43e6baa5aa8b35ff18ff24fdba7443b4bcb884cb4c2f568d32cdac36',
	'0xe8df0f4cd06474abf255b3d38f169dc0c89b7577eac8e1af5a9be9504f9526a8',
	'0x657d1b49d42597026378479189488625a070f40b70896683ab771985079f86a7',
	'0x0fac1cebf35bde899cd9ecdd4371e0e33f44ba83b8a2902d69186646afa3a94b',
	'0x034f3a42e7348de2084406db7a725f9d9d132a56c68324713e6e623601fb4fd7',
	'0x72f50a7e6504a7e3f500005d433d0bb5ed6321c6120dc29494014a2505506e27',
	'0x4fcc828be2dd06d5ec6eb7c8e86f146cca3561e54f8ba660029df8b95b02153a',
	'0xf64045e593847ded7092c5cbf4cebd4c7ebcb99237eeb1d5052fd9a87f948d74',
	'0xc4679cda605c3666c3495ef46224624f96d96d9a8615c11f3d0e9621e43b3864',
	'0x131915283f66ee01c091ffd4cc7f0929629b5cd002781db4bffa0eab0cda0025',
	'0x52acd4eea6268aec52e79ddebe0a0772ba24b39d4a28aad18cec74779143e1f4',
	'0xf5142aafa24866107df628bf92d0358c7da6acc46c2f10951690fd2b8570f117',
	'0xc5d273ffede9df4b1b3834dbf67e80f9e8342f659135114339f25ebb5d28a2c6',
	'0xc3a83e354d10a479c625c9f4d0350489ac70d57e7ab601b8e721ff15ee2297a1',
	'0xe8694612e55d6364f3b445b6a646b12d922d481c9b8187a67a64a101f55bb2dc',
	'0x23ca00902c036cdf5b51e18739adcad8b53e52bb9c216c600a1bec0da5a6c5c3',
	'0x08ffec0151b486a24392d4f347deec02c821d67d6fa4025fc8257e8d303c76fd',
	'0xb29ef56b98a330d30d1e43d814d0a7fa30d12197ef7deff90cb4f3ffd832bbc6',
	'0x9bf0ca7d09e3860f63e6cf578bc4d284e89441ba2e76ecded3e6490970aa086f',
	'0x2ce044e7b1ea9eeeb35322306b2d797cb364df68161130fc4059eca91ff87108',
	'0xe7901612eb1b2797af6e3b26c843d098f23e75079ebde629b4017e82f94daa31',
	'0x792a73d9ef9f799a1f6f18db79ad4c52471f1c3f3cafd99323791eab3396e64c',
	'0x4937ae6d2d141ffee103066a74f4f5f0e32ba1bf701b0d65941f583141241fe9',
	'0xfc28a2fb22579c16d672a1152039cbf671e5f4b9f103feddff4ea06ef3c2bc25',
	'0x620f184bfe506da914133a9385f38b2391a3c5336489df61609152642b84d48a',
	'0xe102e2571ea58c417032ddc54db4e128822e43b0a2b61eee82a7429616d8ab48',
	'0x93dcd3d57bc5a07a406f5172774cd8a72c7295c7ee5f9fac3f03fed7ff12c807',
	'0x5de09d05cb953b0087a39c1fd8403a2ec0084b6a4d5f3379eb5e3587489a4e51',
	'0x1a95a5a49333e0d744d1e64d71dde9c8633ec775742af41e2e5232d1a34eb0cb',
	'0x84752993c6dc6fce70e25ddeb4daddb6592d6b9b0912a0a91c07cfff5a721d89',
	'0xcf6c36653104981208a45ffdd147a86c899e3582a858cf8a50cedc2cbc833bb6',
	'0xebe783c06bf53af0dcc460c2cf137c5182bb2eca56ea113ec874547df3a86388',
	'0x653e7658fe5bea8659f2b5aaceda71fd04060b99ea8859a58f5cd9d7ec6a3fae',
	'0xfa732993af2b60d04d7049511f801e79426b2b6a5103e22769c0cead982b0f47',
	'0x18d7ec01ebb37487f1c59e45b82421a7e3d316e68c25e40a2305d0aa93814ef1',
	'0x9a4b2d734e1333c6fc568b392ac9e9ae810bcecfd0885b3a168d60c0fc8c928c',
	'0x2ea6691f0654bd9acadf4c26326fbcced6eaf0b5f64938c618a05ea64ca0d830',
	'0xdbd232f1ddc81cc64643f541f074d19745817df06ff8d89ccf1ec3b0fbb6e591',
	'0xdac0fb500cf3765950423461c39326efabdced4b2c1a8f3d1df89c671bf710c8',
	'0xd90e0a448e3224ee7760810a97b43bffe956f8443ca3489ef5aa51addf1fc4d8',
	'0xcf8d0d98dd3c2ceaf40845f5260c620fa62b3a15380bc100053aecd6df8e5e7c',
	'0xd9474556884afc05b31272823a31c7d1818b4c0951b15a92f576163ecb432613',
	'0x20b9a3ec7a02d4f344aa1ebc5774b7b0ccafa9a5d76230662fdc0300bb215307',
	'0xa01557a2c5cb12fa6046d7c6921fa6665b7c009a1adec531947e1170ebbb0695',
	'0xfacee57bc356dae0d9958c653253893dfb24e24e8871f53e69b7dccb3ffbf945',
	'0x56a1c985c1f1123181d6b881714793689321ba24301b3585eec427436eb1c76d',
	'0x81f5339934c83ea19dd6bcc75c52e83509629a5f71d3257428c2ce47cc94d08b',
	'0x1fe7b99c28ded39774f37327b509d58e2be7fff94899c06d22b407496a6fa990',
	'0x2646dee5c4ad2d1ea9ce94a3c862dfd843a94753088c2507fea9223fd7e32a8f',
	'0x126865a0197d6ab44bfd15fd052da6db92fd2eb831ff9663451bbfa1219e2af2',
	'0x183df694ebc852a5f90a959f0f563b82ac9691e42357e9a9fe961d71a1b809c8',
	'0x5661fc7f88fbeb8cb881150a810758cf13700bb4e1f31274a244581b37c303c3',
	'0xe8e56f377ab5a261449b92ac42c8ddaacd5671e9fec2179d7933dd1a91200eec',
	'0x27c4fdb3b846aa3ae4a65ef5127a309aa3c1f466671471a806d8912a18b253e8',
	'0x0c0fdd4008740d81a8a7d4281322aee71a1b62c449eb5b142656753d89ebc060',
	'0x4e2ca3988246e1d50b9bf209abb9c1cbfec65bd95afdacc620a36c67bdb8452f',
	'0xa0b9ebefb38c963fd115f52d71fa64501b79d1adcb5270563f92ce0442376545',
	'0x52f9bf16d9e7eff79da73d5e3dea39fe1ef8c77684bf4ec2c6566b41396404d0',
	'0xc69f7755fec146583e276a104bcf91e0c9f0cab91dcdb1c202e8d76a5a5a1101',
	'0x1109352b9112717bd2a7c3eb9a416fff1ba6951760f5bdd5424cf5e4e5b3e65c',
	'0xe05dafb5133bcffb8d59f4e12465dc0e9faeaa05e3e342a08fe135800e3e4407',
	'0xf948981b806057580f91622417534f491da5f61aeaf33d0ed8e69fd5691c95ce',
	'0xb663828d6217467c8a1838a03793da896cbe745b150ebd57d82f814ca579fc22',
	'0xde096bb2c59538a25c89229127fe0bc8b63ecdbe52a3693099cc40a1d8a2cfd4',
	'0xe9aecf5859310f8b596fbe8488222a7fb15a55003455c9f42d1b60fab9cca9ba',
];

// Split `Pool<Base, Quote>` type string into [Base, Quote] while respecting nested <>.
const splitTypeArgs = (typeStr: string): [string, string] => {
	const open = typeStr.indexOf('<');
	const close = typeStr.lastIndexOf('>');
	if (open < 0 || close < 0) throw new Error(`no type args in ${typeStr}`);
	const inner = typeStr.slice(open + 1, close);
	let depth = 0;
	let splitIdx = -1;
	for (let i = 0; i < inner.length; i++) {
		const c = inner[i];
		if (c === '<') depth++;
		else if (c === '>') depth--;
		else if (c === ',' && depth === 0) {
			splitIdx = i;
			break;
		}
	}
	if (splitIdx < 0) throw new Error(`could not split type args in ${typeStr}`);
	return [inner.slice(0, splitIdx).trim(), inner.slice(splitIdx + 1).trim()];
};

(async () => {
	const env = 'mainnet';
	const client = getClient(env);

	console.log(`Fetching types for ${POOL_IDS.length} pools...`);
	const poolInfo = await Promise.all(
		POOL_IDS.map(async (id) => {
			const res = await client.getObject({ id, options: { showType: true } });
			const typeStr = res.data?.type;
			if (!typeStr) throw new Error(`pool ${id} returned no type`);
			const [baseType, quoteType] = splitTypeArgs(typeStr);
			return { id, baseType, quoteType };
		}),
	);

	const tx = new Transaction();
	tx.setSender(SIGNER);
	const gasObj = await client.getObject({ id: GAS_OBJECT });
	if (!gasObj.data) throw new Error(`gas object ${GAS_OBJECT} not found`);
	tx.setGasPayment([
		{ objectId: gasObj.data.objectId, version: gasObj.data.version, digest: gasObj.data.digest },
	]);

	for (const { id, baseType, quoteType } of poolInfo) {
		tx.moveCall({
			target: `${DEEPBOOK_PACKAGE_ID}::pool::update_pool_allowed_versions`,
			arguments: [tx.object(id), tx.object(REGISTRY_ID)],
			typeArguments: [baseType, quoteType],
		});
	}

	const signer = getSigner();
	if (signer.getPublicKey().toSuiAddress() !== SIGNER) {
		throw new Error(
			`keypair address ${signer.getPublicKey().toSuiAddress()} does not match SIGNER ${SIGNER}`,
		);
	}

	const res = await client.signAndExecuteTransaction({
		transaction: tx,
		signer,
		options: { showEffects: true, showObjectChanges: true },
	});
	console.dir(res, { depth: null });
})();
