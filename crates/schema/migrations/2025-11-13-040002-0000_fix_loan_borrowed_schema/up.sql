ALTER TABLE loan_borrowed DROP COLUMN IF EXISTS total_borrow;
ALTER TABLE loan_borrowed DROP COLUMN IF EXISTS total_shares;

ALTER TABLE loan_borrowed ADD COLUMN loan_shares BIGINT NOT NULL DEFAULT 0;

ALTER TABLE loan_borrowed ALTER COLUMN loan_shares DROP DEFAULT;

ALTER TABLE margin_manager_created ADD COLUMN deepbook_pool_id TEXT;
