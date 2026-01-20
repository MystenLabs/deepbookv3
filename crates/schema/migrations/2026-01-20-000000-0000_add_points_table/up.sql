CREATE TABLE points (
    id BIGSERIAL PRIMARY KEY,
    address TEXT NOT NULL,
    amount NUMERIC NOT NULL,
    week INT4 NOT NULL,
    is_add BOOL NOT NULL,
    timestamp TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_points_address ON points (address);
