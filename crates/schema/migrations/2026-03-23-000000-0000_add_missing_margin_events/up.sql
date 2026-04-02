-- CurrentPriceUpdated - tracks when pool prices are updated in the margin registry
CREATE TABLE current_price_updated (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    pool_id                     TEXT        NOT NULL,
    price                       BIGINT      NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

-- PriceToleranceUpdated - tracks when price tolerance settings change
CREATE TABLE price_tolerance_updated (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    pool_id                     TEXT        NOT NULL,
    tolerance                   BIGINT      NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

-- MaxPriceAgeUpdated - tracks when max price age settings change
CREATE TABLE max_price_age_updated (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    pool_id                     TEXT        NOT NULL,
    max_age_ms                  BIGINT      NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE INDEX idx_current_price_updated_pool_id ON current_price_updated(pool_id);
CREATE INDEX idx_current_price_updated_checkpoint ON current_price_updated(checkpoint);

CREATE INDEX idx_price_tolerance_updated_pool_id ON price_tolerance_updated(pool_id);
CREATE INDEX idx_price_tolerance_updated_checkpoint ON price_tolerance_updated(checkpoint);

CREATE INDEX idx_max_price_age_updated_pool_id ON max_price_age_updated(pool_id);
CREATE INDEX idx_max_price_age_updated_checkpoint ON max_price_age_updated(checkpoint);
