ALTER TABLE loan_borrowed DROP COLUMN IF EXISTS loan_shares;

ALTER TABLE loan_borrowed ADD COLUMN total_borrow BIGINT NOT NULL DEFAULT 0;
ALTER TABLE loan_borrowed ADD COLUMN total_shares BIGINT NOT NULL DEFAULT 0;

ALTER TABLE loan_borrowed ALTER COLUMN total_borrow DROP DEFAULT;
ALTER TABLE loan_borrowed ALTER COLUMN total_shares DROP DEFAULT;

ALTER TABLE margin_manager_created DROP COLUMN IF EXISTS deepbook_pool_id;
