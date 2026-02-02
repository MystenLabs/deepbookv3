ALTER TABLE order_updates ALTER COLUMN client_order_id TYPE NUMERIC USING client_order_id::NUMERIC;
ALTER TABLE order_fills ALTER COLUMN maker_client_order_id TYPE NUMERIC USING maker_client_order_id::NUMERIC;
ALTER TABLE order_fills ALTER COLUMN taker_client_order_id TYPE NUMERIC USING taker_client_order_id::NUMERIC;
ALTER TABLE conditional_order_events ALTER COLUMN client_order_id TYPE NUMERIC USING client_order_id::NUMERIC;
