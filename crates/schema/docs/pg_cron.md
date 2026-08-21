# pg_cron Setup

**Important**: This SQL script must be run manually outside of a diesel migration.

Due to our production setup being on a different database than the one the cron is run on, we need to run this outside of a diesel migration. The pg_cron extension and scheduled jobs need to be set up on the database instance that will actually execute the cron jobs, which may be separate from the main application database.

## Manual Setup Instructions

1. Connect to the database where pg_cron is installed
2. Use `schedule_in_database` to schedule jobs that will run on the target database
   - Note: If pg_cron is installed on the same database as your application, you can use `schedule()` instead
3. Run the SQL commands below to schedule the OHCLV update jobs

OHLCV writer and reader sessions must use UTC because the `bucket_time` columns do not store a timezone.

The procedure arguments select the buckets to revisit. Each procedure expands that range to complete UTC bucket boundaries before reading `order_fills`, so repeated or overlapping ranges can safely replace an aggregate; the newest bucket is partial only because future fills do not exist yet.

If executions overlap, an older aggregate cannot replace a row whose latest fill timestamp is newer or whose fill count at the same latest timestamp is greater.

An existing candle keeps its opening price unless a newly observed fill has an earlier timestamp; this keeps `open` and `first_trade_timestamp` consistent when checkpoints are committed out of order without reshuffling fills that share a timestamp.

The migration refreshes each procedure's default range. An execution that started before the migration can finish afterward with the previous definition, so allow one subsequent scheduled execution to finish before treating its recent scheduled range as converged; calling each procedure once after the migration commits also establishes that boundary immediately.

-- Enable pg_cron 
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- minute candle updates 
SELECT cron.schedule_in_database(
    'update_ohclv_1m_recent',
    '* * * * *',
    $$
    CALL update_ohclv_1m(
        (EXTRACT(EPOCH FROM NOW() - INTERVAL '5 minutes') * 1000)::BIGINT,
        (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT
    );
    $$,
    'deepbook' -- target database name
);

-- daily candle updates 
SELECT cron.schedule_in_database(
    'update_ohclv_1d_recent',
    '0 * * * *', 
    $$
    CALL update_ohclv_1d(
        (EXTRACT(EPOCH FROM NOW() - INTERVAL '2 days') * 1000)::BIGINT,
        (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT
    );
    $$,
    'deepbook' 
);

-- weekly full refresh for minute candles 
SELECT cron.schedule_in_database(
    'refresh_ohclv_1m_full',
    '0 2 * * 0', 
    $$
    CALL update_ohclv_1m(
        0::BIGINT,
        (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT
    );
    $$,
    'deepbook' 
);

-- weekly full refresh for daily candles 
SELECT cron.schedule_in_database(
    'refresh_ohclv_1d_full',
    '0 3 * * 0', 
    $$
    CALL update_ohclv_1d(
        0::BIGINT,
        (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT
    );
    $$,
    'deepbook' 
);

## Monitoring Cron Jobs

### View Active Jobs
```sql
SELECT * FROM cron.job;
```

### View Job Run Details and Logs
```sql
SELECT * FROM cron.job_run_details 
ORDER BY start_time DESC 
LIMIT 10;
```

### View Specific Job Logs
```sql
SELECT * FROM cron.job_run_details 
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'update_ohclv_1m_recent')
ORDER BY start_time DESC;
```

### View Latest Job Run for Specific Job
```sql
SELECT * FROM cron.job_run_details 
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'update_ohclv_1m_recent')
ORDER BY start_time DESC 
LIMIT 1;
```

### Clean Up Old Logs
```sql
DELETE FROM cron.job_run_details 
WHERE end_time < now() - interval '7 days';
```
