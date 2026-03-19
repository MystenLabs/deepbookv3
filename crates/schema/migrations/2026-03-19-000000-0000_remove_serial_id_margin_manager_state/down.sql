-- Reverse: restore serial id as primary key, demote margin_manager_id to unique constraint
ALTER TABLE margin_manager_state DROP CONSTRAINT margin_manager_state_pkey;

ALTER TABLE margin_manager_state ADD COLUMN id BIGSERIAL PRIMARY KEY;

ALTER TABLE margin_manager_state ADD CONSTRAINT unique_margin_manager_id UNIQUE (margin_manager_id);
