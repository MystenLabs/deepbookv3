---
name: stacked-prs
description: Default shape for every pull request in this repository — split a change into a two-layer stack, code first (Move/Rust/TS/Python source, tests, manifests, scripts), then docs and setup (Markdown, package docs, predeploy registers, .claude/, CLAUDE.md, .github/) stacked on top. Use whenever opening, creating, or preparing a pull request here, when asked to split a branch or existing PR into a stack, and when restacking after a lower PR merges or changes. Skip only when the change touches a single layer or the user asks for one PR.
---

# Stacked pull requests: code, then docs

A pull request that mixes Move source with prose makes a code reviewer page through documentation diffs to find the behavior change, and makes a docs reviewer wait on code review. This workflow splits one change into two stacked pull requests so each gets its own reviewer and its own diff, while both still land together.

## Layers

`stack.py` classifies every changed path; the first matching rule wins.

| Layer | Position | Contains |
| --- | --- | --- |
| `code` | bottom, based on `main` | Everything that builds, runs, or is executed: Move sources, tests, `Move.toml`, `Move.lock`, `Published.toml`; Rust, TypeScript, Python; `scripts/`; lockfiles and fixtures |
| `docs` | top, based on the `code` branch | Prose and configuration nothing compiles: any `*.md`, `packages/*/docs/`, `packages/*/predeploy/`, `.claude/`, `CLAUDE.md`, `AGENTS.md`, `.github/` |

Rules the split must keep:

- Tests stay with the code they test, so the code pull request passes CI on its own. Source comments and doc comments are part of the source file and stay in the code layer.
- A docs-layer file the code layer cannot pass CI without moves down to `code` (`--code PATTERN`). Examples: a register edit that renames a pinning test `predeploy/check.py` resolves, or a workflow change a new package needs.
- A layer with no changes is dropped. A single-layer change is one ordinary pull request, not a stack.
- Public documentation lags the code only for the span of the stack: the docs pull request merges immediately after the code pull request, so documentation still lands with the change rather than as deferred follow-up.

## Build the stack

1. Put the complete change on one source branch, rebased on current `origin/main` so the layers apply cleanly. When splitting an existing pull request in place, keep a backup first: `git branch <name>-unsplit <name>`.
2. Review the classification: `python3 .claude/skills/stacked-prs/stack.py plan --source <source>`. Add `--code PATTERN` to every later command to move paths down.
3. Ask the user for one branch name (CLAUDE.md § Pull requests). The code layer uses it as-is and the docs layer appends `-docs`.
4. Build the code layer from the base, staging only its files, then commit: `git switch -C <name> origin/main && python3 .claude/skills/stacked-prs/stack.py apply code --source <source>`.
5. Build the docs layer on top of it, then commit: `git switch -c <name>-docs && python3 .claude/skills/stacked-prs/stack.py apply docs --source <source>`.
6. Prove nothing was lost or duplicated: `python3 .claude/skills/stacked-prs/stack.py verify --source <source>` must print OK on `<name>-docs`.
7. Verify each layer on its own branch. On `<name>`, run the build, tests, and formatter the change needs (CLAUDE.md § Common verification commands). On `<name>-docs`, run `python3 packages/predict/predeploy/check.py` whenever `predeploy/` or Predict docs changed.
8. Push both branches. Use `--force-with-lease` for a rebuilt existing branch, then delete the `-unsplit` backup.

## Open the pull requests

- Code pull request: base `main`, the full repository template, and the usual title (`<scope>: <summary> (DBU-NNN)`).
- Docs pull request: base `<name>`, title `<scope>: document <summary> (DBU-NNN)`, and the same template. Its Summary lists the documentation changes, its Test plan lists the doc checks, and its Risk section says what goes stale if it does not merge right after the code pull request.
- Both bodies start with a `## Stack` section listing the two pull requests in merge order, marking the current one: `1. #<code> code ← this`, `2. #<docs> docs`.
- When splitting an existing pull request, keep its number for the code layer, update its body to the code-only scope, and open the docs pull request new.
- The auto-approve workflow only reviews pull requests that target `main` (`.github/AUTO_APPROVE.md`), so the docs pull request can only be auto-approved after it is retargeted.

## Keep the stack in sync

- Change the code layer: commit on `<name>`, then `git rebase <name> <name>-docs` and push both with `--force-with-lease`.
- Change the docs layer: commit on `<name>-docs` only.
- The code pull request merged: branches are deleted on merge, so GitHub retargets the docs pull request to `main`. Squash merges rewrite the code commits, so record the code branch tip before merging (`CODE_TIP=$(git rev-parse <name>)`). Afterwards run `git fetch origin && git rebase --onto origin/main "$CODE_TIP" <name>-docs`, force-push with lease, and re-apply the `auto-approve` label if it is wanted, since a base change dismisses the bot's review.
- Merge in order, bottom first, and do not let other work land between the two. Never merge on the user's behalf.
