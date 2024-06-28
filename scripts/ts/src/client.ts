import { SuiClient, getFullnodeUrl } from "@mysten/sui.js/client";
import { Ed25519Keypair } from '@mysten/sui.js/dist/cjs/keypairs/ed25519';
import { Secp256k1Keypair } from '@mysten/sui.js/keypairs/secp256k1';
import { Secp256r1Keypair } from '@mysten/sui.js/keypairs/secp256r1';
import { decodeSuiPrivateKey } from "@mysten/sui.js/dist/cjs/cryptography";

export class DeepBookClient {
    #client: SuiClient;
    #signer: Ed25519Keypair | Secp256k1Keypair | Secp256r1Keypair;
    #balanceManager: string | undefined;

    constructor(
        network: "mainnet" | "testnet" | "devnet" | "localnet",
        privateKey: string,
        balanceManager?: string
    ) {
        this.#client = new SuiClient({ url: getFullnodeUrl(network) });
        this.#signer = this.getSigner(privateKey);
        this.#balanceManager = balanceManager;
    }

    getSigner(privateKey: string) {
        const { schema, secretKey } = decodeSuiPrivateKey(privateKey);
        if (schema === 'ED25519') return Ed25519Keypair.fromSecretKey(secretKey);
        if (schema === 'Secp256k1') return Secp256k1Keypair.fromSecretKey(secretKey);
        if (schema === 'Secp256r1') return Secp256r1Keypair.fromSecretKey(secretKey);

        throw new Error(`Unsupported schema: ${schema}`);
    }

    setBalanceManager(balanceManager: string) {
        this.#balanceManager = balanceManager;
    }
}