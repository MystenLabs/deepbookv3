# Predict Manager Chain Balance Design

**Date:** 2026-04-21
**Scope:** `app/` predict manager identity, balance display, and trade gating
**Status:** Approved

---

## Goal

Use the predict server as the canonical source for resolving a wallet's `PredictManager`, and use direct chain reads as the source for current wallet and manager balances where those reads are more trustworthy than indexed summaries.

## Existing Constraints

- `PredictManager` is a shared object, so it cannot be discovered by wallet ownership lookup alone.
- Manager ownership is currently resolved through the predict server's indexed `GET /managers?owner=...` path.
- Portfolio and trade currently consume indexed `summary.trading_balance`, which is sufficient for historical and derived analytics but not ideal for immediate balance display.
- The app must continue blocking ambiguous owner state when the indexer returns multiple managers.
- Trade should remain conservative: a fresh deposit should not enable trading until the indexer catches up and reports funded indexed state.

## Design

### Manager identity stays server-backed

The app continues to resolve manager existence through the predict server.

- `0` managers => `missing`
- `1` manager => `ready`
- `>1` managers => `duplicate`

This remains the only supported way to identify which manager belongs to a wallet. The client does not attempt to infer manager identity from raw chain object scans.

### Balances split by source of truth

The app uses two balance sources with different responsibilities.

- Server/indexer:
  - manager identity
  - duplicate-manager detection
  - indexed portfolio summary
  - positions, exposure, redeemable value, PnL
  - conservative trade readiness
- Direct chain RPC:
  - connected wallet quote-asset balance
  - selected manager quote-asset balance

This is a hybrid model, not a replacement of indexed state with live RPC everywhere.

### Portfolio behavior

Portfolio becomes the page that shows both indexed state and live balances.

- Wallet side of the transfer rail uses a direct wallet quote-balance read.
- Trading side of the transfer rail uses a direct manager quote-balance read.
- Summary cards and positions remain driven by indexed server data.

If the server resolves:

- `missing`: show setup state and allow `Create manager + deposit`
- `ready`: show live wallet and manager balances and allow deposit / withdraw
- `duplicate`: block transfer actions and show the conflict state

If chain balance reads are unavailable, portfolio should show `—` for those live balances instead of `$0.00`.

### Trade behavior

Trade remains execution-only and uses indexed readiness, not live balance reads, to enable the CTA.

Trade can execute only when all of the following are true:

- connected wallet present
- server resolves exactly one manager
- indexed `trading_balance > 0`

If the manager chain balance is positive but the indexed summary still shows zero, the trade page remains blocked and shows a syncing message rather than enabling trading early.

### Sync mismatch policy

The client may observe temporary disagreement between indexed state and direct chain reads after deposits or withdrawals.

Rules:

- portfolio may display the live chain balance immediately
- trade gating always waits for indexed confirmation
- when chain manager balance is positive but indexed trading balance is zero, show a "syncing" or "indexing" state
- the app does not silently swap trade gating to live chain reads

This keeps execution rules aligned with the indexed portfolio model and avoids mixed-state surprises on the trade page.

## Data Model Changes

Portfolio UI should stop overloading `transferRail.balances` as a generic source for both wallet and manager numbers.

Add explicit client-side live balance state for:

- `walletQuoteBalance`
- `managerQuoteBalance`
- loading / error status for each

Keep server snapshot meta and summary fields for:

- `managerState`
- `managerCount`
- `managerId`
- `quoteAsset`
- `tradingBalance`
- indexed portfolio metrics and positions

The transfer card should render from explicit wallet/manager balance props instead of assuming `balances[0]` means the wallet.

## Error Handling

- No wallet connected: do not query live balances; show connect-wallet state
- Missing manager: do not query manager balance; query wallet balance only if useful for deposit UX
- Duplicate managers: do not query manager balance; show conflict state
- Live chain balance read fails: preserve indexed server snapshot and show `—` or a small status message for live balance fields
- Server manager lookup fails: treat the page as unresolved and do not guess a manager from chain data

## Testing

Add coverage for:

- portfolio live shell fetches wallet quote balance when account and quote asset are present
- portfolio live shell fetches manager quote balance only when indexed manager state is `ready`
- portfolio renders `—` for live balances while loading or on balance-read failure
- portfolio deposit mode shows wallet as source and manager as destination
- portfolio withdraw mode shows manager as source and wallet as destination
- trade remains disabled when chain manager balance is positive but indexed `trading_balance` is still zero
- trade enables only after indexed funded state is returned by the server

## Non-Goals

- Replacing indexed positions, PnL, or exposure with live chain reconstruction
- Inferring manager ownership from direct chain scans
- Enabling trades before the indexer confirms funded manager state
- Solving duplicate-manager uniqueness at the contract level
