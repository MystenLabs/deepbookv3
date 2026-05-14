CREATE TABLE IF NOT EXISTS materialized_view_refresh_watermarks
(
    view_name                 TEXT      PRIMARY KEY,
    timestamp_ms_hi_inclusive BIGINT    NOT NULL,
    updated_at                TIMESTAMP NOT NULL DEFAULT NOW()
);
