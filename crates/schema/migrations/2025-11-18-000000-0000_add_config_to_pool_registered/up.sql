-- Add config_json column to deepbook_pool_registered table
ALTER TABLE deepbook_pool_registered 
ADD COLUMN config_json JSONB NOT NULL DEFAULT '{}'::jsonb;

-- Create GIN index for efficient JSONB queries
CREATE INDEX idx_deepbook_pool_registered_config 
ON deepbook_pool_registered USING gin(config_json);

-- Remove the default value now that the column exists
ALTER TABLE deepbook_pool_registered 
ALTER COLUMN config_json DROP DEFAULT;

