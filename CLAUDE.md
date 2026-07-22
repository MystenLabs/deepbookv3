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
- `pnpm install --frozen-lockfile && pnpm format:move` - Format Move code. Run before opening a PR; CI runs the same script (`format:move:check`). Formats every package, which is a no-op outside your own edits. Do NOT use `bunx`/`npx prettier-move` — those fetch whatever plugin version is latest, which formats differently from the version CI pins.

### Indexer
- `cargo build -p deepbook-server` - Build indexer
- `cargo test -p deepbook-server` - Run indexer tests

## Context Routing

**Do not assume these rule files are in your context.** Recent Claude Code versions natively inject a path-scoped rule file (via its `paths:` frontmatter) when you touch a matching file, but treat that as a best-effort assist — other agents (Codex) and older harnesses get no injection. **Before editing a file under one of these globs, make sure you have the matching rule file's content — read it yourself if it was not injected.** Manual-trigger rules must always be read explicitly when the request matches.

### Path-Scoped Rules — read before editing files under the glob

- **Move files** (`packages/**/*.move`) → `.claude/rules/move.md`
- **Predict-cluster contracts** (`packages/{predict,propbook,block_scholes_oracle,account}/**/*.move`) → `.claude/rules/predict-contracts.md` *(also read `move.md`)*
- **Unit tests** (`packages/**/tests/**`) → `.claude/rules/unit-tests.md`
- **Predict unit tests** (`packages/predict/tests/**`) → `.claude/rules/predict-unit-tests.md` *(also read `move.md`, `predict-contracts.md`, and `unit-tests.md`)*
- **Predict harness** (`packages/predict/harness/**`) → `.claude/rules/predict-harness.md`
- **Core indexer** (`crates/{server,schema,indexer}/**`) → `.claude/rules/indexer.md` *(thin stub — retires when the core crates migrate)*
- **Scripts** (`scripts/**`) → `.claude/rules/scripts.md`

### Manual-Trigger Rules — read when the request matches

- **Code review / review uncommitted changes** → `.claude/rules/code-review.md` (for a deep Predict smart-contract audit, invoke the `predict-audit` skill — `.claude/skills/predict-audit/` — which fans the lenses out via `orchestrator.workflow.js`, with `ownership-walk.workflow.js` + `rule-sweep.workflow.js` for per-module + per-rule conformance audits)
- **Wrap-up requests** → `.claude/rules/wrap-up.md`
- **Add / build a harness strategy** → `.claude/rules/harness-strategy.md` (engage when the user wants to add a Predict harness strategy or test a scenario in the harness)

When reviewing code in this repo, always read `.claude/rules/code-review.md` and check against its patterns. When I say "wrap up", follow `.claude/rules/wrap-up.md`. When the user wants to add or build a harness strategy (e.g. "I want to add a harness strategy"), follow `.claude/rules/harness-strategy.md`.

## Predict Design State

Predict (`packages/predict/**`) is the most design-heavy surface, and most decisions here are already settled. **Before proposing or changing any Predict economics** (NAV/backing, rounding, oracle trust, liquidation, order-id/tick encoding, floor/leverage, supply/withdraw):

- **Start at the system map** — `packages/predict/predeploy/README.md` (surfaces, authority order, lifecycle loops). The settled record is `AGENTS.md` ("Predict Rework — LANDED" + settled decisions + **rejected directions**) plus `packages/predict/predeploy/{open-items,response-policies,rounding-policy}.md`. Never re-litigate a rejected direction unless its stated condition is met; check `response-policies.md` before adding, removing, or weakening any guard.
- **The floor model is static-floor knockout** (`floor_shares` = static `F`; no `floor_index`/`terminal_floor_index`; winner = `quantity - floor_shares`; knock-out at `floor_amount / liquidation_ltv`). The exact `current_nav` mark superseded the pre-rework NAV/valuation designs (band/haircut/fee/valuation-pass). The **backing reserve** (D030 floor + λ-buffer, `backing_buffer_lambda`) is a **separate axis** from NAV valuation. Any old text describing a rising / time-varying floor is stale.
- `.claude/predict-design/` and `.redesign/` are **personal scratch only** (working logs, raw generated audit output) — nothing load-bearing lives there. Design docs anywhere are **leads to verify against current HEAD**, not ground truth. Ground truth = Move source + git + `sui move test`.

## Predict Build & Verify

A hard guardrail: run every `sui move build` / `sui move test` **in the main loop, never inside a subagent** — long tests trip the 600s watchdog and the run is lost. Check the **real** exit code via `${PIPESTATUS[0]}` or by grepping the output for `error` / `Test result:`; **never pipe build/test through `tail`** (it reports tail's exit code, masking a build failure). Build Predict with `sui move build --path packages/predict --warnings-are-errors`.

**Important:** Update rule files when discovering new insights during sessions, including:
- Bug fixes and their root causes
- Performance issues and solutions
- Database/query gotchas (type mismatches, missing indices)
- Deployment issues (Pulumi conflicts, Kubernetes errors)
- API quirks (default values, missing pagination)
- Any debugging knowledge that would help future sessions

## PR Descriptions

When asked for a PR summary/description, or when creating a PR, always use this format:
- **Summary**: Bullet points describing what changed
- **Why**: Bullet points describing why the PR exists: the problem, pressure, or intent behind the change; do not repeat the summary
- **Test plan**: Checklist of manual or automated verification steps

When creating a PR with `gh pr create`, always ask the user for a branch name before creating the branch. Format the body as:
```
## Summary
- <bullet points>

## Why
- <why this PR exists: problem, pressure, or intent>

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
