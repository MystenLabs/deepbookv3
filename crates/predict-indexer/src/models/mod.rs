use crate::traits::MoveStruct;
use serde::{Deserialize, Serialize};
use sui_sdk_types::Address;
use sui_types::base_types::ObjectID;

pub mod predict {
    use super::*;

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct PositionMinted {
        pub predict_id: ObjectID,
        pub manager_id: ObjectID,
        pub trader: Address,
        pub quote_asset: String,
        pub oracle_id: ObjectID,
        pub expiry: u64,
        pub strike: u64,
        pub is_up: bool,
        pub quantity: u64,
        pub cost: u64,
        pub fee_amount: u64,
    }

    impl MoveStruct for PositionMinted {
        const MODULE: &'static str = "predict";
        const NAME: &'static str = "PositionMinted";
    }

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct PositionRedeemed {
        pub predict_id: ObjectID,
        pub manager_id: ObjectID,
        pub owner: Address,
        pub executor: Address,
        pub quote_asset: String,
        pub oracle_id: ObjectID,
        pub expiry: u64,
        pub strike: u64,
        pub is_up: bool,
        pub quantity: u64,
        pub payout: u64,
        pub fee_amount: u64,
        pub is_settled: bool,
    }

    impl MoveStruct for PositionRedeemed {
        const MODULE: &'static str = "predict";
        const NAME: &'static str = "PositionRedeemed";
    }

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct Supplied {
        pub predict_id: ObjectID,
        pub supplier: Address,
        pub quote_asset: String,
        pub amount: u64,
        pub shares_minted: u64,
    }

    impl MoveStruct for Supplied {
        const MODULE: &'static str = "predict";
        const NAME: &'static str = "Supplied";
    }

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct Withdrawn {
        pub predict_id: ObjectID,
        pub withdrawer: Address,
        pub quote_asset: String,
        pub amount: u64,
        pub shares_burned: u64,
    }

    impl MoveStruct for Withdrawn {
        const MODULE: &'static str = "predict";
        const NAME: &'static str = "Withdrawn";
    }
}

pub mod oracle {
    use super::*;

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct OracleSettled {
        pub oracle_id: ObjectID,
        pub expiry: u64,
        pub settlement_price: u64,
        pub spot_timestamp_ms: u64,
    }

    impl MoveStruct for OracleSettled {
        const MODULE: &'static str = "oracle";
        const NAME: &'static str = "OracleSettled";
    }
}
