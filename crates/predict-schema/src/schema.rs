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
        block_scholes_prices_freshness_ms -> Int8,
        block_scholes_svi_freshness_ms -> Int8,
    }
}

diesel::table! {
    fee_config_updated (event_digest) {
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
        protocol_reserve_profit_share -> Int8,
        withdraw_fee_alpha -> Int8,
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
        valuation_liquidation_budget -> Int8,
        trade_liquidation_budget -> Int8,
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
    market_oracle_template_config_updated (event_digest) {
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
        settlement_freshness_ms -> Int8,
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
        market_oracle_id -> Text,
        pool_vault_id -> Text,
        pyth_source_id -> Text,
        pyth_lazer_feed_id -> Int8,
        expiry -> Int8,
        min_strike -> Numeric,
        tick_size -> Numeric,
        max_strike -> Numeric,
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
        market_oracle_id -> Text,
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
    market_oracle_config_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        market_oracle_id -> Text,
        settlement_freshness_ms -> Int8,
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
    block_scholes_prices_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        market_oracle_id -> Text,
        spot -> Numeric,
        forward -> Numeric,
        basis -> Numeric,
        source_timestamp_ms -> Int8,
        update_timestamp_ms -> Int8,
    }
}

diesel::table! {
    block_scholes_svi_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        market_oracle_id -> Text,
        a -> Numeric,
        b -> Numeric,
        rho -> Numeric,
        m -> Numeric,
        sigma -> Numeric,
        source_timestamp_ms -> Int8,
        update_timestamp_ms -> Int8,
    }
}

diesel::table! {
    pyth_source_updated (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        pyth_source_id -> Text,
        feed_id -> Int8,
        spot -> Numeric,
        source_timestamp_ms -> Int8,
        update_timestamp_ms -> Int8,
    }
}

diesel::table! {
    market_oracle_settled (event_digest) {
        event_digest -> Text,
        digest -> Text,
        sender -> Text,
        checkpoint -> Int8,
        tx_index -> Int8,
        event_index -> Int8,
        timestamp -> Timestamp,
        checkpoint_timestamp_ms -> Int8,
        package -> Text,
        market_oracle_id -> Text,
        expiry -> Int8,
        settlement_price -> Numeric,
        spot_source -> Int2,
        source_timestamp_ms -> Int8,
        update_timestamp_ms -> Int8,
    }
}

diesel::table! {
    supply_executed (event_digest) {
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
        payment -> Numeric,
        shares_minted -> Numeric,
        pool_value_before -> Numeric,
        incentive_value -> Numeric,
        total_supply_after -> Numeric,
        idle_balance_after -> Numeric,
    }
}

diesel::table! {
    withdraw_executed (event_digest) {
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
        shares_burned -> Numeric,
        payout -> Numeric,
        withdraw_fee -> Numeric,
        pool_value_before -> Numeric,
        total_supply_after -> Numeric,
        idle_balance_after -> Numeric,
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
    }
}

diesel::table! {
    expiry_max_funding_updated (event_digest) {
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
        max_expiry_funding -> Numeric,
        net_funding -> Numeric,
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
    trading_loss_rebate_claimed (event_digest) {
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
        trading_fees_paid -> Numeric,
        gross_profit -> Numeric,
        eligible_rebate -> Numeric,
        rebate_amount -> Numeric,
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

diesel::allow_tables_to_appear_in_same_query!(
    block_scholes_prices_updated,
    block_scholes_svi_updated,
    builder_code_created,
    builder_code_set,
    builder_fees_claimed,
    deep_staked,
    deep_unstaked,
    ewma_config_updated,
    expiry_cash_received,
    expiry_cash_rebalanced,
    expiry_cash_template_config_updated,
    expiry_max_funding_updated,
    expiry_market_mint_paused_updated,
    expiry_profit_materialized,
    fee_config_updated,
    liquidated_order_redeemed,
    live_order_redeemed,
    market_config_snapshot,
    market_created,
    market_oracle_config_updated,
    market_oracle_settled,
    market_oracle_template_config_updated,
    order_liquidated,
    order_minted,
    predict_deposit_cap_minted,
    predict_manager_created,
    predict_trade_cap_minted,
    predict_withdraw_cap_minted,
    pricing_config_updated,
    pyth_source_updated,
    risk_config_updated,
    settled_order_redeemed,
    stake_config_updated,
    strike_exposure_template_config_updated,
    supply_executed,
    trading_loss_rebate_claimed,
    trading_paused_updated,
    watermarks,
    withdraw_executed,
);
