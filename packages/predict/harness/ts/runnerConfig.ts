// Environment-free runner defaults shared by metadata discovery and the trader process.
// Keep this module free of runtime/oracle imports: campaign reads strategy metadata before
// any localnet or `.env.localnet` exists.
export const DEFAULT_TRADER_GAS_BUDGET = 2_000_000_000;
