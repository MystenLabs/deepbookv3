CREATE TABLE referral_fee_events (
    event_digest TEXT PRIMARY KEY,
    digest TEXT NOT NULL,
    sender TEXT NOT NULL,
    checkpoint BIGINT NOT NULL,
    timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
    checkpoint_timestamp_ms BIGINT NOT NULL,
    package TEXT NOT NULL,
    pool_id TEXT NOT NULL,
    referral_id TEXT NOT NULL,
    base_fee BIGINT NOT NULL,
    quote_fee BIGINT NOT NULL,
    deep_fee BIGINT NOT NULL
);

CREATE INDEX idx_referral_fee_events_pool_id ON referral_fee_events (pool_id);
CREATE INDEX idx_referral_fee_events_referral_id ON referral_fee_events (referral_id);
CREATE INDEX idx_referral_fee_events_checkpoint_timestamp_ms ON referral_fee_events (checkpoint_timestamp_ms);
