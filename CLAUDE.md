# DeepBook V3

DeepBook is a decentralized order book on the Sui blockchain.

## Project Structure

- `packages/` - Sui Move smart contracts
- `crates/` - Rust indexer and server
- `scripts/` - TypeScript transaction scripts

## Quick Commands

### Move
- `sui move build` - Build Move packages
- `sui move test --gas-limit 100000000000` - Run Move tests
- `bunx prettier-move -c *.move --write` - Format Move code

### Indexer
- `cargo build -p deepbook-server` - Build indexer
- `cargo test -p deepbook-server` - Run indexer tests

## Auto-Loaded Rules

Claude automatically loads contextual knowledge based on files being edited:
- **Move files** (`packages/**/*.move`) → `.claude/rules/move.md`
- **Indexer files** (`crates/server/**`, `crates/schema/**`, `crates/indexer/**`) → `.claude/rules/indexer.md`
- **Scripts** (`scripts/**`) → `.claude/rules/scripts.md`
- **Unit tests** (`packages/**/tests/**`) → `.claude/rules/unit-tests.md`
- **Code review** (`packages/**/*.move`) → `.claude/rules/code-review.md`

When reviewing code in this repo, always read `.claude/rules/code-review.md` and check against its patterns.

**Important:** Update rule files when discovering new insights during sessions, including:
- Bug fixes and their root causes
- Performance issues and solutions
- Database/query gotchas (type mismatches, missing indices)
- Deployment issues (Pulumi conflicts, Kubernetes errors)
- API quirks (default values, missing pagination)
- Any debugging knowledge that would help future sessions

## PR Descriptions

When asked for a PR summary/description, or when creating a PR, always use this format:
- **Summary**: Bullet points describing what changed and why
- **Test plan**: Checklist of manual or automated verification steps

When creating a PR with `gh pr create`, always ask the user for a branch name before creating the branch. Format the body as:
```
## Summary
- <bullet points>

## Key decisions
- <decisions that teammates should know about: trade-offs, design choices, why something was done a certain way>

## Test plan
- [ ] <checklist items>
```

## Wrap Up

When I say "wrap up", follow the instructions in `.claude/rules/wrap-up.md`.

## Behavioral Guidelines

Guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them. Don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it. Don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
