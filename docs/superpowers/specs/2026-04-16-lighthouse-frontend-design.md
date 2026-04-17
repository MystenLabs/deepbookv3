# Lighthouse — Predict Testnet Frontend Design

**Date:** 2026-04-16
**Codename:** Lighthouse (the frontend)
**Product:** DeepBook Predict (the primitive)
**Scope:** Shareable testnet MVP — a URL Mysten can send to teammates, the waitlist, and Consensus-adjacent demos
**Audience:** Retail-leaning traders + LPs; must not feel like a pro trading terminal

---

## 1. Goals

**Primary:** Ship a live, shareable testnet frontend that lets a non-crypto-native user sign in with Google, fund a testnet trading account, open a directional BTC position, hold it through lifecycle, redeem on win.

**Secondary:** Prove the PLP (Predict Liquidity Provider) loop — supply USDsui, watch vault performance, withdraw. This is half the protocol and must not feel like an afterthought.

**Tertiary:** Seed code the production frontend can grow into — not throwaway, but not over-engineered either. Vibe-coded first pass with bones a team can extend.

**Non-goals (this spec):**
- Range (IN/OUT) markets — the wheel preserves the lock-button hook, but range is hidden and shipped in V2
- Multi-asset (ETH, etc.) — BTC only
- Multi-quote (USDC, etc.) — USDsui only
- Mobile-optimized layout — responsive reflow is best-effort; primary design is desktop
- Gamification layer (leaderboards, badges, streaks) — aspirational per context pack, not MVP
- Mainnet — legal/compliance gating, separate track

---

## 2. Product semantics (canonical from Designer Brief)

- **Directional market:** bet whether BTC settles above or below a single strike at expiry.
- **UP** = settlement **strictly** > strike
- **DOWN** = settlement ≤ strike
- Within one expiry, UP and DOWN are **opposite outcomes of the same market**, not two separate markets.
- **Lifecycle:** Active → Awaiting settlement → Settled. *Expired ≠ settled.* Awaiting-settlement is a real intermediate state (oracle hasn't pushed final price yet), trading is disabled, open positions are safe.
- **Pricing:** oracle pushes BlockScholes SVI parameters 1–2×/sec on-chain. Client recomputes UP/DOWN digital-option prices locally from the live SVI surface. Spread widens with vault utilization.
- **Payout:** binary — $1 per winning contract, $0 per losing contract.
- **Strikes:** BTC $1 increments, $50k–$150k, max 100k unique strikes per expiry.

---

## 3. Information architecture

**Nav shell:** single top bar, 3 tabs.

```
Lighthouse [TESTNET]   Trade   Vault   Portfolio        0x7f3a…c4d2
```

| Route | Purpose |
|---|---|
| `/` → `/trade` | Primary trading experience. Also hosts the positions table at the bottom. |
| `/vault` | PLP / vault page. TVL, PLP share value, performance, utilization, composition, supply/withdraw. |
| `/portfolio` | Account value + PnL chart + trading balance deposit/withdraw. |
| `/signin` (unauthenticated only) | zkLogin landing. Redirects to `/trade` after auth. |

No dedicated "Positions" or "Account" pages — positions live under Trade, identity/session live in a wallet menu off the address pill (or `/portfolio`).

---

## 4. Trade view (primary screen)

### 4.1 Top bar (page-level, below nav)

Three zones:

1. **Left:** `BTC` symbol + status pill (`● Active` / `● Awaiting settlement` / `● Settled`) + underline sublabel ("Oracle · Block Scholes SVI · updates ~1-2s").
2. **Center:** **Expiry chips** — one per active expiry, discovered at runtime from the registry. Each chip shows date (`Apr 24`) and a **minute-resolution** countdown (`in 7d 16h`). Active chip is gold-highlighted. Urgent (<1h to expiry) chips shift to amber. Settling chips shift to a distinct amber state.
3. **Right:** "Trading balance $1,000.00" — tap-through to Portfolio for deposit/withdraw.

### 4.2 Body — chart-as-hero layout

Grid: `1fr 90px 300px` (chart · wheel · quote rail).

**Chart panel:**
- Header row with two zones:
  - Left: big BTC price + 24h change (`$64,218 +1.24%`) + sublabel `BTC spot · 24h`
  - Right: **small, undefined "Settles in" timer** — plain stacked text, no border, no bar. Format: `7d 16h 32m 14s` (seconds dimmed). Below: wall-clock (`Apr 24 · 8:00 UTC`). This is the **only** second-resolution timer on the page.
- 380px chart area: BTC spot over 24h, with a dashed strike line + strike badge at the selected strike. Toggle lets user switch between `BTC Spot` and `UP @ $strike` (the implied option price over time, computed from the historical SVI surface).
- Library: `lightweight-charts` (TradingView's OSS).

**Strike wheel (90px rail between chart and quote):**
- Canvas-based, adapted from `charts_btc.html` (user's prior prototype).
- Vertical scroll with momentum; center item is the selected strike; fade-out toward edges.
- Lock button **hidden** in MVP (reserved for range markets in V2).
- Visible band size: adaptive — at spot ± $N with $1 granularity when zoomed in, bigger bands ($100/$500) when scrolled far.
- Keyboard: arrow keys step by $1; Page Up/Down step by $100.
- Integrates with chart: selected strike updates the dashed line + badge live.

**Quote rail (300px):**
- **Header row** (own card title): left "QUOTE live" uppercase label, right a 20px SVG refresh ring that depletes clockwise over the quote TTL (~3s) and resets. No "Quote refreshes in Xs" text.
- **Selected strike card:** gold-tinted, `Selected strike $64,000`.
- **Side section:** UP / DOWN pills, one above the other, each showing side tag + "BTC > $X" / "BTC ≤ $X" + live ask price. Selected side is border-highlighted (green for UP, red for DOWN).
- **Size section:** big input `$50.00 USDsui` + `≈ 97 contracts` sub + preset chips `$10 / $50 / $100 / Max`.
- **Summary block:** Ask price / Max payout / Spread (three rows).
- **CTA button** (full width): `Buy UP > $64,000 → $50.00`, green for UP, red for DOWN.

### 4.3 Lifecycle state variants

Status pill, timer, and quote rail all shift with lifecycle:

| State | Pill | Timer label | Quote rail header | Rail body | CTA |
|---|---|---|---|---|---|
| **Active** | `● Active` green | `Settles in 7d 16h 32m 14s` | `QUOTE live` + refresh ring | Full quote UI | `Buy UP → $X` |
| **Awaiting** | `● Awaiting settlement` amber | `Expected in ~5m` (static) | `QUOTE paused` + static ring | Notice card: "Waiting for settlement price. Your open positions remain safe." + "Trade next expiry →" | Disabled |
| **Settled** | `● Settled` lavender | `Settled 2h 4m ago` | `OUTCOME — UP won` / `DOWN won` | Your position row + outcome card (`Won +$89` / `Lost -$51`) + settlement price dot pinned on chart | `Redeem` (if won) / `Trade next expiry →` (if lost / no position) |

Chart shows a vertical expiry marker (amber) in Awaiting state; in Settled state the marker turns lavender and a dot+badge pins the final price onto the chart.

### 4.4 Positions table (below trade body, same page)

One row per `(strike, expiry, side)` aggregate — multiple buys collapse into a single row.

**Tabs:** `All · Open · To redeem · History`

**Columns:**
| Column | Content |
|---|---|
| Expiry | Date + countdown (coarse: `in 7d 16h` / `pending...` / `7d ago`) |
| Strike · Side | `$64,000 [UP]` / `$65,500 [DOWN]` (side as colored pill) |
| Qty | Contracts (integer) |
| Cost | Basis (USD) |
| Mark | Live bid from vault — pulsing green dot while market is active; `—` during Awaiting; `$1.0000` / `$0.0000` when Settled |
| P&L | Signed USD with pct; colored green/red |
| Status | Pill: `Active` / `Awaiting` / `Won` / `Lost` |
| Action | `Sell` (active) / disabled (awaiting) / `Redeem $X` (won, lavender CTA) / no button (lost) |

Row tinting: Awaiting amber, Won lavender, Lost 50% faded.

**Footer row:** Total open exposure · Unrealized P&L · Pending-redeem total.

---

## 5. Vault page (`/vault`)

### 5.1 Hero (4-column grid)

- **Title block:** `PLP Vault` + sublabel "Predict Liquidity Provider · underwrites every market"
- **TVL:** `$2,847,216 · +4.8% 7d`
- **PLP value:** `$1.0412 · +1.24% 7d · ~32% APR` *(APR hidden on testnet until real data exists, or shown clearly as illustrative)*
- **Your position:** `1,200.00 PLP ≈ $1,249.44 · +$49.44`

### 5.2 Body (1fr + 320px rail)

**Left column:**

1. **Vault performance chart** — single line, 220px tall, range picker `1D / 1W / 1M / 3M / All`. Green line/fill if PLP value has risen; handles PLP value over time.
2. **Metrics grid — 4 cards:**
   - Utilization `37%` (bar: $1,053k / $2,847k)
   - Available liquidity `$1,794k` (withdrawable now, green bar)
   - Open exposure `$472k` (net directional across markets)
   - Fees · 7d `$18,420` (from spread revenue)
3. **Composition bar:** horizontal stacked bar with legend chips — USDsui / Locked / PnL buffer. *Exact split TBC with backend (Emma); mockup shows placeholder 64% / 28% / 8%.*

**Right rail — Provide liquidity card:**

- Header: "PROVIDE LIQUIDITY" label + Supply/Withdraw toggle.
- Input card: big `$500.00 USDsui` + wallet balance sub + preset chips `25% / 50% / 75% / Max`.
- Arrow divider (`↓`).
- Output card (gold-tinted): "You receive 480.15 PLP at $1.0412 per share".
- Summary block: PLP price / Your share after / Net APR (7d).
- CTA: `Supply $500.00 USDsui` (green).

Withdraw state: inputs swap (PLP → USDsui); output card shows net stable received after any unstaking / slippage considerations (if any — subject to vault contract behavior).

---

## 6. Portfolio page (`/portfolio`)

Intentionally minimal. Two columns, mirrored structure.

### Left column
- **Header:** "ACCOUNT VALUE" label + `$7,486.84` big value + `+$486.84 (+6.96%) all-time` sublabel.
- **PnL chart card:** "PnL OVER TIME" title + range picker `1D / 1W / 1M / 3M / All`. 300px chart area. Live dot pinned to current value with a tooltip (`+$486.84`). Realized + mark-to-market blended series.

### Right column
- **Header:** "TRADING BALANCE" label + `$1,000.00` big value + "USDsui · available to trade" sublabel.
- **Transfer card:** "TRANSFER" header + Deposit/Withdraw toggle. From-lane (Wallet) → swap arrow → To-lane (Trading). Full-width CTA. **No preset chips, no session card, no faucet callout on this page** — keep it lean.

Explicitly **removed** from this page (considered and rejected for scope):
- Hero stat columns (realized PnL / unrealized PnL / fees paid)
- Performance card grid (trades / win rate / avg win / avg loss)
- Balance allocation bar
- Identity card (avatar, email, session pill, Refresh/Copy/Sign-out)
- Faucet callout

Sign-out + session info live in a wallet menu off the address pill in the nav (see §7.3).

---

## 7. Authentication & session

### 7.1 Sign-in page (unauthenticated landing)

Centered card, 420px max-width:
- Gradient logo tile (60×60, gold→orange)
- `Welcome to Lighthouse` heading
- One-paragraph copy: what the product is, sign in → testnet address → fund → trade
- `Sign in with Google` (white button, Google SVG)
- `Sign in with Apple` (dark alt button)
- Footer: "Testnet only · no real funds at risk · gas sponsored. By continuing you agree to the [testnet terms]."

### 7.2 zkLogin flow

- OAuth → JWT (Google/Apple)
- Server route: `POST /api/zklogin/salt` — returns user's salt (persist in Vercel KV / Upstash Redis keyed by JWT `sub`; derive deterministically if not present)
- Server route: `POST /api/zklogin/prove` — proxies to Mysten testnet prover (`prover-dev.mystenlabs.com`)
- Client: derives Sui address from JWT + salt; generates ephemeral keypair bound to `maxEpoch = currentEpoch + 10`; requests ZK proof
- Client: stores ephemeral keypair + proof + max epoch in **sessionStorage** (clears on tab close); `jwt` + `salt` in a secure httpOnly cookie so refresh re-derives cleanly

### 7.3 Session lifecycle

- Session key signs all txs; no popup per trade
- Countdown derived from `maxEpoch - currentEpoch` → wall-clock via Sui system state
- When session is within 10 minutes of expiry → show a small "Session ends soon" toast with a `Refresh` button (re-runs OAuth silently via Google's One Tap if available)
- Expired session → session key is dead; user is prompted to sign in again before any tx
- Wallet menu (click address pill in nav): Email · Address (copy) · Session status + `Refresh` · `Sign out`

### 7.4 Gas

- **Testnet only:** sponsored via a server-side sponsor wallet. Every tx goes through `POST /api/tx/sponsor` which fills the gas object. User never sees "insufficient SUI for gas."
- Mainnet: out of scope; will need a different model.

### 7.5 Faucet (testnet USDsui)

- On first sign-in, if wallet USDsui balance == 0, auto-trigger a faucet mint (`dusdcMint.ts`) via a server route and show a toast: "We minted you 10,000 testnet USDsui to start. Happy trading."
- Manual re-mint via a button in the wallet menu and/or on the Vault page when the user has no wallet balance.

---

## 8. Data architecture

### 8.1 Canonical read contract

The frontend uses a **three-lane read model**:

1. **Public predict-server** for all indexed or summarized UI data.
2. **Browser-side Sui gRPC checkpoint streaming** for live oracle updates.
3. **Direct on-chain reads** only for wallet-local or confirmation-critical data.

This is the lock:

- The public server is the canonical source for rendered protocol state.
- The live stream is the canonical source for sub-second oracle freshness.
- Direct chain reads are a narrow escape hatch, not the default render path.

### 8.2 Public server responsibilities

Everything that feels like a page-level summary should come from the public server, even if the server itself uses chain reads internally.

Required server routes for the MVP:

| Endpoint | Purpose |
|---|---|
| `/predicts/:predict_id/state` | pricing config, risk config, pause state, enabled quote assets |
| `/predicts/:predict_id/oracles` | predict-scoped oracle list for expiry chips and trade boot |
| `/oracles/:oracle_id/state` | initial snapshot of selected oracle + latest price + latest SVI + ask bounds |
| `/managers?owner=0x...` | resolve owner -> manager |
| `/managers/:manager_id/summary` | trading balance, open exposure, redeemable, realized/unrealized PnL, account value |
| `/managers/:manager_id/positions/summary` | aggregated positions table rows |
| `/predicts/:predict_id/vault/summary` | TVL, PLP price, utilization, liquidity, exposure, fees, composition |
| `/predicts/:predict_id/vault/performance?range=...` | vault performance chart series |
| `/managers/:manager_id/pnl?range=...` | portfolio PnL series |

Important correction: the old global `/oracles` route is not a good long-term UI contract if multiple predicts exist. The frontend should consume a predict-scoped oracle route.

### 8.3 Live oracle prices (critical path)

- **Primary:** subscribe to the Sui fullnode checkpoint stream over gRPC using `@mysten/sui/grpc` and `SubscriptionService.SubscribeCheckpoints`.
- **Mechanism:** read checkpoint data, inspect transaction events, filter down to:
  - `OraclePricesUpdated`
  - `OracleSVIUpdated`
  - the selected `oracle_id`
- **Reconnect model:** persist the last processed checkpoint cursor and reconnect from it if the stream terminates.
- **Seed model:** before starting the stream, fetch `/oracles/:oracle_id/state` from the public server and render immediately.
- **Recovery model:** if the stream goes stale, refetch `/oracles/:oracle_id/state` and then resume streaming.
- **Client-side pricing:** from SVI params + spot + time-to-expiry + strike, compute UP price using the normal CDF formula already implemented in `charts_btc.html`. Same for DOWN (= 1 − UP ignoring discount, minus spread). Spread comes from predict config and vault utilization loaded through the server.
- **Refresh ring:** ticks down on a fixed cadence (~3s) independent of the event stream. It represents quote freshness, not raw stream liveness.

### 8.4 Direct on-chain reads

Direct chain reads are still allowed, but they should be narrowly scoped:

- current epoch for zkLogin session expiry math
- wallet USDsui balance
- wallet PLP balance
- transaction confirmation / post-submit polling

The browser should **not** rebuild vault metrics, portfolio PnL, or positions history from raw chain objects.

### 8.5 Transaction flow

- **Buy UP/DOWN:** client builds PTB with `predict::mint_position`, signs with ephemeral key + zkLogin sig, POSTs to sponsor route, sponsor wraps with gas + executes. UI shows pending state → success toast with tx link.
- **Sell (close early):** `predict::redeem_position` (before settlement, vault bids back).
- **Redeem (after settlement):** `predict::redeem_position` with `is_settled=true` → USDsui payout.
- **Supply PLP:** `predict::supply`
- **Withdraw PLP:** `predict::withdraw`
- **Deposit/withdraw trading balance:** `predict::deposit_balance` / `predict::withdraw_balance` on the user's trading sub-account (derived object, MVP = 1 account per user).

---

## 9. Tech stack & repo layout

| Piece | Choice |
|---|---|
| Framework | Next.js 15 (App Router) + TypeScript |
| Styling | Tailwind CSS (with a `colors.ts` for the Lighthouse palette) |
| SDKs | `@mysten/sui`, `@mysten/zklogin` |
| Server state | SWR |
| Client state | Zustand (1 store: selected expiry, strike, side, size) |
| Charts | `lightweight-charts` (TradingView OSS) for spot + PnL chart |
| Strike wheel | Canvas component ported from `charts_btc.html` |
| Hosting | Vercel (instant previews + one-click deploys) |
| Env boundary | `NEXT_PUBLIC_*` for gRPC URL, package ID, registry ID, predict-server URL; server-only for sponsor wallet key |
| Repo | Monorepo — new app at `apps/lighthouse/` (pnpm workspace) alongside `scripts/`, `packages/`, `crates/` |

### 9.1 Palette (dark-first)

| Token | Value | Use |
|---|---|---|
| `bg-base` | `#0a0a14` | page background |
| `bg-surface` | `#12121e` | cards |
| `bg-rail` | `#0e0e18` | right-rail background |
| `border-faint` | `rgba(255,255,255,0.06)` | card borders |
| `accent-gold` | `rgba(220,180,50,0.95)` | primary actions, selected strike, countdowns |
| `accent-green` | `rgba(60,200,120,0.95)` | UP, gains, active state |
| `accent-red` | `rgba(240,100,100,0.9)` | DOWN, losses |
| `accent-amber` | `rgba(240,180,80,0.9)` | urgent/awaiting-settlement |
| `accent-lavender` | `rgba(170,180,240,0.9)` | settled |

### 9.2 File layout (inside `apps/lighthouse/`)

```
apps/lighthouse/
├── package.json
├── next.config.ts
├── tailwind.config.ts
├── tsconfig.json
├── app/
│   ├── layout.tsx              # Nav shell, session providers, zkLogin boundary
│   ├── page.tsx                # → redirect /trade
│   ├── trade/page.tsx          # Trade view + positions table below
│   ├── vault/page.tsx          # Vault / PLP
│   ├── portfolio/page.tsx      # Portfolio
│   ├── signin/page.tsx         # zkLogin landing
│   └── api/
│       ├── zklogin/salt/route.ts
│       ├── zklogin/prove/route.ts
│       ├── tx/sponsor/route.ts
│       └── faucet/mint/route.ts
├── components/
│   ├── nav/TopNav.tsx
│   ├── trade/ExpiryChips.tsx
│   ├── trade/HeroChart.tsx     # wraps lightweight-charts
│   ├── trade/StrikeWheel.tsx   # canvas, ported from charts_btc.html
│   ├── trade/QuoteRail.tsx
│   ├── trade/PositionsTable.tsx
│   ├── trade/LifecycleBanner.tsx
│   ├── vault/VaultHero.tsx
│   ├── vault/PerformanceChart.tsx
│   ├── vault/MetricsGrid.tsx
│   ├── vault/ProvideLiquidityRail.tsx
│   ├── portfolio/PnlChart.tsx
│   ├── portfolio/TransferCard.tsx
│   └── common/{RefreshRing,Countdown,StatusPill,Sparkline}.tsx
├── lib/
│   ├── pricing/svi.ts          # normal CDF + UP/DOWN price from SVI params
│   ├── pricing/spread.ts
│   ├── sui/client.ts           # SuiGrpcClient singleton
│   ├── sui/checkpoints.ts      # checkpoint subscription + cursor resume
│   ├── sui/read.ts             # direct chain reads allowed in-browser
│   ├── sui/ptb.ts              # PTB builders for mint/redeem/supply/withdraw/deposit/withdraw-balance
│   ├── zklogin/session.ts      # ephemeral key lifecycle
│   ├── api/predict-server.ts   # typed REST client
│   └── formatters.ts           # USD, countdown, address shortening
└── store/
    └── trade.ts                # Zustand: expiry, strike, side, size
```

---

## 10. Responsive strategy

Desktop (≥1280px) is the primary design. For narrower viewports:

- **1024–1279px:** chart+wheel+rail stays three-column but sides compress; stats grids go 2×N.
- **768–1023px:** quote rail reflows below the chart as a full-width card; positions table scrolls horizontally.
- **<768px:** not optimized for MVP; show a "Best viewed on desktop" banner (still functional). Mobile optimization is V1.1.

---

## 11. Out of scope (V2+)

- Range markets (IN/OUT between two strikes) — wheel already has the lock-button affordance
- Multi-asset (ETH, SOL) — registry already supports this on-chain, UI just needs an asset selector
- Multi-account per user (contract supports via derived objects; MVP is 1 account)
- Gamification (leaderboards, streaks, badges, duels)
- Mobile-first responsive design
- Wallet connect adapter (existing wallet users) — alongside zkLogin
- Mainnet launch (legal review dependency)
- i18n

---

## 12. Success criteria

Launch-day:
- [ ] A Mysten teammate with no pre-existing Sui wallet can sign in with Google, get a testnet USDsui balance via the auto-faucet, deposit to trading, buy an UP position, see it MTM, and close it for a win/loss — all inside 5 minutes, zero SUI/gas friction
- [ ] The same teammate can supply $100 of USDsui to the PLP vault, see PLP value on the chart, withdraw some
- [ ] Live oracle prices update visibly (quote ring ticks, UP/DOWN prices shift) as BlockScholes pushes to chain
- [ ] All three lifecycle states (Active / Awaiting / Settled) are exercisable on real testnet expiries
- [ ] Shareable URL (Vercel preview or custom domain) works without VPN / Mysten-SSO gating

Two weeks post-launch:
- [ ] ≥50 non-Mysten testnet addresses have traded
- [ ] At least one external waitlist user has completed the full loop (sign in → trade → redeem)
- [ ] Front-end teaser referenced by Amir's May 7 Consensus narrative

---

## 13. Open questions flagged for implementation phase

1. **APR display on testnet:** show "~32% APR" derived from 7d spread revenue / TVL, or hide until real data exists? (Emma / Aslan call.)
2. **Vault composition exact categories:** the "USDsui / Locked / PnL buffer" split is a placeholder — needs reconciliation with vault contract's actual accounting (Emma).
3. **Sponsor wallet funding & rate limit:** sponsor wallet needs auto-top-up + per-user tx rate limit to prevent drainage. Implementation detail for the plan phase.
4. **gRPC provider behavior:** some fullnode gRPC streams can terminate and require reconnect/resume handling. This does not change the architecture, but it must shape the implementation.
5. **Settlement price marker on chart:** is the chart zoomed to the market's full life (listing → expiry), or just 24h? Designer brief implies the former; requires more time-series data than a single latest-state endpoint.
6. **Settled markets still visible?** When a user selects a settled expiry chip, do they see the settled-state view with chart history, or do we hide settled chips entirely? This spec assumes they stay visible and render the Settled state.
7. **Multiple oracle IDs per expiry date?** If the registry rotates (creates new oracles as old ones settle), are there moments where two expiries of the same underlying overlap in the chip bar? Probably yes; handle gracefully.

These don't block spec approval — they surface during implementation.
