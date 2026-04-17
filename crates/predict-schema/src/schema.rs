diesel::table! {
    oracle_activated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        oracle_id -> Text,
        expiry -> Int8,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    oracle_settled (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        oracle_id -> Text,
        expiry -> Int8,
        settlement_price -> Int8,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    oracle_prices_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        oracle_id -> Text,
        spot -> Int8,
        forward -> Int8,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    oracle_svi_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        oracle_id -> Text,
        a -> Int8,
        b -> Int8,
        rho -> Int8,
        rho_negative -> Bool,
        m -> Int8,
        m_negative -> Bool,
        sigma -> Int8,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    predict_created (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        predict_id -> Text,
    }
}

diesel::table! {
    oracle_created (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        oracle_id -> Text,
        oracle_cap_id -> Text,
        underlying_asset -> Text,
        expiry -> Int8,
        min_strike -> Int8,
        tick_size -> Int8,
    }
}

diesel::table! {
    position_minted (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
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
        ask_price -> Int8,
    }
}

diesel::table! {
    position_redeemed (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
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
        bid_price -> Int8,
        is_settled -> Bool,
    }
}

diesel::table! {
    range_minted (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        predict_id -> Text,
        manager_id -> Text,
        trader -> Text,
        quote_asset -> Text,
        oracle_id -> Text,
        expiry -> Int8,
        lower_strike -> Int8,
        higher_strike -> Int8,
        quantity -> Int8,
        cost -> Int8,
        ask_price -> Int8,
    }
}

diesel::table! {
    range_redeemed (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        predict_id -> Text,
        manager_id -> Text,
        trader -> Text,
        quote_asset -> Text,
        oracle_id -> Text,
        expiry -> Int8,
        lower_strike -> Int8,
        higher_strike -> Int8,
        quantity -> Int8,
        payout -> Int8,
        bid_price -> Int8,
        is_settled -> Bool,
    }
}

diesel::table! {
    supplied (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        predict_id -> Text,
        supplier -> Text,
        quote_asset -> Text,
        amount -> Int8,
        shares_minted -> Int8,
    }
}

diesel::table! {
    withdrawn (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        predict_id -> Text,
        withdrawer -> Text,
        quote_asset -> Text,
        amount -> Int8,
        shares_burned -> Int8,
    }
}

diesel::table! {
    trading_pause_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        predict_id -> Text,
        paused -> Bool,
    }
}

diesel::table! {
    pricing_config_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        predict_id -> Text,
        base_spread -> Int8,
        min_spread -> Int8,
        utilization_multiplier -> Int8,
        min_ask_price -> Int8,
        max_ask_price -> Int8,
    }
}

diesel::table! {
    risk_config_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        predict_id -> Text,
        max_total_exposure_pct -> Int8,
    }
}

diesel::table! {
    oracle_ask_bounds_set (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        predict_id -> Text,
        oracle_id -> Text,
        min_ask_price -> Int8,
        max_ask_price -> Int8,
    }
}

diesel::table! {
    oracle_ask_bounds_cleared (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        predict_id -> Text,
        oracle_id -> Text,
    }
}

diesel::table! {
    quote_asset_enabled (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        predict_id -> Text,
        quote_asset -> Text,
    }
}

diesel::table! {
    quote_asset_disabled (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        predict_id -> Text,
        quote_asset -> Text,
    }
}

diesel::table! {
    predict_manager_created (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        package -> Text,
        manager_id -> Text,
        owner -> Text,
    }
}

diesel::table! {
    watermarks (pipeline) {
        pipeline -> Text,
        epoch_hi_inclusive -> Int8,
        checkpoint_hi_inclusive -> Int8,
        tx_hi -> Int8,
        timestamp_ms_hi_inclusive -> Int8,
    }
}

diesel::allow_tables_to_appear_in_same_query!(
    oracle_activated,
    oracle_settled,
    oracle_prices_updated,
    oracle_svi_updated,
    predict_created,
    oracle_created,
    position_minted,
    position_redeemed,
    range_minted,
    range_redeemed,
    supplied,
    withdrawn,
    trading_pause_updated,
    pricing_config_updated,
    risk_config_updated,
    oracle_ask_bounds_set,
    oracle_ask_bounds_cleared,
    quote_asset_enabled,
    quote_asset_disabled,
    predict_manager_created,
    watermarks,
);
