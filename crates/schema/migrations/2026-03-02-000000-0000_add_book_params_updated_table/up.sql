CREATE TABLE IF NOT EXISTS book_params_updated
(
    event_digest            TEXT         PRIMARY KEY,
    digest                  TEXT         NOT NULL,
    sender                  TEXT         NOT NULL,
    checkpoint              BIGINT       NOT NULL,
    timestamp               TIMESTAMP    DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT       NOT NULL,
    package                 TEXT         NOT NULL,
    pool_id                 TEXT         NOT NULL,
    tick_size               BIGINT       NOT NULL,
    lot_size                BIGINT       NOT NULL,
    min_size                BIGINT       NOT NULL,
    onchain_timestamp       BIGINT       NOT NULL
);

CREATE INDEX idx_book_params_updated_pool_id ON book_params_updated(pool_id);
CREATE INDEX idx_book_params_updated_checkpoint ON book_params_updated(checkpoint);
