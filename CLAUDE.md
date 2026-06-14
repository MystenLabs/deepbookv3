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
- `bunx prettier-move -c path/to/file.move --write` - Format Move code

### Indexer
- `cargo build -p deepbook-server` - Build indexer
- `cargo test -p deepbook-server` - Run indexer tests

## Context Routing

**These rule files are NOT auto-loaded.** The `paths:` frontmatter on each rule file is a machine-readable map for a `UserPromptSubmit` hook — but unless that hook is configured in `.claude/settings.json`, nothing loads these for you. **Before editing a file under one of these globs, open and read the matching rule file yourself.** Manual-trigger rules must likewise be read when the request matches.

### Path-Scoped Rules — read before editing files under the glob

- **Move files** (`packages/**/*.move`) → `.claude/rules/move.md`
- **Unit tests** (`packages/**/tests/**`) → `.claude/rules/unit-tests.md`
- **Predict simulations** (`packages/predict/simulations/**`) → `.claude/rules/predict-simulations.md`
- **Core indexer** (`crates/{server,schema,indexer}/**`) → `.claude/rules/indexer.md`
- **Predict indexer** (`crates/predict-{server,schema,indexer}/**`) → `.claude/rules/predict-indexer.md` *(also read `indexer.md` for shared operational gotchas)*
- **Scripts** (`scripts/**`) → `.claude/rules/scripts.md`

### Manual-Trigger Rules — read when the request matches

- **Code review / review uncommitted changes** → `.claude/rules/code-review.md` (for a deep Predict protocol review it routes you on to the `.claude/predict-review/` lenses + `rule-auditor.md`)
- **Wrap-up requests** → `.claude/rules/wrap-up.md`

When reviewing code in this repo, always read `.claude/rules/code-review.md` and check against its patterns. When I say "wrap up", follow `.claude/rules/wrap-up.md`.

## Predict Design State

Predict (`packages/predict/**`) is the most design-heavy surface, and most decisions here are already settled. **Before proposing or changing any Predict economics** (NAV/backing, rounding, oracle trust, liquidation, order-id/tick encoding, floor/leverage, supply/withdraw):

- **grep `.claude/predict-design/DECISION_JOURNAL.md` and `HISTORY.md`** for prior rulings first. Never re-open a `rejected` decision unless its `don't-revisit-unless` condition is met.
- The **landed** state + the current settled-decision list live in `AGENTS.md` ("Predict Rework — LANDED" + "Settled design decisions") — read that block, since Claude does not auto-load `AGENTS.md`. The async NAV/LP + tick re-encode + oracle-extraction rework has shipped on this branch, so `DECISION_JOURNAL.md`'s pre-rework LP/NAV/backing entries (e.g. D024/D030 Σ/λ backing) are **superseded** by the landed exact-`current_nav` design — treat them as history. `.redesign/ASYNC_NAV_REDESIGN.md` is the design rationale for that landed system.
- Design docs are **leads to verify against current HEAD**, not ground truth. Ground truth = Move source + git + `sui move test`.

@.claude/predict-design/ROUNDING_POLICY.md

## Predict Build & Verify

A hard guardrail (documented in DECISION_JOURNAL D004): run every `sui move build` / `sui move test` **in the main loop, never inside a subagent** — long tests trip the 600s watchdog and the run is lost. Check the **real** exit code via `${PIPESTATUS[0]}` or by grepping the output for `error` / `Test result:`; **never pipe build/test through `tail`** (it reports tail's exit code, masking a build failure). Build Predict with `sui move build --path packages/predict --warnings-are-errors`.

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

## Linear

The Linear API key is in `.env` as `LINEAR_API_KEY` — use it (via `source .env`) for issue creation/lookup against `https://api.linear.app/graphql`.

- Repo's project: **Deepbook Maintenance** (id `1fa68715-f85f-4e4c-bdfe-38b9fbf7be40`) under team **DeFi** / key `DBU` (id `fa06ddc0-54b9-4a24-b1ed-06dee49e0c1b`).
- To auto-link a PR to a Linear issue, include the issue identifier (e.g. `DBU-402`) in the branch name or PR title.

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
- During reviews and refactors, actively look for simplifications where the code is already revealing a cleaner shape: mirrored structs, copy-through helpers, repeated field groups, or wrappers that only shuttle the same data around.

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
