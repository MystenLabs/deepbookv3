-- Indexes for margin_manager_created table
CREATE INDEX IF NOT EXISTS idx_margin_manager_created_checkpoint_timestamp_ms
    ON margin_manager_created (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_margin_manager_created_margin_manager_id
    ON margin_manager_created (margin_manager_id);

CREATE INDEX IF NOT EXISTS idx_margin_manager_created_balance_manager_id
    ON margin_manager_created (balance_manager_id);

CREATE INDEX IF NOT EXISTS idx_margin_manager_created_owner
    ON margin_manager_created (owner);

-- Indexes for loan_borrowed table
CREATE INDEX IF NOT EXISTS idx_loan_borrowed_checkpoint_timestamp_ms
    ON loan_borrowed (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_loan_borrowed_margin_manager_id
    ON loan_borrowed (margin_manager_id);

CREATE INDEX IF NOT EXISTS idx_loan_borrowed_margin_pool_id
    ON loan_borrowed (margin_pool_id);

-- Indexes for loan_repaid table
CREATE INDEX IF NOT EXISTS idx_loan_repaid_checkpoint_timestamp_ms
    ON loan_repaid (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_loan_repaid_margin_manager_id
    ON loan_repaid (margin_manager_id);

CREATE INDEX IF NOT EXISTS idx_loan_repaid_margin_pool_id
    ON loan_repaid (margin_pool_id);

-- Indexes for liquidation table
CREATE INDEX IF NOT EXISTS idx_liquidation_checkpoint_timestamp_ms
    ON liquidation (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_liquidation_margin_manager_id
    ON liquidation (margin_manager_id);

CREATE INDEX IF NOT EXISTS idx_liquidation_margin_pool_id
    ON liquidation (margin_pool_id);

-- Indexes for asset_supplied table
CREATE INDEX IF NOT EXISTS idx_asset_supplied_checkpoint_timestamp_ms
    ON asset_supplied (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_asset_supplied_margin_pool_id
    ON asset_supplied (margin_pool_id);

CREATE INDEX IF NOT EXISTS idx_asset_supplied_supplier
    ON asset_supplied (supplier);

CREATE INDEX IF NOT EXISTS idx_asset_supplied_asset_type
    ON asset_supplied (asset_type);

-- Indexes for asset_withdrawn table
CREATE INDEX IF NOT EXISTS idx_asset_withdrawn_checkpoint_timestamp_ms
    ON asset_withdrawn (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_asset_withdrawn_margin_pool_id
    ON asset_withdrawn (margin_pool_id);

CREATE INDEX IF NOT EXISTS idx_asset_withdrawn_supplier
    ON asset_withdrawn (supplier);

CREATE INDEX IF NOT EXISTS idx_asset_withdrawn_asset_type
    ON asset_withdrawn (asset_type);

-- Indexes for margin_pool_created table
CREATE INDEX IF NOT EXISTS idx_margin_pool_created_checkpoint_timestamp_ms
    ON margin_pool_created (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_margin_pool_created_margin_pool_id
    ON margin_pool_created (margin_pool_id);

CREATE INDEX IF NOT EXISTS idx_margin_pool_created_asset_type
    ON margin_pool_created (asset_type);

-- Indexes for deepbook_pool_updated table
CREATE INDEX IF NOT EXISTS idx_deepbook_pool_updated_checkpoint_timestamp_ms
    ON deepbook_pool_updated (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_deepbook_pool_updated_margin_pool_id
    ON deepbook_pool_updated (margin_pool_id);

CREATE INDEX IF NOT EXISTS idx_deepbook_pool_updated_deepbook_pool_id
    ON deepbook_pool_updated (deepbook_pool_id);

-- Indexes for interest_params_updated table
CREATE INDEX IF NOT EXISTS idx_interest_params_updated_checkpoint_timestamp_ms
    ON interest_params_updated (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_interest_params_updated_margin_pool_id
    ON interest_params_updated (margin_pool_id);

-- Indexes for margin_pool_config_updated table
CREATE INDEX IF NOT EXISTS idx_margin_pool_config_updated_checkpoint_timestamp_ms
    ON margin_pool_config_updated (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_margin_pool_config_updated_margin_pool_id
    ON margin_pool_config_updated (margin_pool_id);

-- Indexes for maintainer_cap_updated table
CREATE INDEX IF NOT EXISTS idx_maintainer_cap_updated_checkpoint_timestamp_ms
    ON maintainer_cap_updated (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_maintainer_cap_updated_maintainer_cap_id
    ON maintainer_cap_updated (maintainer_cap_id);

-- Indexes for deepbook_pool_registered table
CREATE INDEX IF NOT EXISTS idx_deepbook_pool_registered_checkpoint_timestamp_ms
    ON deepbook_pool_registered (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_deepbook_pool_registered_pool_id
    ON deepbook_pool_registered (pool_id);

-- Indexes for deepbook_pool_updated_registry table
CREATE INDEX IF NOT EXISTS idx_deepbook_pool_updated_registry_checkpoint_timestamp_ms
    ON deepbook_pool_updated_registry (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_deepbook_pool_updated_registry_pool_id
    ON deepbook_pool_updated_registry (pool_id);

-- Indexes for deepbook_pool_config_updated table
CREATE INDEX IF NOT EXISTS idx_deepbook_pool_config_updated_checkpoint_timestamp_ms
    ON deepbook_pool_config_updated (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_deepbook_pool_config_updated_pool_id
    ON deepbook_pool_config_updated (pool_id);
