# DeepBook Order Wrapper

Thin wrapper package around DeepBook pool actions for best-effort batching.

It exposes conditional helpers that avoid aborting a PTB when:

- a target order is already gone
- a new order no longer has enough available balance

Main entrypoints live in `deepbook_order_wrapper::wrapper`:

- `cancel_order_if_exists`
- `cancel_orders_if_exist`
- `place_limit_order_if_balance_sufficient`
- `place_market_order_if_balance_sufficient`
- `cancel_order_if_exists_then_place_limit_order_if_possible`
- `cancel_order_if_exists_then_place_market_order_if_possible`

Deployment lives alongside the package at `deploy/publish.ts`.

```bash
cd scripts
pnpm tsx ../packages/deepbook_order_wrapper/deploy/publish.ts --dry-run
pnpm tsx ../packages/deepbook_order_wrapper/deploy/publish.ts
```

The deploy script resolves `@deepbook/core` through MVR first, then verifies that the repo's mainnet DeepBook package matches that resolution before publishing this wrapper with `--build-env mainnet`.

This is self-contained inside the repo, but not standalone outside it:

- it expects the DeepBook package at `packages/deepbook`
- it expects the TypeScript tooling from the repo `scripts/` package
