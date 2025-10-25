-- Drop indexes for margin_manager_created table
DROP INDEX IF EXISTS idx_margin_manager_created_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_margin_manager_created_margin_manager_id;
DROP INDEX IF EXISTS idx_margin_manager_created_balance_manager_id;
DROP INDEX IF EXISTS idx_margin_manager_created_owner;

-- Drop indexes for loan_borrowed table
DROP INDEX IF EXISTS idx_loan_borrowed_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_loan_borrowed_margin_manager_id;
DROP INDEX IF EXISTS idx_loan_borrowed_margin_pool_id;

-- Drop indexes for loan_repaid table
DROP INDEX IF EXISTS idx_loan_repaid_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_loan_repaid_margin_manager_id;
DROP INDEX IF EXISTS idx_loan_repaid_margin_pool_id;

-- Drop indexes for liquidation table
DROP INDEX IF EXISTS idx_liquidation_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_liquidation_margin_manager_id;
DROP INDEX IF EXISTS idx_liquidation_margin_pool_id;

-- Drop indexes for asset_supplied table
DROP INDEX IF EXISTS idx_asset_supplied_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_asset_supplied_margin_pool_id;
DROP INDEX IF EXISTS idx_asset_supplied_supplier;
DROP INDEX IF EXISTS idx_asset_supplied_asset_type;

-- Drop indexes for asset_withdrawn table
DROP INDEX IF EXISTS idx_asset_withdrawn_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_asset_withdrawn_margin_pool_id;
DROP INDEX IF EXISTS idx_asset_withdrawn_supplier;
DROP INDEX IF EXISTS idx_asset_withdrawn_asset_type;

-- Drop indexes for margin_pool_created table
DROP INDEX IF EXISTS idx_margin_pool_created_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_margin_pool_created_margin_pool_id;
DROP INDEX IF EXISTS idx_margin_pool_created_asset_type;

-- Drop indexes for deepbook_pool_updated table
DROP INDEX IF EXISTS idx_deepbook_pool_updated_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_deepbook_pool_updated_margin_pool_id;
DROP INDEX IF EXISTS idx_deepbook_pool_updated_deepbook_pool_id;

-- Drop indexes for interest_params_updated table
DROP INDEX IF EXISTS idx_interest_params_updated_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_interest_params_updated_margin_pool_id;

-- Drop indexes for margin_pool_config_updated table
DROP INDEX IF EXISTS idx_margin_pool_config_updated_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_margin_pool_config_updated_margin_pool_id;

-- Drop indexes for maintainer_cap_updated table
DROP INDEX IF EXISTS idx_maintainer_cap_updated_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_maintainer_cap_updated_maintainer_cap_id;

-- Drop indexes for deepbook_pool_registered table
DROP INDEX IF EXISTS idx_deepbook_pool_registered_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_deepbook_pool_registered_pool_id;

-- Drop indexes for deepbook_pool_updated_registry table
DROP INDEX IF EXISTS idx_deepbook_pool_updated_registry_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_deepbook_pool_updated_registry_pool_id;

-- Drop indexes for deepbook_pool_config_updated table
DROP INDEX IF EXISTS idx_deepbook_pool_config_updated_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_deepbook_pool_config_updated_pool_id;
