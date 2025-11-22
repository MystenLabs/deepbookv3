-- Remove config_json column from deepbook_pool_registered table
DROP INDEX IF EXISTS idx_deepbook_pool_registered_config;
ALTER TABLE deepbook_pool_registered DROP COLUMN config_json;

