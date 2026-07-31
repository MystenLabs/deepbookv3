-- Supports newest-first account history lookups for maker fills.
CREATE INDEX IF NOT EXISTS idx_order_fills_maker_history
    ON order_fills (
        maker_balance_manager_id,
        checkpoint_timestamp_ms DESC,
        checkpoint DESC,
        event_digest COLLATE "C" DESC
    );

-- Supports newest-first account history lookups for taker fills.
CREATE INDEX IF NOT EXISTS idx_order_fills_taker_history
    ON order_fills (
        taker_balance_manager_id,
        checkpoint_timestamp_ms DESC,
        checkpoint DESC,
        event_digest COLLATE "C" DESC
    );
