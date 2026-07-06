import { TESTNET_CONFIG } from "./testnet.js";
import type { PredictConfig } from "./types.js";

export type { PredictConfig, PredictPackages, UnderlyingConfig } from "./types.js";
export { TESTNET_CONFIG } from "./testnet.js";

/** The shared Clock object — a fixed well-known id on every network. */
export const CLOCK_ID = "0x6";
/** The shared AccumulatorRoot object — a fixed well-known id on every network. */
export const ACCUMULATOR_ROOT_ID = "0xacc";

export function getConfig(network: "testnet" | "mainnet"): PredictConfig {
	if (network === "mainnet") throw new Error("no mainnet deployment");
	return TESTNET_CONFIG;
}

// MVR: when @deepbook/predict is registered, resolve the name here (named-packages
// plugin); builders never hardcode targets.
export function predictTarget(
	cfg: PredictConfig,
	module: string,
	fn: string,
): `${string}::${string}::${string}` {
	return `${cfg.packages.predict}::${module}::${fn}`;
}

// MVR: when @deepbook/account is registered, resolve the name here (named-packages
// plugin); builders never hardcode targets.
export function accountTarget(
	cfg: PredictConfig,
	module: string,
	fn: string,
): `${string}::${string}::${string}` {
	return `${cfg.packages.account}::${module}::${fn}`;
}
