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
        lower_tick -> Int8,
        higher_tick -> Int8,
        leverage -> Int8,
        entry_probability -> Int8,
        quantity -> Numeric,
        net_premium -> Numeric,
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

diesel::table! {
    predict_manager_created (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        predict_manager_id -> Text,
        balance_manager_id -> Text,
        owner -> Text,
    }
}

diesel::table! {
    builder_code_created (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        builder_code_id -> Text,
        owner -> Text,
        builder_code_index -> Numeric,
    }
}

diesel::table! {
    builder_code_set (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        predict_manager_id -> Text,
        owner -> Text,
        builder_code_id -> Nullable<Text>,
    }
}

diesel::table! {
    predict_trade_cap_minted (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        predict_manager_id -> Text,
        cap_id -> Text,
    }
}

diesel::table! {
    predict_deposit_cap_minted (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        predict_manager_id -> Text,
        cap_id -> Text,
    }
}

diesel::table! {
    predict_withdraw_cap_minted (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        predict_manager_id -> Text,
        cap_id -> Text,
    }
}

diesel::table! {
    pricing_config_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        protocol_config_id -> Text,
        pyth_spot_freshness_ms -> Int8,
        block_scholes_surface_freshness_ms -> Int8,
    }
}

diesel::table! {
    risk_config_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        protocol_config_id -> Text,
        trade_liquidation_budget -> Int8,
        protocol_reserve_profit_share -> Int8,
    }
}

diesel::table! {
    expiry_cash_template_config_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        protocol_config_id -> Text,
        trading_loss_rebate_rate -> Int8,
    }
}

diesel::table! {
    strike_exposure_template_config_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        protocol_config_id -> Text,
        terminal_floor_index -> Int8,
        liquidation_ltv -> Int8,
        backing_buffer_lambda -> Int8,
        base_fee -> Numeric,
        min_fee -> Numeric,
        min_ask_price -> Numeric,
        max_ask_price -> Numeric,
        expiry_fee_window_ms -> Int8,
        expiry_fee_max_multiplier -> Int8,
    }
}

diesel::table! {
    ewma_config_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        protocol_config_id -> Text,
        alpha -> Int8,
        z_score_threshold -> Int8,
        penalty_rate -> Numeric,
        enabled -> Bool,
    }
}

diesel::table! {
    stake_config_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        protocol_config_id -> Text,
        lower_benefit_power -> Numeric,
        upper_benefit_power -> Numeric,
    }
}

diesel::table! {
    trading_paused_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        protocol_config_id -> Text,
        paused -> Bool,
    }
}

diesel::table! {
    market_created (event_digest) {
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
        pool_vault_id -> Text,
        propbook_underlying_id -> Int8,
        expiry -> Int8,
        tick_size -> Numeric,
    }
}

diesel::table! {
    market_config_snapshot (event_digest) {
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
        terminal_floor_index -> Int8,
        liquidation_ltv -> Int8,
        backing_buffer_lambda -> Int8,
        base_fee -> Numeric,
        min_fee -> Numeric,
        min_ask_price -> Numeric,
        max_ask_price -> Numeric,
        expiry_fee_window_ms -> Int8,
        expiry_fee_max_multiplier -> Int8,
        trading_loss_rebate_rate -> Int8,
    }
}

diesel::table! {
    expiry_market_mint_paused_updated (event_digest) {
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
        paused -> Bool,
    }
}

diesel::table! {
    market_settled (event_digest) {
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
        propbook_underlying_id -> Int8,
        expiry -> Int8,
        settlement_price -> Numeric,
        settled_at_ms -> Int8,
    }
}

diesel::table! {
    expiry_cash_rebalanced (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_vault_id -> Text,
        expiry_market_id -> Text,
        amount -> Numeric,
        to_expiry -> Bool,
        target_cash -> Numeric,
        expiry_cash_after -> Numeric,
        idle_balance_after -> Numeric,
        sent_to_expiry_after -> Numeric,
        received_from_expiry_after -> Numeric,
        protocol_reserve_balance_after -> Numeric,
        pending_protocol_profit_after -> Numeric,
    }
}

diesel::table! {
    expiry_cash_received (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_vault_id -> Text,
        expiry_market_id -> Text,
        settlement_price -> Numeric,
        amount -> Numeric,
        idle_balance_after -> Numeric,
        sent_to_expiry_after -> Numeric,
        received_from_expiry_after -> Numeric,
    }
}

diesel::table! {
    expiry_profit_materialized (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_vault_id -> Text,
        expiry_market_id -> Text,
        lp_profit -> Numeric,
        protocol_profit -> Numeric,
        idle_balance_after -> Numeric,
        protocol_reserve_balance_after -> Numeric,
        profit_basis_after -> Numeric,
        pending_protocol_profit_after -> Numeric,
    }
}

diesel::table! {
    deep_staked (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_vault_id -> Text,
        predict_manager_id -> Text,
        amount -> Numeric,
        active_stake_after -> Numeric,
        inactive_stake_after -> Numeric,
    }
}

diesel::table! {
    deep_unstaked (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_vault_id -> Text,
        predict_manager_id -> Text,
        amount -> Numeric,
    }
}

diesel::table! {
    builder_fees_claimed (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        builder_code_id -> Text,
        owner -> Text,
        amount -> Numeric,
    }
}

diesel::table! {
    supply_requested (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_vault_id -> Text,
        predict_manager_id -> Text,
        recipient -> Text,
        request_index -> Int8,
        amount -> Numeric,
    }
}

diesel::table! {
    withdraw_requested (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_vault_id -> Text,
        predict_manager_id -> Text,
        recipient -> Text,
        request_index -> Int8,
        amount -> Numeric,
    }
}

diesel::table! {
    request_cancelled (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_vault_id -> Text,
        predict_manager_id -> Text,
        recipient -> Text,
        request_index -> Int8,
        amount -> Numeric,
        is_supply -> Bool,
    }
}

diesel::table! {
    supply_filled (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_vault_id -> Text,
        predict_manager_id -> Text,
        recipient -> Text,
        request_index -> Int8,
        dusdc_amount -> Numeric,
        shares_minted -> Numeric,
    }
}

diesel::table! {
    withdraw_filled (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_vault_id -> Text,
        predict_manager_id -> Text,
        recipient -> Text,
        request_index -> Int8,
        shares_burned -> Numeric,
        dusdc_amount -> Numeric,
    }
}

diesel::table! {
    flush_executed (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pool_vault_id -> Text,
        epoch -> Int8,
        pool_value -> Numeric,
        total_supply -> Numeric,
        active_market_nav -> Numeric,
        market_count -> Int8,
        idle_balance_before -> Numeric,
        supplies_filled -> Int8,
        withdrawals_filled -> Int8,
        requests_processed -> Int8,
        idle_balance_after -> Numeric,
    }
}

diesel::table! {
    order_state (expiry_market_id, order_id) {
        expiry_market_id -> Text,
        order_id -> Text,
        predict_manager_id -> Nullable<Text>,
        position_root_id -> Nullable<Text>,
        owner -> Nullable<Text>,
        status -> Text,
        replacement_order_id -> Nullable<Text>,
        opened_at_ms -> Int8,
        lower_boundary_index -> Int8,
        higher_boundary_index -> Int8,
        floor_shares -> Numeric,
        quantity -> Numeric,
        sequence -> Int8,
        leverage -> Nullable<Int8>,
        entry_probability -> Nullable<Int8>,
        net_premium -> Nullable<Numeric>,
        updated_at_ms -> Int8,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
    }
}

diesel::table! {
    lp_request_state (pool_vault_id, is_supply, request_index) {
        pool_vault_id -> Text,
        is_supply -> Bool,
        request_index -> Int8,
        predict_manager_id -> Nullable<Text>,
        recipient -> Nullable<Text>,
        requested_amount -> Nullable<Numeric>,
        status -> Text,
        filled_dusdc -> Nullable<Numeric>,
        filled_shares -> Nullable<Numeric>,
        opened_at_ms -> Int8,
        updated_at_ms -> Int8,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
    }
}

diesel::table! {
    market_activity_1h (expiry_market_id, bucket_ms) {
        expiry_market_id -> Text,
        bucket_ms -> Int8,
        mint_count -> Int8,
        mint_quantity -> Numeric,
        mint_premium -> Numeric,
        mint_fees -> Numeric,
        unique_minters -> Int8,
        live_redeem_count -> Int8,
        live_redeem_quantity -> Numeric,
        live_redeem_amount -> Numeric,
        live_redeem_fees -> Numeric,
        settled_redeem_count -> Int8,
        settled_redeem_quantity -> Numeric,
        settled_redeem_payout -> Numeric,
    }
}

diesel::table! {
    vault_flows_1h (pool_vault_id, bucket_ms) {
        pool_vault_id -> Text,
        bucket_ms -> Int8,
        supply_count -> Int8,
        supply_amount -> Numeric,
        shares_minted -> Numeric,
        withdraw_count -> Int8,
        withdraw_amount -> Numeric,
        shares_burned -> Numeric,
        total_supply_after -> Numeric,
        idle_balance_after -> Numeric,
    }
}

diesel::table! {
    liquidation_stats_1h (expiry_market_id, bucket_ms) {
        expiry_market_id -> Text,
        bucket_ms -> Int8,
        liquidated_count -> Int8,
        liquidated_quantity -> Numeric,
        gross_value -> Numeric,
        floor_amount -> Numeric,
        surplus -> Numeric,
        gap -> Numeric,
    }
}

diesel::table! {
    position_cashflow (expiry_market_id, position_root_id) {
        expiry_market_id -> Text,
        position_root_id -> Text,
        predict_manager_id -> Text,
        owner -> Text,
        minted_quantity -> Numeric,
        net_premium -> Numeric,
        mint_fees -> Numeric,
        live_redeem_amount -> Numeric,
        live_redeem_fees -> Numeric,
        live_quantity_closed -> Numeric,
        settled_payout -> Numeric,
        settled_quantity_closed -> Numeric,
        liquidated_quantity_closed -> Numeric,
    }
}

// Oracle-lane tables, written by the standalone oracle-indexer (own watermark
// namespace) into the shared predict DB; see the 2026-06-13 oracle_lane
// migration.
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
    builder_code_created,
    builder_code_set,
    builder_fees_claimed,
    deep_staked,
    deep_unstaked,
    ewma_config_updated,
    expiry_cash_received,
    expiry_cash_rebalanced,
    expiry_cash_template_config_updated,
    expiry_market_mint_paused_updated,
    expiry_profit_materialized,
    flush_executed,
    liquidated_order_redeemed,
    liquidation_stats_1h,
    live_order_redeemed,
    lp_request_state,
    market_activity_1h,
    market_config_snapshot,
    market_created,
    market_settled,
    oracle_bound,
    oracle_source_registered,
    oracle_spot_1m,
    order_liquidated,
    order_minted,
    order_state,
    position_cashflow,
    pyth_observation,
    predict_deposit_cap_minted,
    predict_manager_created,
    predict_trade_cap_minted,
    predict_withdraw_cap_minted,
    pricing_config_updated,
    request_cancelled,
    risk_config_updated,
    settled_order_redeemed,
    stake_config_updated,
    strike_exposure_template_config_updated,
    supply_filled,
    supply_requested,
    trading_paused_updated,
    vault_flows_1h,
    watermarks,
    withdraw_filled,
    withdraw_requested,
);
