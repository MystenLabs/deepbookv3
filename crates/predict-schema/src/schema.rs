// Predict protocol Diesel schema — hand-written to match migration.

// === Oracle tables ===

diesel::table! {
    oracle_activated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
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
        package -> Text,
        oracle_id -> Text,
        a -> Int8,
        b -> Int8,
        rho -> Int8,
        rho_negative -> Bool,
        m -> Int8,
        m_negative -> Bool,
        sigma -> Int8,
        risk_free_rate -> Int8,
        onchain_timestamp -> Int8,
    }
}

// === Registry tables ===

diesel::table! {
    predict_created (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
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
        package -> Text,
        oracle_id -> Text,
        oracle_cap_id -> Text,
        expiry -> Int8,
    }
}

diesel::table! {
    admin_vault_balance_changed (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        predict_id -> Text,
        amount -> Int8,
        deposit -> Bool,
    }
}

// === Trading tables ===

diesel::table! {
    position_minted (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        predict_id -> Text,
        manager_id -> Text,
        trader -> Text,
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
        package -> Text,
        predict_id -> Text,
        manager_id -> Text,
        trader -> Text,
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
    collateralized_position_minted (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        predict_id -> Text,
        manager_id -> Text,
        trader -> Text,
        oracle_id -> Text,
        locked_expiry -> Int8,
        locked_strike -> Int8,
        locked_is_up -> Bool,
        minted_expiry -> Int8,
        minted_strike -> Int8,
        minted_is_up -> Bool,
        quantity -> Int8,
    }
}

diesel::table! {
    collateralized_position_redeemed (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        predict_id -> Text,
        manager_id -> Text,
        trader -> Text,
        oracle_id -> Text,
        locked_expiry -> Int8,
        locked_strike -> Int8,
        locked_is_up -> Bool,
        minted_expiry -> Int8,
        minted_strike -> Int8,
        minted_is_up -> Bool,
        quantity -> Int8,
    }
}

// === Admin tables ===

diesel::table! {
    trading_pause_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
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
        package -> Text,
        predict_id -> Text,
        base_spread -> Int8,
        max_skew_multiplier -> Int8,
        utilization_multiplier -> Int8,
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
        package -> Text,
        predict_id -> Text,
        max_total_exposure_pct -> Int8,
    }
}

// === User tables ===

diesel::table! {
    predict_manager_created (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        manager_id -> Text,
        owner -> Text,
    }
}

// === System tables ===

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
    admin_vault_balance_changed,
    position_minted,
    position_redeemed,
    collateralized_position_minted,
    collateralized_position_redeemed,
    trading_pause_updated,
    pricing_config_updated,
    risk_config_updated,
    predict_manager_created,
    watermarks,
);
