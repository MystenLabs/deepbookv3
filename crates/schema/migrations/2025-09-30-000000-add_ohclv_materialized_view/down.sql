-- Drop OHCLV materialized view and related objects

DROP PROCEDURE IF EXISTS incremental_refresh_ohclv(BIGINT, BIGINT);

DROP FUNCTION IF EXISTS refresh_ohclv_data();

DROP INDEX IF EXISTS idx_ohclv_pool_interval_time;
DROP INDEX IF EXISTS idx_ohclv_time;
DROP INDEX IF EXISTS idx_ohclv_pool_time;

DROP MATERIALIZED VIEW IF EXISTS ohclv_data;

DROP TYPE IF EXISTS time_interval;