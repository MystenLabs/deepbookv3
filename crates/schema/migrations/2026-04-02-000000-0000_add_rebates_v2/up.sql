-- RebateEventV2 - tracks rebate claims with base/quote/deep breakdown
CREATE TABLE rebates_v2 (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    pool_id                     TEXT        NOT NULL,
    balance_manager_id          TEXT        NOT NULL,
    epoch                       BIGINT      NOT NULL,
    claim_base                  BIGINT      NOT NULL,
    claim_quote                 BIGINT      NOT NULL,
    claim_deep                  BIGINT      NOT NULL
);

CREATE INDEX idx_rebates_v2_pool ON rebates_v2(pool_id);
CREATE INDEX idx_rebates_v2_balance_manager ON rebates_v2(balance_manager_id);
CREATE INDEX idx_rebates_v2_checkpoint ON rebates_v2(checkpoint);
