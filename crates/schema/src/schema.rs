// @generated automatically by Diesel CLI.

diesel::table! {
    asset_supplied (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        margin_pool_id -> Text,
        asset_type -> Text,
        supplier -> Text,
        amount -> Int8,
        shares -> Int8,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    asset_withdrawn (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        margin_pool_id -> Text,
        asset_type -> Text,
        supplier -> Text,
        amount -> Int8,
        shares -> Int8,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    assets (asset_type) {
        asset_type -> Text,
        name -> Text,
        symbol -> Text,
        decimals -> Int2,
        ucid -> Nullable<Int4>,
        package_id -> Nullable<Text>,
        package_address_url -> Nullable<Text>,
    }
}

diesel::table! {
    balances (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        balance_manager_id -> Text,
        asset -> Text,
        amount -> Int8,
        deposit -> Bool,
    }
}

diesel::table! {
    collateral_events (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        event_type -> Text,
        margin_manager_id -> Text,
        amount -> Numeric,
        asset_type -> Text,
        pyth_decimals -> Int2,
        pyth_price -> Numeric,
        withdraw_base_asset -> Nullable<Bool>,
        base_pyth_decimals -> Nullable<Int2>,
        base_pyth_price -> Nullable<Numeric>,
        quote_pyth_decimals -> Nullable<Int2>,
        quote_pyth_price -> Nullable<Numeric>,
        remaining_base_asset -> Nullable<Numeric>,
        remaining_quote_asset -> Nullable<Numeric>,
        remaining_base_debt -> Nullable<Numeric>,
        remaining_quote_debt -> Nullable<Numeric>,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    conditional_order_events (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        event_type -> Text,
        manager_id -> Text,
        pool_id -> Nullable<Text>,
        conditional_order_id -> Int8,
        trigger_below_price -> Bool,
        trigger_price -> Numeric,
        is_limit_order -> Bool,
        client_order_id -> Int8,
        order_type -> Int2,
        self_matching_option -> Int2,
        price -> Numeric,
        quantity -> Numeric,
        is_bid -> Bool,
        pay_with_deep -> Bool,
        expire_timestamp -> Int8,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    deep_burned (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_id -> Text,
        burned_amount -> Int8,
    }
}

diesel::table! {
    deepbook_pool_config_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_id -> Text,
        config_json -> Jsonb,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    deepbook_pool_registered (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_id -> Text,
        onchain_timestamp -> Int8,
        config_json -> Nullable<Jsonb>,
    }
}

diesel::table! {
    deepbook_pool_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        margin_pool_id -> Text,
        deepbook_pool_id -> Text,
        pool_cap_id -> Text,
        enabled -> Bool,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    deepbook_pool_updated_registry (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_id -> Text,
        enabled -> Bool,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    flashloans (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        borrow -> Bool,
        pool_id -> Text,
        borrow_quantity -> Int8,
        type_name -> Text,
    }
}

diesel::table! {
    interest_params_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        margin_pool_id -> Text,
        pool_cap_id -> Text,
        config_json -> Jsonb,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    liquidation (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        margin_manager_id -> Text,
        margin_pool_id -> Text,
        liquidation_amount -> Int8,
        pool_reward -> Int8,
        pool_default -> Int8,
        risk_ratio -> Int8,
        onchain_timestamp -> Int8,
        remaining_base_asset -> Numeric,
        remaining_quote_asset -> Numeric,
        remaining_base_debt -> Numeric,
        remaining_quote_debt -> Numeric,
        base_pyth_price -> Int8,
        base_pyth_decimals -> Int2,
        quote_pyth_price -> Int8,
        quote_pyth_decimals -> Int2,
    }
}

diesel::table! {
    loan_borrowed (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        margin_manager_id -> Text,
        margin_pool_id -> Text,
        loan_amount -> Int8,
        onchain_timestamp -> Int8,
        loan_shares -> Int8,
    }
}

diesel::table! {
    loan_repaid (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        margin_manager_id -> Text,
        margin_pool_id -> Text,
        repay_amount -> Int8,
        repay_shares -> Int8,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    maintainer_cap_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        maintainer_cap_id -> Text,
        allowed -> Bool,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    maintainer_fees_withdrawn (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        margin_pool_id -> Text,
        margin_pool_cap_id -> Text,
        maintainer_fees -> Int8,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    margin_manager_created (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        margin_manager_id -> Text,
        balance_manager_id -> Text,
        owner -> Text,
        onchain_timestamp -> Int8,
        deepbook_pool_id -> Nullable<Text>,
    }
}

diesel::table! {
    margin_manager_state (id) {
        id -> Int4,
        #[max_length = 66]
        margin_manager_id -> Varchar,
        #[max_length = 66]
        deepbook_pool_id -> Varchar,
        #[max_length = 66]
        base_margin_pool_id -> Nullable<Varchar>,
        #[max_length = 66]
        quote_margin_pool_id -> Nullable<Varchar>,
        #[max_length = 255]
        base_asset_id -> Nullable<Varchar>,
        #[max_length = 50]
        base_asset_symbol -> Nullable<Varchar>,
        #[max_length = 255]
        quote_asset_id -> Nullable<Varchar>,
        #[max_length = 50]
        quote_asset_symbol -> Nullable<Varchar>,
        risk_ratio -> Nullable<Numeric>,
        base_asset -> Nullable<Numeric>,
        quote_asset -> Nullable<Numeric>,
        base_debt -> Nullable<Numeric>,
        quote_debt -> Nullable<Numeric>,
        base_pyth_price -> Nullable<Int8>,
        base_pyth_decimals -> Nullable<Int4>,
        quote_pyth_price -> Nullable<Int8>,
        quote_pyth_decimals -> Nullable<Int4>,
        created_at -> Timestamp,
        updated_at -> Timestamp,
        current_price -> Nullable<Numeric>,
        lowest_trigger_above_price -> Nullable<Numeric>,
        highest_trigger_below_price -> Nullable<Numeric>,
    }
}

diesel::table! {
    margin_pool_config_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        margin_pool_id -> Text,
        pool_cap_id -> Text,
        config_json -> Jsonb,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    margin_pool_created (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        margin_pool_id -> Text,
        maintainer_cap_id -> Text,
        asset_type -> Text,
        config_json -> Jsonb,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    margin_pool_snapshots (id) {
        id -> Int8,
        margin_pool_id -> Text,
        asset_type -> Text,
        timestamp -> Timestamp,
        total_supply -> Int8,
        total_borrow -> Int8,
        vault_balance -> Int8,
        supply_cap -> Int8,
        interest_rate -> Int8,
        available_withdrawal -> Int8,
        utilization_rate -> Float8,
        solvency_ratio -> Nullable<Float8>,
        available_liquidity_pct -> Nullable<Float8>,
    }
}

diesel::table! {
    ohclv_1d (pool_id, bucket_time) {
        pool_id -> Text,
        bucket_time -> Date,
        open -> Numeric,
        high -> Numeric,
        low -> Numeric,
        close -> Numeric,
        base_volume -> Numeric,
        quote_volume -> Numeric,
        trade_count -> Int4,
        first_trade_timestamp -> Int8,
        last_trade_timestamp -> Int8,
    }
}

diesel::table! {
    ohclv_1m (pool_id, bucket_time) {
        pool_id -> Text,
        bucket_time -> Timestamp,
        open -> Numeric,
        high -> Numeric,
        low -> Numeric,
        close -> Numeric,
        base_volume -> Numeric,
        quote_volume -> Numeric,
        trade_count -> Int4,
        first_trade_timestamp -> Int8,
        last_trade_timestamp -> Int8,
    }
}

diesel::table! {
    order_fills (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_id -> Text,
        maker_order_id -> Text,
        taker_order_id -> Text,
        maker_client_order_id -> Int8,
        taker_client_order_id -> Int8,
        price -> Int8,
        taker_fee -> Int8,
        taker_fee_is_deep -> Bool,
        maker_fee -> Int8,
        maker_fee_is_deep -> Bool,
        taker_is_bid -> Bool,
        base_quantity -> Int8,
        quote_quantity -> Int8,
        maker_balance_manager_id -> Text,
        taker_balance_manager_id -> Text,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    order_updates (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        status -> Text,
        pool_id -> Text,
        order_id -> Text,
        client_order_id -> Int8,
        price -> Int8,
        is_bid -> Bool,
        original_quantity -> Int8,
        quantity -> Int8,
        filled_quantity -> Int8,
        onchain_timestamp -> Int8,
        balance_manager_id -> Text,
        trader -> Text,
    }
}

diesel::table! {
    pause_cap_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pause_cap_id -> Text,
        allowed -> Bool,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    pool_prices (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        target_pool -> Text,
        reference_pool -> Text,
        conversion_rate -> Int8,
    }
}

diesel::table! {
    pool_created (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_id -> Text,
        taker_fee -> Int8,
        maker_fee -> Int8,
        tick_size -> Int8,
        lot_size -> Int8,
        min_size -> Int8,
        whitelisted_pool -> Bool,
        treasury_address -> Text,
    }
}

diesel::table! {
    pools (pool_id) {
        pool_id -> Text,
        pool_name -> Text,
        base_asset_id -> Text,
        base_asset_decimals -> Int2,
        base_asset_symbol -> Text,
        base_asset_name -> Text,
        quote_asset_id -> Text,
        quote_asset_decimals -> Int2,
        quote_asset_symbol -> Text,
        quote_asset_name -> Text,
        min_size -> Int8,
        lot_size -> Int8,
        tick_size -> Int8,
    }
}

diesel::table! {
    proposals (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_id -> Text,
        balance_manager_id -> Text,
        epoch -> Int8,
        taker_fee -> Int8,
        maker_fee -> Int8,
        stake_required -> Int8,
    }
}

diesel::table! {
    protocol_fees_increased (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        margin_pool_id -> Text,
        total_shares -> Int8,
        referral_fees -> Int8,
        maintainer_fees -> Int8,
        protocol_fees -> Int8,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    protocol_fees_withdrawn (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        margin_pool_id -> Text,
        protocol_fees -> Int8,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    rebates (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_id -> Text,
        balance_manager_id -> Text,
        epoch -> Int8,
        claim_amount -> Int8,
    }
}

diesel::table! {
    referral_fee_events (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_id -> Text,
        referral_id -> Text,
        base_fee -> Int8,
        quote_fee -> Int8,
        deep_fee -> Int8,
    }
}

diesel::table! {
    referral_fees_claimed (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        referral_id -> Text,
        owner -> Text,
        fees -> Int8,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    stakes (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_id -> Text,
        balance_manager_id -> Text,
        epoch -> Int8,
        amount -> Int8,
        stake -> Bool,
    }
}

diesel::table! {
    sui_error_transactions (id) {
        id -> Int4,
        txn_digest -> Text,
        sender_address -> Text,
        timestamp_ms -> Int8,
        failure_status -> Text,
        package -> Text,
        cmd_idx -> Nullable<Int8>,
    }
}

diesel::table! {
    supplier_cap_minted (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        supplier_cap_id -> Text,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    supply_referral_minted (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        margin_pool_id -> Text,
        supply_referral_id -> Text,
        owner -> Text,
        onchain_timestamp -> Int8,
    }
}

diesel::table! {
    trade_params_update (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_id -> Text,
        taker_fee -> Int8,
        maker_fee -> Int8,
        stake_required -> Int8,
    }
}

diesel::table! {
    votes (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_id -> Text,
        balance_manager_id -> Text,
        epoch -> Int8,
        from_proposal_id -> Nullable<Text>,
        to_proposal_id -> Text,
        stake -> Int8,
    }
}

diesel::table! {
    points (id) {
        id -> Int8,
        address -> Text,
        amount -> Int8,
        week -> Int4,
        timestamp -> Timestamp,
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

diesel::allow_tables_to_appear_in_same_query!(
    asset_supplied,
    asset_withdrawn,
    assets,
    balances,
    collateral_events,
    conditional_order_events,
    deep_burned,
    deepbook_pool_config_updated,
    deepbook_pool_registered,
    deepbook_pool_updated,
    deepbook_pool_updated_registry,
    flashloans,
    interest_params_updated,
    liquidation,
    loan_borrowed,
    loan_repaid,
    maintainer_cap_updated,
    maintainer_fees_withdrawn,
    margin_manager_created,
    margin_manager_state,
    margin_pool_config_updated,
    margin_pool_created,
    margin_pool_snapshots,
    ohclv_1d,
    ohclv_1m,
    order_fills,
    order_updates,
    pause_cap_updated,
    points,
    pool_created,
    pool_prices,
    pools,
    proposals,
    protocol_fees_increased,
    protocol_fees_withdrawn,
    rebates,
    referral_fee_events,
    referral_fees_claimed,
    stakes,
    sui_error_transactions,
    supplier_cap_minted,
    supply_referral_minted,
    trade_params_update,
    votes,
    watermarks,
);
