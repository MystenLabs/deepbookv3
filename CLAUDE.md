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

## Skills & Rules

Claude automatically loads contextual knowledge:
- **Move files** (`packages/**/*.move`) - Code quality rules auto-load
- **Indexer files** (`crates/server/**`, `crates/schema/**`, `crates/indexer/**`) - Indexer rules auto-load

Skills in `.claude/skills/` contain deeper domain knowledge that Claude can reference when needed.

**Important:** Update skills when discovering new insights:
- `.claude/skills/move/SKILL.md` - Move patterns and gotchas
- `.claude/skills/indexer/SKILL.md` - Database optimization and debugging
