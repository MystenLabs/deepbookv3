ALTER TABLE order_updates ALTER COLUMN client_order_id TYPE BIGINT USING client_order_id::BIGINT;
ALTER TABLE order_fills ALTER COLUMN maker_client_order_id TYPE BIGINT USING maker_client_order_id::BIGINT;
ALTER TABLE order_fills ALTER COLUMN taker_client_order_id TYPE BIGINT USING taker_client_order_id::BIGINT;
ALTER TABLE conditional_order_events ALTER COLUMN client_order_id TYPE BIGINT USING client_order_id::BIGINT;
