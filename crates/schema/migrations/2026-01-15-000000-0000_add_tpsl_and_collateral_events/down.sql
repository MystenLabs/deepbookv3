-- Rollback: Remove TPSL and Collateral event tables

DROP TABLE IF EXISTS conditional_order_insufficient_funds;
DROP TABLE IF EXISTS conditional_order_executed;
DROP TABLE IF EXISTS conditional_order_cancelled;
DROP TABLE IF EXISTS conditional_order_added;
DROP TABLE IF EXISTS withdraw_collateral;
DROP TABLE IF EXISTS deposit_collateral;
