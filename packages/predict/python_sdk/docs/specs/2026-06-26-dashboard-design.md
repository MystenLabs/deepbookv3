# Reimagined Dashboard — Design Spec

- Date: 2026-06-26
- Status: layout approved (v3 mock); pending implementation plan.
- Scope: the `predict-sdk dashboard` command (`predict_sdk/dashboard.py`).

## Context

Today `dashboard.py` is a read-only, **account-centric** Textual TUI (one account's
balances, positions, PnL). We are reimagining it as a full-screen, live
**protocol-observability monitor**: a polished, auto-refreshing superset of
`predict-sdk status` that gives clear at-a-glance visibility into protocol health, the
per-cadence market lifecycle, oracle freshness, and keeper/operational status.

Per `docs/data-architecture.md` (D010), `status` and `dashboard` derive live state from
the same on-chain snapshot; this spec is the dashboard side of that.

## Goals

- At-a-glance answer to "is the protocol healthy and are the keepers keeping up."
- Keep the `status` cadence-box motif (expired · live · upcoming, per cadence) as the
  visual hero, but full-screen, color-coded, and live.
- Surface **operational health** (settlement backlog, unfunded markets, oracle-feeder
  heartbeat) and a derived **attention** summary.
- Auto-refresh; degrade gracefully on any source outage; read-only (no trading).
- Reuse existing data plumbing (on-chain snapshot, indexer, status report) — no bespoke
  reads.

## Non-goals (deferred, not this spec)

- Backing/solvency and risk/liquidations panels, and PLP/flush detail — the separate
  data effort owns these.
- Trends/sparkline band, fees/revenue panel, config-snapshot panel (not selected; easy
  to add later).
- Account/portfolio view *in the dashboard* — the protocol monitor replaces the default
  `dashboard`; the account positions/PnL/balances view stays available via the
  `positions` and `account` CLI commands. An in-dashboard account section is revisited
  later (it pairs with the deferred solvency/PLP work).

## Approved layout (v3)

```
╭─ PREDICT  testnet · BTC_USD · chain 4c78 ───────────────  ● LIVE   14:03:22  ↻10s lag2s ─╮
╰──────────────────────────────────────────────────────────────────────────────────────────╯
  ⚠ ATTENTION   ⌛ settlement backlog 2 · oldest 8m    ⚡ 1m·14:04 unfunded    ✓ oracle fresh
  PROTOCOL      ORACLE        POOL·IDLE     PLP SUPPLY    OPEN INT.     24h VOL
  ● live ✔mint  ● fresh 8s    19,990        20,000        412k +12%     1.2M ▂▅▃▆▄█
  ── 1m ──  · window 3 · 0 live · 1 unfunded ──
   [expired][expired][⚠ UNFUNDED 14:04][next][next]
  ── 5m ──  · window 3 · 1 live ──
   [settled @64,180][⌛ awaiting][● LIVE 3:12 OI120k][next][next]
  ── 1h ──  · window 3 · 1 live · 2 backlog ──
   [settled @63,900][⌛ awaiting][● LIVE 56:48 OI260k][next][next]
  ╭ ORACLE ─────────╮ ╭ KEEPERS · OPS ──────╮ ╭ ACTIVITY · live ───────╮
  │ ● pyth 8s /30s   │ │ settlement 2 await   │ │ 14:03:18 mint 5m 120    │
  │   spot 64,212    │ │   oldest 8m ⌛       │ │ 14:03:05 settle 1h @…    │
  │ ● bs   8s /30s   │ │ unfunded 1m·14:04 ⚡ │ │ 14:02:51 liq  5m −40     │
  │   fwd 64,440     │ │ rebalance funded →+3 │ │ 14:02:30 mint 1m 60      │
  │ fresh · 8s ago   │ │ feeder ● 8s · ckpt N │ │ …                        │
  ╰──────────────────╯ ╰──────────────────────╯ ╰──────────────────────────╯
```

Zones:

1. **Banner + verdict** — network/asset/chain, verdict (● LIVE / ⚠ DEGRADED / ✗ BLOCKED),
   clock, refresh interval, indexer/chain lag.
2. **Attention strip** — derived one-line summary of what needs attention; collapses to a
   single green "✓ all nominal" line when empty (see rules below).
3. **Vitals strip** — protocol live/mintable, oracle freshness, pool idle, PLP supply,
   open interest, 24h volume.
4. **Cadence timelines (hero)** — per cadence (1m/5m/1h…), the 5-slot box row:
   expired/settled (dim) · awaiting-settle (amber) · live (green: progress + TTL + OI) ·
   upcoming (cyan: "opens in"). Unfunded live markets render amber (`⚠ UNFUNDED`).
5. **Oracle panel** — pyth + block-scholes-surface freshness (age / threshold) and
   spot/forward/SVI values.
6. **Keepers · Ops panel** — settlement backlog (count + oldest), unfunded markets,
   rebalance "funded through +N", oracle-feeder heartbeat, valuation state, indexer lag,
   chain checkpoint.
7. **Activity feed** *(follow-up — not in v1)* — recent mints / settlements / liquidations
   (live, newest first); ships once the indexer event-feed wiring (dep 5) lands.

## Data sources

Mapping each zone to its source under the two-plane model (chain snapshot for live state,
indexer for discovery/history, `SuiReadClient` for chain health):

| Zone / field | Source | Status |
|---|---|---|
| Verdict, vitals oracle/pool-idle/PLP | `OnchainSnapshot` (pool, oracle) | available |
| Attention: unfunded, under-backed, stale oracle | snapshot (`cash_balance`, `payout_liability`, oracle ts) | available |
| Cadence window (which markets exist) | indexer `GET /markets` | available (discovery) |
| Cadence box: cash/funded, reference tick, liability, expiry | `OnchainSnapshot` (`MarketSnapshot`) | available |
| Cadence box: settled@price, mint-paused | indexer `GET /markets/{id}/state` today | needs tweak (see deps) |
| Oracle panel (freshness, spot/fwd/svi) | `OnchainSnapshot` (`MarketOracleSnapshot`) | available |
| Keepers: unfunded, rebalance-funded, feeder heartbeat | snapshot (`cash`, oracle `update_timestamp_ms`) | available |
| Keepers: chain checkpoint | `SuiReadClient.latest_checkpoint` → `ChainHealth` | available |
| Vitals OI / 24h vol · activity feed | indexer history (`/open-interest`, `/activity`, order feeds) | needs wiring |
| Attention/keepers: settlement backlog, paused, valuation | mixed | needs tweak |

## Data dependencies (prerequisites — owned by the data consolidation)

The dashboard consumes these; where a field is not yet available it degrades gracefully
(shows "—" / omits the item). To fully realize v3:

1. **Per-market `mint_paused` + settlement (settled flag + price)** in the on-chain
   snapshot getters (today via indexer `/markets/{id}/state`). Needed by the cadence
   "settled @ price" boxes and mintability.
2. **Settlement backlog + oldest-awaiting** derive from *expired & not settled* — needs
   the settled flag from (1).
3. **Protocol gates (`trading_paused`, `valuation_in_progress`) + oracle freshness
   thresholds** — no protocol snapshot in the reader yet; today from indexer `/config`.
   Fine to keep there until consolidation.
4. **Indexer-lag line** — `/status` is off-limits (it proxies chain). Either add a
   DB-only watermark endpoint, or show chain checkpoint + indexer-reachable instead.
5. **History wiring** — OI, 24h volume, activity feed from existing indexer endpoints.

None block the design; they are tracked so the data work and the dashboard converge.

## Architecture

Keep the existing three-layer separation in `dashboard.py` (load → assemble → render):

- **Pure view-model (no Textual, fully offline-testable per D006).** Dataclasses
  assembled from inputs:
  - inputs: `PredictStatusReport` (observability), `OnchainSnapshot` (onchain), indexer
    history rows, `ChainHealth`.
  - derives: vitals row, **attention items** (rules below), **keeper/ops health**, the
    cadence view (reuse observability's timeline computation), activity rows.
- **Thin Textual `App`** — one widget per zone rendering the view-model; an auto-refresh
  worker reusing the existing exclusive "skip if a load is in flight" pattern; a loader
  that gathers inputs off the UI thread.
- **Reuse:** observability's cadence-timeline + slot-state logic; the on-chain snapshot
  reader; indexer clients; the box/colour vocabulary from `render.py`. The cadence hero is
  built as **native Textual widgets** that share the slot-state + box-label logic with
  `render.py` (not embedded `render.py` strings), so it can refresh and grow drill-in later.

## Attention-strip rules (derived, ordered by severity)

Emit an item when true; order red → amber; collapse to green "✓ all nominal" if none:

- ✗ trading paused / protocol blocked
- ✗ oracle stale (any feed past its freshness threshold)
- ⚠ market under-backed (`payout_liability > cash_balance`)
- ⚠ settlement backlog (N expired-unsettled; show oldest age)
- ⚡ unfunded live market(s) (`cash_balance == 0`)
- ⚠ valuation in progress
- ⚠ data source unavailable (snapshot/indexer/oracle outage)

## Refresh & liveness

- Auto-refresh on an interval (configurable; keep current default unless changed); skip
  if a load is already in flight (existing pattern). `r` refresh, `q` quit.
- Show data-as-of: chain checkpoint + clock + indexer lag/reachability.

## Error handling / degradation

Every source fails open: a snapshot error, indexer outage, or missing oracle binding
makes the affected panel show "unavailable" and surfaces in the attention strip; the rest
of the dashboard still renders. Read-only, so stale data is never a safety risk.

## Testing (offline, D006)

- View-model assembly: unit tests with fixture `OnchainSnapshot` + fixture indexer JSON +
  fixture `PredictStatusReport` → assert derived vitals / attention items / keeper health /
  cadence rows. Hand-derived expected values.
- Attention rules: table of (inputs → expected attention items), including the all-nominal
  collapse and each degradation path.
- Textual app: a fake loader returns a fixed view-model; assert widgets populate (mirror
  existing `test_dashboard` patterns). No live RPC.

## Resolved decisions (spec review)

1. **Account view** — the protocol monitor replaces the default `dashboard`;
   account/portfolio stays available via the `positions` / `account` CLI commands.
2. **Activity feed** — deferred to a follow-up. v1 ships the snapshot-driven zones
   (verdict, attention, vitals, cadence hero, oracle, keepers).
3. **Cadence hero** — native Textual widgets, sharing slot-state / box-label logic with
   `render.py`.

## v1 scope

Zones 1–6 (banner/verdict, attention strip, vitals strip, cadence hero, oracle panel,
keepers/ops panel), snapshot- + indexer-discovery-driven, native Textual widgets,
auto-refresh, read-only. The activity feed (zone 7) and the deferred panels follow later.
