-- Remove config_json column from deepbook_pool_registered table
ALTER TABLE deepbook_pool_registered DROP COLUMN IF EXISTS config_json;

