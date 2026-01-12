CREATE TABLE IF NOT EXISTS pool_created
(
    event_digest                TEXT         PRIMARY KEY,
    digest                      TEXT         NOT NULL,
    sender                      TEXT         NOT NULL,
    checkpoint                  BIGINT       NOT NULL,
    timestamp                   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT       NOT NULL,
    package                     TEXT         NOT NULL,
    pool_id                     TEXT         NOT NULL,
    taker_fee                   BIGINT       NOT NULL,
    maker_fee                   BIGINT       NOT NULL,
    tick_size                   BIGINT       NOT NULL,
    lot_size                    BIGINT       NOT NULL,
    min_size                    BIGINT       NOT NULL,
    whitelisted_pool            BOOLEAN      NOT NULL,
    treasury_address            TEXT         NOT NULL
);

CREATE INDEX idx_pool_created_pool_id ON pool_created(pool_id);
CREATE INDEX idx_pool_created_checkpoint ON pool_created(checkpoint);
