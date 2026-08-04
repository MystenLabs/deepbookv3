# DeepBook V3

DeepBook V3 is a decentralized order book on Sui. This file is the canonical entry point for coding agents; `AGENTS.md` is a relative symlink to it so every agent reads the same repository guidance.

## Authority and context

- Source and tests own executable behavior.
- Tracked decision records own settled design choices and revisit conditions.
- `.claude/rules/` owns editing and workflow directives scoped by path or task.
- Package documentation owns public explanations of current behavior.
- When sources disagree, verify against source and tests, then fix or record the lower-authority drift rather than copying another version of the fact.

Use repository-relative pointers instead of copying facts between context files. Local Markdown links are for navigable documents; backticks are for source paths, commands, and identifiers.

## Repository map

- `packages/` contains Sui Move packages.
- `crates/` contains the DeepBook indexer, server, and schema crates.
- `scripts/` contains protocol package-upgrade transactions and SDK examples.
- `.claude/rules/` contains scoped contributor guidance.
- `.claude/skills/` contains explicitly invoked specialist workflows.

## Context routing

Do not assume a scoped rule is already in context. Claude Code may inject a rule through its `paths:` frontmatter, while Codex and other agents may not; before editing a matching file, open the rule yourself if it was not injected. Manual-trigger rules must always be read when the task matches.

### Path-scoped rules

| Files or surface | Required guidance |
| --- | --- |
| Move source and package manifests | [Sui Move instructions](.claude/rules/move.md) |
| Predict, Propbook, and Account Move contracts | [Predict contract rules](.claude/rules/predict-contracts.md) and [Sui Move instructions](.claude/rules/move.md) |
| Move unit tests | [Unit-test rules](.claude/rules/unit-tests.md) |
| Predict localnet harness | [Predict harness rules](.claude/rules/predict-harness.md) |
| Core indexer, server, and schema crates | [Indexer rules](.claude/rules/indexer.md) |
| TypeScript transaction scripts | [Scripts rules](.claude/rules/scripts.md) |

### Manual-trigger rules

| Task | Required guidance |
| --- | --- |
| Code review or review of uncommitted changes | [Code-review rules](.claude/rules/code-review.md); for an explicitly approved deep Predict audit, use the [Predict audit skill](.claude/skills/predict-audit/SKILL.md) |
| Add or build a Predict harness strategy | [Harness-strategy workflow](.claude/rules/harness-strategy.md) and [Predict harness rules](.claude/rules/predict-harness.md) |
| Create, change, run, publish, deploy, migrate, resume, audit, or verify a Predict deployment | [Predict deployment rules](.claude/rules/predict-deployment.md), plus [Sui Move instructions](.claude/rules/move.md) when package manifests are involved |
| Wrap up a session | [Wrap-up workflow](.claude/rules/wrap-up.md) |
| Request Codex-gated pull-request approval | [Auto-approval contract](.github/AUTO_APPROVE.md) |

## Predict context

Before proposing or changing Predict economics, start with the [Predict development-system map](packages/predict/predeploy/README.md), then read the linked open-work, response-policy, evidence, and design-decision surfaces required by the task. The [Predict protocol documentation](packages/predict/docs/README.md) explains current public behavior; it does not outrank source, tests, or the development-system authority order.

Treat `.claude/predict-design/`, `.claude/predict-review/`, and `.redesign/` as ignored personal scratch. Nothing another contributor needs to continue the work may live only there.

## Common verification commands

### Move

- Build a package: `sui move build --path packages/<package>`.
- Test a package: `sui move test --path packages/<package> --gas-limit 100000000000`.
- Build Predict with warnings denied: `sui move build --path packages/predict --warnings-are-errors`.
- Format Move before opening a pull request: `pnpm install --frozen-lockfile && pnpm format:move`; do not use `bunx` or `npx` because CI uses the repository-pinned formatter dependency.

Run every `sui move build` and `sui move test` in the main session, not in a subagent. Preserve the command's real exit code; do not pipe a build or test through `tail`.

### Rust

- Build the server: `cargo build -p deepbook-server`.
- Test the server: `cargo test -p deepbook-server`.

### JavaScript and TypeScript

- Lint: `pnpm run lint`.
- Format: `pnpm run prettier:fix`.

## Updating context

Route durable information to one owner instead of appending it wherever it was discovered:

| Information | Owner |
| --- | --- |
| General or path-specific contributor directive | The matching file under `.claude/rules/` |
| Component behavior or interface fact | Source, tests, or the owning package README |
| Settled Predict mechanism decision or rejected direction | [Predict design decisions](packages/predict/docs/design/decisions.md) |
| Settled Predict response to a degenerate or adversarial state | [Predict response-policy register](packages/predict/predeploy/response-policies.md) |
| Unresolved Predict finding or experiment plan | [Predict open-items register](packages/predict/predeploy/open-items.md) |
| Predict measurement | A dated record under `packages/predict/predeploy/evidence/`, following the [predeploy lifecycle](packages/predict/predeploy/README.md) |
| Public Predict explanation or risk | [Predict protocol documentation](packages/predict/docs/README.md) |
| Raw working notes or generated audit output | Ignored scratch only; extract durable results before another contributor needs them |

Before changing repository guidance, check the owning file for an existing rule, name the failure the new directive prevents, and point to source, tests, decisions, or evidence instead of restating their details. When the user asks to wrap up, follow the proposal gate in the [wrap-up workflow](.claude/rules/wrap-up.md).

Context prose uses one physical line per paragraph, list item, and blockquote. YAML frontmatter, fenced code, and tables are exempt.

## Pull requests

Use the repository's [pull-request template](.github/PULL_REQUEST_TEMPLATE.md). Write the summary, motivation, decisions, scope, tests, and risk in plain engineering language that a contributor can understand without access to private repositories or internal context. Include a DBU identifier in the branch name or pull-request title when the work has a Linear ticket; mechanical documentation and configuration chores may be unticketed.
