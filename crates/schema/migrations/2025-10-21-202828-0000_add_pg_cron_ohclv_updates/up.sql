-- Enable pg_cron 
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- minute candle updates 
SELECT cron.schedule(
    'update_ohclv_1m_recent',
    '* * * * *', -- Every minute
    $$
    CALL update_ohclv_1m(
        (EXTRACT(EPOCH FROM NOW() - INTERVAL '5 minutes') * 1000)::BIGINT,
        (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT
    );
    $$
);

-- daily candle updates 
SELECT cron.schedule(
    'update_ohclv_1d_recent',
    '0 * * * *', -- Every hour at minute 0
    $$
    CALL update_ohclv_1d(
        (EXTRACT(EPOCH FROM NOW() - INTERVAL '2 days') * 1000)::BIGINT,
        (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT
    );
    $$
);

-- weekly full refresh for minute candles 
SELECT cron.schedule(
    'refresh_ohclv_1m_full',
    '0 2 * * 0', 
    $$
    CALL update_ohclv_1m(
        0::BIGINT,
        (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT
    );
    $$
);

-- weekly full refresh for daily candles 
SELECT cron.schedule(
    'refresh_ohclv_1d_full',
    '0 3 * * 0', 
    $$
    CALL update_ohclv_1d(
        0::BIGINT,
        (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT
    );
    $$
);
