ALTER TABLE oracle_created ADD COLUMN IF NOT EXISTS predict_id TEXT;

WITH oracle_predict_candidates AS (
    SELECT oracle_id, predict_id, checkpoint, tx_index, event_index
    FROM position_minted
    UNION ALL
    SELECT oracle_id, predict_id, checkpoint, tx_index, event_index
    FROM position_redeemed
    UNION ALL
    SELECT oracle_id, predict_id, checkpoint, tx_index, event_index
    FROM range_minted
    UNION ALL
    SELECT oracle_id, predict_id, checkpoint, tx_index, event_index
    FROM range_redeemed
    UNION ALL
    SELECT oracle_id, predict_id, checkpoint, tx_index, event_index
    FROM oracle_ask_bounds_set
    UNION ALL
    SELECT oracle_id, predict_id, checkpoint, tx_index, event_index
    FROM oracle_ask_bounds_cleared
),
latest_oracle_predict AS (
    SELECT DISTINCT ON (oracle_id)
        oracle_id,
        predict_id
    FROM oracle_predict_candidates
    ORDER BY oracle_id, checkpoint DESC, tx_index DESC, event_index DESC
)
UPDATE oracle_created AS oc
SET predict_id = latest_oracle_predict.predict_id
FROM latest_oracle_predict
WHERE oc.oracle_id = latest_oracle_predict.oracle_id
  AND oc.predict_id IS NULL;

UPDATE oracle_created
SET predict_id = (
    SELECT predict_id
    FROM predict_created
    ORDER BY checkpoint DESC, tx_index DESC, event_index DESC
    LIMIT 1
)
WHERE predict_id IS NULL
  AND EXISTS (SELECT 1 FROM predict_created);

ALTER TABLE oracle_created
    ALTER COLUMN predict_id SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_oracle_created_predict_id_event_order
    ON oracle_created (predict_id, checkpoint DESC, tx_index DESC, event_index DESC);

CREATE INDEX IF NOT EXISTS idx_oracle_prices_updated_oracle_id_event_order
    ON oracle_prices_updated (oracle_id, checkpoint_timestamp_ms DESC, tx_index DESC, event_index DESC);

CREATE INDEX IF NOT EXISTS idx_oracle_svi_updated_oracle_id_event_order
    ON oracle_svi_updated (oracle_id, checkpoint_timestamp_ms DESC, tx_index DESC, event_index DESC);

CREATE INDEX IF NOT EXISTS idx_position_minted_manager_id_market_order
    ON position_minted (
        manager_id,
        oracle_id,
        expiry,
        strike,
        is_up,
        checkpoint DESC,
        tx_index DESC,
        event_index DESC
    );

CREATE INDEX IF NOT EXISTS idx_position_redeemed_manager_id_market_order
    ON position_redeemed (
        manager_id,
        oracle_id,
        expiry,
        strike,
        is_up,
        checkpoint DESC,
        tx_index DESC,
        event_index DESC
    );

CREATE INDEX IF NOT EXISTS idx_supplied_predict_id_time
    ON supplied (predict_id, checkpoint_timestamp_ms ASC, tx_index ASC, event_index ASC);

CREATE INDEX IF NOT EXISTS idx_withdrawn_predict_id_time
    ON withdrawn (predict_id, checkpoint_timestamp_ms ASC, tx_index ASC, event_index ASC);

CREATE INDEX IF NOT EXISTS idx_quote_asset_enabled_predict_event_order
    ON quote_asset_enabled (predict_id, checkpoint DESC, tx_index DESC, event_index DESC);

CREATE INDEX IF NOT EXISTS idx_quote_asset_disabled_predict_event_order
    ON quote_asset_disabled (predict_id, checkpoint DESC, tx_index DESC, event_index DESC);
