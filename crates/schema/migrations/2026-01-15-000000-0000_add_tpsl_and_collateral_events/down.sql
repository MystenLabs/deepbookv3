-- Rollback: Remove TPSL and Collateral event tables

DROP TABLE IF EXISTS conditional_order_events;
DROP TABLE IF EXISTS collateral_events;
