// @generated automatically by Diesel CLI.

diesel::table! {
    predict_managers (object_id) {
        object_id -> Text,
        owner_address -> Text,
        checkpoint -> Int8,
        timestamp -> Int8,
    }
}

diesel::table! {
    predict_user_positions (manager_id, oracle_id, expiry, strike, is_up) {
        manager_id -> Text,
        oracle_id -> Text,
        expiry -> Int8,
        strike -> Int8,
        is_up -> Bool,
        free_quantity -> Int8,
        locked_quantity -> Int8,
        checkpoint -> Int8,
        timestamp -> Int8,
    }
}

diesel::table! {
    predict_collateral (manager_id, oracle_id, expiry, strike) {
        manager_id -> Text,
        oracle_id -> Text,
        expiry -> Int8,
        strike -> Int8,
        quantity -> Int8,
        checkpoint -> Int8,
        timestamp -> Int8,
    }
}

diesel::table! {
    predict_oracles (object_id) {
        object_id -> Text,
        underlying_asset -> Text,
        pyth_lazer_feed_id -> Int4,
        expiry -> Int8,
        min_strike -> Int8,
        tick_size -> Int8,
        status -> Int2,
        settlement_price -> Nullable<Int8>,
        checkpoint -> Int8,
        timestamp -> Int8,
    }
}

diesel::table! {
    predict_events_minted (tx_digest, event_index) {
        tx_digest -> Text,
        event_index -> Int8,
        checkpoint -> Int8,
        timestamp -> Int8,
        predict_id -> Text,
        manager_id -> Text,
        trader -> Text,
        quote_asset -> Text,
        oracle_id -> Text,
        expiry -> Int8,
        strike -> Int8,
        is_up -> Bool,
        quantity -> Int8,
        cost -> Int8,
        fee_amount -> Int8,
    }
}

diesel::table! {
    predict_events_redeemed (tx_digest, event_index) {
        tx_digest -> Text,
        event_index -> Int8,
        checkpoint -> Int8,
        timestamp -> Int8,
        predict_id -> Text,
        manager_id -> Text,
        owner -> Text,
        executor -> Text,
        quote_asset -> Text,
        oracle_id -> Text,
        expiry -> Int8,
        strike -> Int8,
        is_up -> Bool,
        quantity -> Int8,
        payout -> Int8,
        fee_amount -> Int8,
        is_settled -> Bool,
    }
}

diesel::table! {
    predict_events_oracle_settled (tx_digest, event_index) {
        tx_digest -> Text,
        event_index -> Int8,
        checkpoint -> Int8,
        timestamp -> Int8,
        oracle_id -> Text,
        expiry -> Int8,
        settlement_price -> Int8,
        spot_timestamp_ms -> Int8,
    }
}

diesel::table! {
    predict_vaults (object_id) {
        object_id -> Text,
        quote_asset -> Text,
        balance -> Int8,
        total_mtm -> Int8,
        total_max_payout -> Int8,
        total_lp_supply -> Int8,
        base_fee -> Int8,
        min_fee -> Int8,
        utilization_multiplier -> Int8,
        max_total_exposure_pct -> Int8,
        mtm_freshness_ms -> Int8,
        total_fees_accrued -> Int8,
        lp_fees_accrued -> Int8,
        protocol_fees_accrued -> Int8,
        insurance_fees_accrued -> Int8,
        trading_paused -> Bool,
        checkpoint -> Int8,
        timestamp -> Int8,
    }
}

diesel::table! {
    predict_events_supplied (tx_digest, event_index) {
        tx_digest -> Text,
        event_index -> Int8,
        checkpoint -> Int8,
        timestamp -> Int8,
        predict_id -> Text,
        supplier -> Text,
        quote_asset -> Text,
        amount -> Int8,
        shares_minted -> Int8,
    }
}

diesel::table! {
    predict_events_withdrawn (tx_digest, event_index) {
        tx_digest -> Text,
        event_index -> Int8,
        checkpoint -> Int8,
        timestamp -> Int8,
        predict_id -> Text,
        withdrawer -> Text,
        quote_asset -> Text,
        amount -> Int8,
        shares_burned -> Int8,
    }
}

diesel::allow_tables_to_appear_in_same_query!(
    predict_managers,
    predict_user_positions,
    predict_collateral,
    predict_oracles,
    predict_vaults,
    predict_events_minted,
    predict_events_redeemed,
    predict_events_oracle_settled,
    predict_events_supplied,
    predict_events_withdrawn,
);
