// @generated automatically by Diesel CLI.

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
    pyth_observation (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        propbook_oracle_id -> Text,
        pyth_source_id -> Int8,
        price_magnitude -> Numeric,
        price_is_negative -> Bool,
        exponent_magnitude -> Int4,
        exponent_is_negative -> Bool,
        source_timestamp_us -> Numeric,
        normalized_spot -> Nullable<Numeric>,
        source_timestamp_ms -> Int8,
        update_timestamp_ms -> Int8,
        is_exact -> Bool,
    }
}

diesel::table! {
    block_scholes_observation (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        propbook_oracle_id -> Text,
        bs_source_id -> Int8,
        expiry_ms -> Int8,
        spot -> Numeric,
        forward -> Numeric,
        svi_a -> Numeric,
        svi_b -> Numeric,
        svi_rho -> Numeric,
        svi_m -> Numeric,
        svi_sigma -> Numeric,
        normalized_spot -> Nullable<Numeric>,
        normalized_forward -> Nullable<Numeric>,
        source_timestamp_ms -> Int8,
        update_timestamp_ms -> Int8,
        is_exact -> Bool,
    }
}

diesel::table! {
    oracle_source_registered (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        oracle_kind -> Int2,
        source_id -> Int8,
        propbook_oracle_id -> Text,
    }
}

diesel::table! {
    oracle_bound (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        propbook_underlying_id -> Int8,
        oracle_kind -> Int2,
        source_id -> Int8,
        propbook_oracle_id -> Text,
        value_kind -> Int2,
    }
}

diesel::table! {
    oracle_spot_1m (propbook_oracle_id, expiry_ms, bucket_ms) {
        propbook_oracle_id -> Text,
        expiry_ms -> Int8,
        bucket_ms -> Int8,
        open -> Numeric,
        high -> Numeric,
        low -> Numeric,
        close -> Numeric,
        forward -> Numeric,
        update_count -> Int8,
    }
}

diesel::allow_tables_to_appear_in_same_query!(
    block_scholes_observation,
    oracle_bound,
    oracle_source_registered,
    oracle_spot_1m,
    pyth_observation,
    watermarks,
);
