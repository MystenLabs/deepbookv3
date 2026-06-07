// @generated automatically by Diesel CLI.

diesel::table! {
    order_minted (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        expiry_market_id -> Text,
        predict_manager_id -> Text,
        order_id -> Text,
        position_root_id -> Text,
        owner -> Text,
        lower_strike -> Numeric,
        higher_strike -> Numeric,
        leverage -> Int8,
        entry_probability -> Int8,
        quantity -> Numeric,
        contribution -> Numeric,
        trading_fee -> Numeric,
        builder_fee -> Numeric,
        penalty_fee -> Numeric,
        builder_code_id -> Nullable<Text>,
    }
}

diesel::table! {
    live_order_redeemed (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        expiry_market_id -> Text,
        predict_manager_id -> Text,
        order_id -> Text,
        position_root_id -> Text,
        owner -> Text,
        quantity_closed -> Numeric,
        remaining_quantity -> Numeric,
        replacement_order_id -> Nullable<Text>,
        redeem_amount -> Numeric,
        trading_fee -> Numeric,
        builder_fee -> Numeric,
        penalty_fee -> Numeric,
        builder_code_id -> Nullable<Text>,
    }
}

diesel::table! {
    settled_order_redeemed (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        expiry_market_id -> Text,
        predict_manager_id -> Text,
        order_id -> Text,
        position_root_id -> Text,
        owner -> Text,
        quantity_closed -> Numeric,
        settlement_price -> Numeric,
        payout_amount -> Numeric,
    }
}

diesel::table! {
    liquidated_order_redeemed (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        expiry_market_id -> Text,
        predict_manager_id -> Text,
        order_id -> Text,
        position_root_id -> Text,
        owner -> Text,
        quantity_closed -> Numeric,
    }
}

diesel::table! {
    watermarks (pipeline) {
        pipeline -> Text,
        epoch_hi_inclusive -> Int8,
        checkpoint_hi_inclusive -> Int8,
        tx_hi -> Int8,
        timestamp_ms_hi_inclusive -> Int8,
        reader_lo -> Int8,
        pruner_timestamp -> Timestamp,
        pruner_hi -> Int8,
    }
}

diesel::table! {
    order_liquidated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        expiry_market_id -> Text,
        order_id -> Text,
        quantity -> Numeric,
        gross_value -> Numeric,
        floor_amount -> Numeric,
        liquidation_ltv -> Int8,
    }
}

diesel::allow_tables_to_appear_in_same_query!(
    liquidated_order_redeemed,
    live_order_redeemed,
    order_liquidated,
    order_minted,
    settled_order_redeemed,
    watermarks,
);
