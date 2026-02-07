# DeepBook V3

DeepBook is a decentralized order book on the Sui blockchain.

## Project Structure

- `packages/` - Sui Move smart contracts
- `crates/` - Rust indexer and server
- `scripts/` - TypeScript transaction scripts

## Quick Commands

### Move
- `sui move build` - Build Move packages
- `sui move test` - Run Move tests
- `bunx prettier-move -c *.move --write` - Format Move code

### Indexer
- `cargo build -p deepbook-server` - Build indexer
- `cargo test -p deepbook-server` - Run indexer tests

## Auto-Loaded Rules

Claude automatically loads contextual knowledge based on files being edited:
- **Move files** (`packages/**/*.move`) → `.claude/rules/move.md`
- **Indexer files** (`crates/server/**`, `crates/schema/**`, `crates/indexer/**`) → `.claude/rules/indexer.md`
- **Scripts** (`scripts/**`) → `.claude/rules/scripts.md`

**Important:** Update rule files when discovering new insights during sessions, including:
- Bug fixes and their root causes
- Performance issues and solutions
- Database/query gotchas (type mismatches, missing indices)
- Deployment issues (Pulumi conflicts, Kubernetes errors)
- API quirks (default values, missing pagination)
- Any debugging knowledge that would help future sessions
