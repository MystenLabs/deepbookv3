---
paths:
  - "crates/server/**"
  - "crates/schema/**"
  - "crates/indexer/**"
---

# Indexer Development Rules

When working on the indexer, refer to `.claude/skills/indexer/SKILL.md` for detailed knowledge about:
- Database query patterns and performance optimization
- Recommended indices for slow queries
- Diesel migration best practices
- Common issues (504 timeouts, TransactionExpiration errors)

## Quick Reference

### Key Files
- `crates/server/src/server.rs` - Route handlers
- `crates/server/src/reader.rs` - Database queries
- `crates/schema/migrations/` - Diesel migrations

### Common Commands
- Build: `cargo build -p deepbook-server`
- Test: `cargo test -p deepbook-server`

### Migration Notes
- Cannot use `CREATE INDEX CONCURRENTLY` in Diesel migrations (runs in transaction)
- Use `IF NOT EXISTS` for idempotent migrations
