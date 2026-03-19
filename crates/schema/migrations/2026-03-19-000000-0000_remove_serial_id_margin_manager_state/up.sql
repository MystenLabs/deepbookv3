-- Drop the serial id column and make margin_manager_id the primary key.
-- The id sequence has exhausted its 32-bit range (2,147,483,647) because
-- INSERT ... ON CONFLICT DO UPDATE consumes a sequence value on every attempt,
-- even when the row already exists and gets updated instead of inserted.
-- Since margin_manager_id is already unique (via unique_margin_manager_id constraint),
-- we promote it to primary key and drop the unnecessary serial id.

-- Drop the old primary key (id column + sequence)
ALTER TABLE margin_manager_state DROP COLUMN id;

-- Drop the existing unique constraint (will be replaced by primary key)
ALTER TABLE margin_manager_state DROP CONSTRAINT IF EXISTS unique_margin_manager_id;

-- Make margin_manager_id the primary key
ALTER TABLE margin_manager_state ADD PRIMARY KEY (margin_manager_id);
