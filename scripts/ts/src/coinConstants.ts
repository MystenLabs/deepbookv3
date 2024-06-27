import { getActiveAddress } from "./utils";

/// Immutable constants ///
// Trading constants
export const NO_RESTRICTION = 0;
export const IMMEDIATE_OR_CANCEL = 1;
export const FILL_OR_KILL = 2;
export const POST_ONLY = 3;

// Self matching options
export const SELF_MATCHING_ALLOWED = 0;
export const CANCEL_TAKER = 1;
export const CANCEL_MAKER = 2;

// Pool constants
export const FLOAT_SCALAR = 1000000000;
export const POOL_CREATION_FEE = 10000 * 1000000;
export const LARGE_TIMESTAMP = 1844674407370955161;
export const GAS_BUDGET = 0.5 * 1000000000 // Adjust based on benchmarking

/// Mutable coin constants ///
type CoinScalarsType = {
    [key: string]: number;
};

// Declare coin types
export const ASLAN_TYPE = `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::aslancoin::ASLANCOIN`;
export const TONY_TYPE = `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::tonycoin::TONYCOIN`;
export const DEEP_TYPE = `0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP`;
export const SUI_TYPE = `0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI`;

// Add types and coin scalars as needed
export const COIN_SCALARS: CoinScalarsType = {
    [ASLAN_TYPE]: 1000000,
    [TONY_TYPE]: 1000000,
    [DEEP_TYPE]: 1000000,
    [SUI_TYPE]: 1000000000,
};

// Update coin IDs as needed
export const COIN_IDS = {
    DEEP: `0x363fc7964af3ce74ec92ba37049601ffa88dfa432c488130b340b52d58bdcf50`,
    SUI: `0x0064c4fd7c1c8f56ee8fb1d564bcd1c32a274156b942fd0ea25d605e3d2c5315`,
    TONY: `0xd5dd3f2623fd809bf691362b6838efc7b84e12c49741299787439f755e5ee765`
};

// Update env, package IDs, manager id as needed
export const ENV = 'testnet';
export const DEEPBOOK_PACKAGE_ID = `0x22ed917fa56afe09677314871a2997a111ebacd1f622b6cfed3a4422aa4d2e06`;
export const REGISTRY_ID = `0x14614dfc9243fcb2ef7ac51efed5c6284ca701d55216e1f42b3eb22c541feaa6`;
export const DEEP_TREASURY_ID = `0x69fffdae0075f8f71f4fa793549c11079266910e8905169845af1f5d00e09dcb`;
export const DEEP_SUI_POOL_ID = `0x9c29aa70749297fe4fc35403ae743cc8883ad26ba77b9ba214dbff7d5f9a5395`;
export const TONY_SUI_POOL_ID = `0x92083a73031ad86c6df401dc4a59b5dfa589db5937a921c2ec72a5629b715154`;
export const MANAGER_ID = `0x08b49d7067383d17cdd695161b247e2f617e0d9095da65edb85900e7b6f82de4`;
export const MY_ADDRESS = getActiveAddress();

/// Admin only ///
export const ADMINCAP_ID = `0x30314edf9cfa6057722746f31b0973225b38437589b067d4ca6ad263cef9186a`;
