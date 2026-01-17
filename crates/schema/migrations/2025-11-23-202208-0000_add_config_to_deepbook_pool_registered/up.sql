-- Add config_json column to deepbook_pool_registered table
ALTER TABLE deepbook_pool_registered ADD COLUMN config_json JSONB;

