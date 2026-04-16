# Lighthouse Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Lighthouse — a shareable Next.js frontend on Vercel that lets a retail user zkLogin with Google, fund a testnet trading account, open a directional BTC position against DeepBook Predict, see MTM / lifecycle states, redeem on win, and supply/withdraw PLP — all against the predict-testnet-4-16 contracts + `predict-server.testnet.mystenlabs.com` + on-chain oracle event stream.

**Architecture:** Next.js 15 App Router + TypeScript + Tailwind. Server routes proxy zkLogin prover + sponsor gas. Live oracle prices arrive via on-chain `OraclePricesUpdated` / `OracleSVIUpdated` event subscription (WS), with REST fallback. User-level data (positions, balance, vault metrics, PnL history) via SWR against `predict-server`. Client state via Zustand (selected expiry/strike/side/size). Canvas-based strike wheel ported from `charts_btc.html`. `lightweight-charts` for BTC spot + PnL chart.

**Tech Stack:** Next.js 15, TypeScript 5, Tailwind CSS v4, `@mysten/sui`, `@mysten/dapp-kit`, `@mysten/zklogin`, `lightweight-charts`, SWR, Zustand, Vitest, Playwright.

**Spec:** `docs/superpowers/specs/2026-04-16-lighthouse-frontend-design.md`

---

## File Structure

New app under `apps/lighthouse/` (pnpm workspace addition; alongside existing `scripts/`, `packages/`, `crates/`).

```
apps/lighthouse/
├── package.json
├── next.config.ts
├── tailwind.config.ts
├── tsconfig.json
├── postcss.config.mjs
├── vitest.config.ts
├── playwright.config.ts
├── .env.example
├── .env.local                        (gitignored)
├── app/
│   ├── globals.css
│   ├── layout.tsx                    # Root layout: providers, auth boundary, top nav
│   ├── page.tsx                      # → redirect to /trade
│   ├── trade/page.tsx                # Trade view + PositionsTable below
│   ├── vault/page.tsx                # PLP vault
│   ├── portfolio/page.tsx            # Portfolio (account value + PnL chart + transfer)
│   ├── signin/page.tsx               # zkLogin landing (unauthenticated)
│   └── api/
│       ├── zklogin/
│       │   ├── salt/route.ts         # POST — return/persist user salt (Upstash KV)
│       │   └── prove/route.ts        # POST — proxy Mysten testnet prover
│       ├── tx/sponsor/route.ts       # POST — sign + execute sponsored tx
│       └── faucet/mint/route.ts      # POST — mint 10k testnet USDsui to user
├── components/
│   ├── nav/TopNav.tsx
│   ├── nav/WalletMenu.tsx
│   ├── trade/ExpiryChips.tsx
│   ├── trade/HeroChart.tsx           # wraps lightweight-charts
│   ├── trade/StrikeWheel.tsx         # canvas component
│   ├── trade/QuoteRail.tsx
│   ├── trade/PositionsTable.tsx
│   ├── trade/LifecycleBanner.tsx     # awaiting-settlement notice + settled outcome card
│   ├── vault/VaultHero.tsx
│   ├── vault/PerformanceChart.tsx
│   ├── vault/MetricsGrid.tsx
│   ├── vault/CompositionBar.tsx
│   ├── vault/ProvideLiquidityRail.tsx
│   ├── portfolio/AccountValueHeader.tsx
│   ├── portfolio/PnlChart.tsx
│   ├── portfolio/TransferCard.tsx
│   └── common/
│       ├── RefreshRing.tsx
│       ├── Countdown.tsx
│       ├── StatusPill.tsx
│       └── Sparkline.tsx
├── lib/
│   ├── config.ts                     # env -> typed config
│   ├── pricing/
│   │   ├── svi.ts                    # normalCDF + computeUpPrice (port from charts_btc.html)
│   │   ├── spread.ts                 # utilization-aware spread calc
│   │   └── index.ts
│   ├── sui/
│   │   ├── client.ts                 # SuiClient singleton
│   │   ├── events.ts                 # OraclePricesUpdated/SVI subscription + fallback poll
│   │   ├── ptb.ts                    # PTB builders for all user txs
│   │   └── types.ts                  # Move event type guards
│   ├── zklogin/
│   │   ├── session.ts                # ephemeral keypair + maxEpoch math
│   │   ├── oauth.ts                  # Google/Apple client ID + redirect URL
│   │   └── storage.ts                # sessionStorage wrappers
│   ├── api/
│   │   ├── predict-server.ts         # typed fetcher for predict-server endpoints
│   │   └── swr-config.ts
│   └── formatters.ts                 # USD, countdown, address shortening
├── store/
│   └── trade.ts                      # Zustand: expiry, strike, side, size
└── tests/
    ├── unit/
    │   ├── pricing.test.ts
    │   ├── formatters.test.ts
    │   └── session.test.ts
    └── e2e/
        ├── signin.spec.ts
        ├── trade.spec.ts
        └── vault.spec.ts
```

**Design decisions locked in this structure:**
- Pure logic (pricing, formatters, session math) lives in `lib/` with Vitest unit tests. Pure functions are trivially testable; we TDD them strictly.
- React components have **no per-component unit tests** — they're covered by Playwright smoke tests in Checkpoint 9. Rationale: this is a testnet MVP, and unit-testing component render is low-ROI compared to real-browser e2e.
- PTB builders (`lib/sui/ptb.ts`) are pure-ish (they return an unsigned `Transaction`). They get snapshot tests on the serialized PTB shape.
- Server routes are TDD'd via request/response unit tests using Next.js's `NextRequest` mock.

---

## Checkpoint 0 — Workspace & Bootstrap

**Gate at end:** `pnpm --filter lighthouse build` passes; app boots on `pnpm --filter lighthouse dev`; Tailwind palette is in scope; env loads.

### Task 0.1: Add `apps/lighthouse` to the pnpm workspace

**Files:**
- Modify: `pnpm-workspace.yaml`

- [ ] **Step 1:** Inspect current workspace config.

```bash
cat pnpm-workspace.yaml
```

- [ ] **Step 2:** Add `apps/*` to `packages:` if not present.

```yaml
packages:
  - scripts
  - apps/*
```

If the file already lists other workspaces, add `apps/*` as a new entry without removing the existing ones.

- [ ] **Step 3:** Create the `apps/lighthouse` directory.

```bash
mkdir -p apps/lighthouse
```

- [ ] **Step 4:** Commit.

```bash
git add pnpm-workspace.yaml
git commit -m "chore(workspace): register apps/* in pnpm workspace"
```

### Task 0.2: Bootstrap the Next.js 15 app

**Files:**
- Create: `apps/lighthouse/package.json`
- Create: `apps/lighthouse/next.config.ts`
- Create: `apps/lighthouse/tsconfig.json`
- Create: `apps/lighthouse/postcss.config.mjs`
- Create: `apps/lighthouse/app/layout.tsx`
- Create: `apps/lighthouse/app/page.tsx`
- Create: `apps/lighthouse/app/globals.css`

- [ ] **Step 1:** Write `apps/lighthouse/package.json`.

```json
{
  "name": "lighthouse",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "next dev -p 3200",
    "build": "next build",
    "start": "next start -p 3200",
    "lint": "next lint",
    "typecheck": "tsc --noEmit",
    "test": "vitest run",
    "test:watch": "vitest",
    "e2e": "playwright test"
  },
  "dependencies": {
    "@mysten/sui": "^1.15.0",
    "@mysten/dapp-kit": "^0.14.0",
    "@mysten/zklogin": "^0.7.0",
    "@tanstack/react-query": "^5.0.0",
    "lightweight-charts": "^4.2.0",
    "next": "^15.0.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0",
    "swr": "^2.2.5",
    "zod": "^3.23.0",
    "zustand": "^4.5.0"
  },
  "devDependencies": {
    "@playwright/test": "^1.47.0",
    "@types/node": "^22.0.0",
    "@types/react": "^19.0.0",
    "@types/react-dom": "^19.0.0",
    "autoprefixer": "^10.4.20",
    "eslint": "^9.0.0",
    "eslint-config-next": "^15.0.0",
    "postcss": "^8.4.0",
    "tailwindcss": "^3.4.14",
    "typescript": "^5.6.0",
    "vitest": "^2.1.0"
  }
}
```

- [ ] **Step 2:** Write `apps/lighthouse/next.config.ts`.

```ts
import type { NextConfig } from "next";

const config: NextConfig = {
  reactStrictMode: true,
  experimental: {
    // Next 15 App Router defaults
  },
  async redirects() {
    return [{ source: "/", destination: "/trade", permanent: false }];
  },
};

export default config;
```

- [ ] **Step 3:** Write `apps/lighthouse/tsconfig.json`.

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["dom", "dom.iterable", "esnext"],
    "module": "esnext",
    "moduleResolution": "bundler",
    "jsx": "preserve",
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "incremental": true,
    "plugins": [{ "name": "next" }],
    "paths": {
      "@/*": ["./*"]
    }
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
  "exclude": ["node_modules"]
}
```

- [ ] **Step 4:** Write `apps/lighthouse/postcss.config.mjs`.

```js
export default {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
};
```

- [ ] **Step 5:** Write `apps/lighthouse/app/globals.css`.

```css
@tailwind base;
@tailwind components;
@tailwind utilities;

html, body { height: 100%; }
body {
  background: var(--bg-base);
  color: rgba(255, 255, 255, 0.95);
  font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', sans-serif;
  min-height: 100vh;
}
```

- [ ] **Step 6:** Write a placeholder `apps/lighthouse/app/page.tsx` (the redirect to `/trade` is handled by `next.config.ts`, but Next requires `app/page.tsx` to exist).

```tsx
export default function Home() {
  return null;
}
```

- [ ] **Step 7:** Write a minimal `apps/lighthouse/app/layout.tsx`.

```tsx
import type { ReactNode } from "react";
import "./globals.css";

export const metadata = {
  title: "Lighthouse — DeepBook Predict",
  description: "Predict where BTC settles. Vault-backed prediction markets on Sui testnet.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
```

- [ ] **Step 8:** Install dependencies.

```bash
cd apps/lighthouse && pnpm install
```

Expected: pnpm resolves all deps against the root lockfile without errors.

- [ ] **Step 9:** Run typecheck.

```bash
cd apps/lighthouse && pnpm typecheck
```

Expected: PASS with no errors.

- [ ] **Step 10:** Commit.

```bash
git add apps/lighthouse
git commit -m "feat(lighthouse): bootstrap Next.js 15 app skeleton"
```

### Task 0.3: Configure Tailwind with the Lighthouse palette

**Files:**
- Create: `apps/lighthouse/tailwind.config.ts`

- [ ] **Step 1:** Write `apps/lighthouse/tailwind.config.ts`. Colors match the spec §9.1 palette; rgba values preserve the Alpha-on-dark look established in the mockups.

```ts
import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./app/**/*.{ts,tsx}",
    "./components/**/*.{ts,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        // Backgrounds
        "bg-base": "#0a0a14",
        "bg-surface": "#12121e",
        "bg-rail": "#0e0e18",
        "bg-wheel": "#14141f",
        // Borders
        "border-faint": "rgba(255, 255, 255, 0.06)",
        "border-subtle": "rgba(255, 255, 255, 0.08)",
        // Accents
        "gold": "rgba(220, 180, 50, 0.95)",
        "gold-dim": "rgba(220, 180, 50, 0.7)",
        "gold-bg": "rgba(220, 180, 50, 0.12)",
        "gold-border": "rgba(220, 180, 50, 0.35)",
        "green": "rgba(60, 200, 120, 0.95)",
        "green-bg": "rgba(60, 200, 120, 0.15)",
        "red": "rgba(240, 100, 100, 0.9)",
        "red-bg": "rgba(240, 100, 100, 0.1)",
        "amber": "rgba(240, 180, 80, 0.9)",
        "amber-bg": "rgba(240, 180, 80, 0.1)",
        "lavender": "rgba(170, 180, 240, 0.9)",
        "lavender-bg": "rgba(170, 180, 240, 0.1)",
      },
      fontFamily: {
        mono: ["'SF Mono'", "'Fira Code'", "monospace"],
      },
      letterSpacing: {
        track: "0.08em",
      },
    },
  },
  plugins: [],
};

export default config;
```

- [ ] **Step 2:** Update `apps/lighthouse/app/globals.css` to expose CSS variables for the base background (used in the raw CSS selectors of ported components like the wheel canvas wrapper).

```css
@tailwind base;
@tailwind components;
@tailwind utilities;

:root {
  --bg-base: #0a0a14;
  --bg-surface: #12121e;
  --bg-rail: #0e0e18;
}

html, body { height: 100%; }
body {
  background: var(--bg-base);
  color: rgba(255, 255, 255, 0.95);
  font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', sans-serif;
  min-height: 100vh;
}
```

- [ ] **Step 3:** Verify Tailwind picks up the config by building once.

```bash
cd apps/lighthouse && pnpm build
```

Expected: build succeeds; output mentions `app/page` as a route.

- [ ] **Step 4:** Commit.

```bash
git add apps/lighthouse/tailwind.config.ts apps/lighthouse/app/globals.css
git commit -m "feat(lighthouse): configure Tailwind with Lighthouse palette"
```

### Task 0.4: Env config + typed `lib/config.ts`

**Files:**
- Create: `apps/lighthouse/.env.example`
- Create: `apps/lighthouse/lib/config.ts`
- Modify: `.gitignore` (ensure `apps/lighthouse/.env.local` is ignored)

- [ ] **Step 1:** Write `.env.example`.

```bash
# Sui network
NEXT_PUBLIC_SUI_NETWORK=testnet
NEXT_PUBLIC_SUI_RPC_URL=https://fullnode.testnet.sui.io
NEXT_PUBLIC_SUI_WS_URL=wss://fullnode.testnet.sui.io

# Predict package deploy (from scripts/config/constants.ts after redeploy)
NEXT_PUBLIC_PREDICT_PACKAGE_ID=0x01db8fc74ead463c7167f9c609af72e64ac4eeb0f6b9c05da17c16ad0fd348d0
NEXT_PUBLIC_PREDICT_REGISTRY_ID=0xc30b84b73d64472c19f12bc5357273ddce6d76ef04116306808b022078080d0a
NEXT_PUBLIC_PREDICT_ID=
NEXT_PUBLIC_USDSUI_TYPE=

# Indexer / API server
NEXT_PUBLIC_PREDICT_SERVER_URL=https://predict-server.testnet.mystenlabs.com

# zkLogin
NEXT_PUBLIC_GOOGLE_CLIENT_ID=
NEXT_PUBLIC_APPLE_CLIENT_ID=
NEXT_PUBLIC_ZKLOGIN_PROVER_URL=https://prover-dev.mystenlabs.com/v1

# Server-only (never NEXT_PUBLIC_)
SPONSOR_WALLET_PRIVATE_KEY=
UPSTASH_REDIS_URL=
UPSTASH_REDIS_TOKEN=
FAUCET_ADMIN_KEY=
```

- [ ] **Step 2:** Write `lib/config.ts`.

```ts
import { z } from "zod";

const PublicEnvSchema = z.object({
  suiNetwork: z.enum(["testnet", "mainnet"]),
  suiRpcUrl: z.string().url(),
  suiWsUrl: z.string().url(),
  predictPackageId: z.string().regex(/^0x[0-9a-fA-F]{64}$/),
  predictRegistryId: z.string().regex(/^0x[0-9a-fA-F]{64}$/),
  predictId: z.string().regex(/^0x[0-9a-fA-F]{64}$/),
  usdsuiType: z.string().min(1),
  predictServerUrl: z.string().url(),
  googleClientId: z.string().min(1),
  appleClientId: z.string().optional(),
  zkLoginProverUrl: z.string().url(),
});

export type PublicConfig = z.infer<typeof PublicEnvSchema>;

export function publicConfig(): PublicConfig {
  return PublicEnvSchema.parse({
    suiNetwork: process.env.NEXT_PUBLIC_SUI_NETWORK,
    suiRpcUrl: process.env.NEXT_PUBLIC_SUI_RPC_URL,
    suiWsUrl: process.env.NEXT_PUBLIC_SUI_WS_URL,
    predictPackageId: process.env.NEXT_PUBLIC_PREDICT_PACKAGE_ID,
    predictRegistryId: process.env.NEXT_PUBLIC_PREDICT_REGISTRY_ID,
    predictId: process.env.NEXT_PUBLIC_PREDICT_ID,
    usdsuiType: process.env.NEXT_PUBLIC_USDSUI_TYPE,
    predictServerUrl: process.env.NEXT_PUBLIC_PREDICT_SERVER_URL,
    googleClientId: process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID,
    appleClientId: process.env.NEXT_PUBLIC_APPLE_CLIENT_ID,
    zkLoginProverUrl: process.env.NEXT_PUBLIC_ZKLOGIN_PROVER_URL,
  });
}

// Server-only — do NOT import from client components
export function serverConfig() {
  return {
    sponsorKey: process.env.SPONSOR_WALLET_PRIVATE_KEY!,
    redisUrl: process.env.UPSTASH_REDIS_URL!,
    redisToken: process.env.UPSTASH_REDIS_TOKEN!,
    faucetKey: process.env.FAUCET_ADMIN_KEY!,
  };
}
```

- [ ] **Step 3:** Verify `.gitignore` already ignores `**/.env.local`. If not, append `apps/lighthouse/.env.local` to it.

```bash
grep -q "\.env\.local" .gitignore || echo "apps/lighthouse/.env.local" >> .gitignore
```

- [ ] **Step 4:** Create a dev `.env.local` by copying `.env.example`. Leave sensitive server-only values blank for now (Checkpoint 2/3 fill them in).

```bash
cp apps/lighthouse/.env.example apps/lighthouse/.env.local
```

- [ ] **Step 5:** Commit.

```bash
git add apps/lighthouse/.env.example apps/lighthouse/lib/config.ts .gitignore
git commit -m "feat(lighthouse): add env schema + typed config"
```

### Task 0.5: Gate — build + dev boot

- [ ] **Step 1:** Build.

```bash
cd apps/lighthouse && pnpm build
```

Expected: succeeds with one route (`/` → redirect to `/trade`, which 404s since the route doesn't exist yet — that's acceptable for this gate).

- [ ] **Step 2:** Typecheck.

```bash
cd apps/lighthouse && pnpm typecheck
```

Expected: PASS.

- [ ] **Step 3:** Start the dev server briefly to confirm it boots.

```bash
cd apps/lighthouse && timeout 5 pnpm dev || true
```

Expected: logs show `Ready in <ms>` before timeout kills it.

- [ ] **Step 4:** Commit any lockfile updates.

```bash
git add pnpm-lock.yaml 2>/dev/null; git commit -m "chore(lighthouse): lockfile" --allow-empty-message --allow-empty 2>/dev/null || true
```

Checkpoint 0 done. Proceed to Checkpoint 1.

---

## Checkpoint 1 — Core Libs (pure logic, TDD)

**Gate at end:** `pnpm --filter lighthouse test` green. All exports consumed by later checkpoints exist and are typed.

### Task 1.1: Vitest setup

**Files:**
- Create: `apps/lighthouse/vitest.config.ts`

- [ ] **Step 1:** Write `vitest.config.ts`.

```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["tests/unit/**/*.test.ts"],
    globals: false,
  },
  resolve: {
    alias: {
      "@": new URL(".", import.meta.url).pathname,
    },
  },
});
```

- [ ] **Step 2:** Run vitest once to confirm it resolves (no tests yet → "No test files found" is acceptable).

```bash
cd apps/lighthouse && pnpm test
```

Expected: exits 0 or 1 with "No test files found". Either is fine — we haven't written tests yet.

- [ ] **Step 3:** Commit.

```bash
git add apps/lighthouse/vitest.config.ts
git commit -m "feat(lighthouse): configure vitest"
```

### Task 1.2: `lib/pricing/svi.ts` — write failing tests

**Files:**
- Create: `apps/lighthouse/tests/unit/pricing.test.ts`

- [ ] **Step 1:** Write tests. The reference implementation is in `/Users/aslantashtanov/Desktop/Projects/second-brain-workspace/data/docs/visuals/charts_btc.html` (lines 195–225 in that file). We're re-implementing it in TypeScript with BPS-scaled inputs.

```ts
import { describe, it, expect } from "vitest";
import { normalCDF, computeUpPrice, computeDownPrice } from "@/lib/pricing/svi";

describe("normalCDF", () => {
  it("returns 0.5 at x=0", () => {
    expect(normalCDF(0)).toBeCloseTo(0.5, 4);
  });
  it("approaches 1 at large positive x", () => {
    expect(normalCDF(6)).toBe(1);
  });
  it("approaches 0 at large negative x", () => {
    expect(normalCDF(-6)).toBe(0);
  });
  it("is symmetric around 0 (N(-x) = 1 - N(x))", () => {
    for (const x of [0.3, 0.7, 1.2, 2.1]) {
      expect(normalCDF(-x) + normalCDF(x)).toBeCloseTo(1.0, 4);
    }
  });
});

describe("computeUpPrice (ATM, low vol, short TTE)", () => {
  const SVI_FLAT = { a: 0.04, b: 0.0, rho: 0.0, m: 0.0, sigma: 0.01 };
  const ONE_DAY_MS = 86_400_000;
  const now = 1_700_000_000_000;
  const expiry = now + 7 * ONE_DAY_MS;

  it("ATM UP price sits near 0.5", () => {
    const price = computeUpPrice({
      spot: 64_000,
      forward: 64_000,
      strike: 64_000,
      svi: SVI_FLAT,
      nowMs: now,
      expiryMs: expiry,
      riskFreeRateBps: 0,
    });
    expect(price).toBeGreaterThan(0.45);
    expect(price).toBeLessThan(0.55);
  });

  it("far-OTM UP price approaches 0", () => {
    const price = computeUpPrice({
      spot: 64_000,
      forward: 64_000,
      strike: 200_000,
      svi: SVI_FLAT,
      nowMs: now,
      expiryMs: expiry,
      riskFreeRateBps: 0,
    });
    expect(price).toBeLessThan(0.05);
  });

  it("deep-ITM UP price approaches 1", () => {
    const price = computeUpPrice({
      spot: 64_000,
      forward: 64_000,
      strike: 10_000,
      svi: SVI_FLAT,
      nowMs: now,
      expiryMs: expiry,
      riskFreeRateBps: 0,
    });
    expect(price).toBeGreaterThan(0.95);
  });

  it("UP + DOWN = 1 (ignoring discount)", () => {
    const up = computeUpPrice({
      spot: 64_000, forward: 64_000, strike: 65_000,
      svi: SVI_FLAT, nowMs: now, expiryMs: expiry, riskFreeRateBps: 0,
    });
    const down = computeDownPrice({
      spot: 64_000, forward: 64_000, strike: 65_000,
      svi: SVI_FLAT, nowMs: now, expiryMs: expiry, riskFreeRateBps: 0,
    });
    expect(up + down).toBeCloseTo(1.0, 4);
  });
});
```

- [ ] **Step 2:** Run tests — confirm they fail.

```bash
cd apps/lighthouse && pnpm test
```

Expected: FAIL with "Cannot find module '@/lib/pricing/svi'".

### Task 1.3: `lib/pricing/svi.ts` — minimal implementation

**Files:**
- Create: `apps/lighthouse/lib/pricing/svi.ts`

- [ ] **Step 1:** Write the implementation. Ported from the Abramowitz & Stegun approximation in `charts_btc.html`.

```ts
export interface SviParams {
  a: number;       // base level (annualized total variance at ATM)
  b: number;       // wing slope
  rho: number;     // correlation, in [-1, 1]
  m: number;       // horizontal shift (ATM log-moneyness)
  sigma: number;   // smile curvature
}

export interface PriceInput {
  spot: number;
  forward: number;
  strike: number;
  svi: SviParams;
  nowMs: number;
  expiryMs: number;
  riskFreeRateBps: number;  // 0–10000
}

const MS_PER_YEAR = 365.25 * 24 * 3600 * 1000;

/**
 * Abramowitz & Stegun approximation to the standard normal CDF.
 * Matches the reference implementation in charts_btc.html.
 */
export function normalCDF(x: number): number {
  if (x > 6) return 1;
  if (x < -6) return 0;
  const a1 = 0.254829592;
  const a2 = -0.284496736;
  const a3 = 1.421413741;
  const a4 = -1.453152027;
  const a5 = 1.061405429;
  const p = 0.3275911;
  const sign = x < 0 ? -1 : 1;
  const ax = Math.abs(x);
  const t = 1.0 / (1.0 + p * ax);
  const y = 1.0 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * Math.exp(-ax * ax / 2);
  return 0.5 * (1.0 + sign * y);
}

/**
 * Digital UP option price (P(BTC > strike at expiry)).
 * Uses Black-Scholes with SVI-parameterized total variance.
 */
export function computeUpPrice(input: PriceInput): number {
  const { spot, forward, strike, svi, nowMs, expiryMs, riskFreeRateBps } = input;
  const tte = Math.max((expiryMs - nowMs) / MS_PER_YEAR, 1e-10);
  const rfr = riskFreeRateBps / 10_000;
  const discount = Math.exp(-rfr * tte);

  if (forward <= 0 || strike <= 0) return 0.5;

  const k = Math.log(strike / forward);
  const km = k - svi.m;
  const totalVar = svi.a + svi.b * (svi.rho * km + Math.sqrt(km * km + svi.sigma * svi.sigma));
  if (totalVar <= 0) return 0.5;

  const sqrtVar = Math.sqrt(totalVar);
  const d2 = (-k - totalVar / 2) / sqrtVar;
  return discount * normalCDF(d2);
}

/**
 * Digital DOWN option price (P(BTC <= strike at expiry)).
 * By put-call parity for digitals: DOWN = discount - UP.
 */
export function computeDownPrice(input: PriceInput): number {
  const tte = Math.max((input.expiryMs - input.nowMs) / MS_PER_YEAR, 1e-10);
  const rfr = input.riskFreeRateBps / 10_000;
  const discount = Math.exp(-rfr * tte);
  return discount - computeUpPrice(input);
}
```

- [ ] **Step 2:** Run tests.

```bash
cd apps/lighthouse && pnpm test
```

Expected: all pricing tests PASS.

- [ ] **Step 3:** Commit.

```bash
git add apps/lighthouse/lib/pricing/svi.ts apps/lighthouse/tests/unit/pricing.test.ts
git commit -m "feat(lighthouse): add SVI pricing primitives with tests"
```

### Task 1.4: `lib/pricing/spread.ts` — utilization-aware spread

**Files:**
- Create: `apps/lighthouse/lib/pricing/spread.ts`
- Modify: `apps/lighthouse/tests/unit/pricing.test.ts`

- [ ] **Step 1:** Add tests to the existing pricing test file.

```ts
// ...append to tests/unit/pricing.test.ts:
import { applySpread } from "@/lib/pricing/spread";

describe("applySpread", () => {
  it("base spread only at zero utilization", () => {
    const { ask, bid } = applySpread({
      midPrice: 0.5,
      baseSpreadBps: 40,
      utilizationPct: 0,
      utilizationMultiplier: 2.0,
      minSpreadBps: 5,
    });
    expect(ask).toBeGreaterThan(0.5);
    expect(bid).toBeLessThan(0.5);
    expect(ask - bid).toBeCloseTo(0.5 * (40 / 10_000), 4);
  });

  it("widens with utilization", () => {
    const low = applySpread({
      midPrice: 0.5, baseSpreadBps: 40, utilizationPct: 10,
      utilizationMultiplier: 2.0, minSpreadBps: 5,
    });
    const high = applySpread({
      midPrice: 0.5, baseSpreadBps: 40, utilizationPct: 80,
      utilizationMultiplier: 2.0, minSpreadBps: 5,
    });
    expect(high.ask - high.bid).toBeGreaterThan(low.ask - low.bid);
  });

  it("never goes below minSpread", () => {
    const { ask, bid } = applySpread({
      midPrice: 0.5, baseSpreadBps: 0, utilizationPct: 0,
      utilizationMultiplier: 0, minSpreadBps: 10,
    });
    expect(ask - bid).toBeGreaterThanOrEqual(0.5 * (10 / 10_000) - 1e-9);
  });
});
```

- [ ] **Step 2:** Run — confirm they fail with a "module not found" error.

```bash
cd apps/lighthouse && pnpm test
```

Expected: FAIL on spread imports.

- [ ] **Step 3:** Implement `lib/pricing/spread.ts`.

```ts
export interface SpreadInput {
  midPrice: number;           // 0..1
  baseSpreadBps: number;      // from predict.pricing_config.base_spread
  utilizationPct: number;     // 0..100
  utilizationMultiplier: number;  // from predict.pricing_config.utilization_multiplier, scaled 1.0 = identity
  minSpreadBps: number;       // from predict.pricing_config.min_spread
}

export interface SpreadOutput {
  ask: number;  // ask = mid + half-spread
  bid: number;  // bid = mid - half-spread
  spreadBps: number;  // effective spread in bps
}

/**
 * Utilization-aware spread calculator. Mirrors the on-chain logic in
 * packages/predict/sources/predict.move::trade_prices.
 *
 * spread = max(minSpread, baseSpread + baseSpread * (utilization * multiplier))
 */
export function applySpread(input: SpreadInput): SpreadOutput {
  const { midPrice, baseSpreadBps, utilizationPct, utilizationMultiplier, minSpreadBps } = input;
  const utilization = utilizationPct / 100;
  const bumped = baseSpreadBps + baseSpreadBps * utilization * utilizationMultiplier;
  const spreadBps = Math.max(minSpreadBps, bumped);
  const halfSpread = (midPrice * spreadBps) / 2 / 10_000;
  return {
    ask: midPrice + halfSpread,
    bid: Math.max(0, midPrice - halfSpread),
    spreadBps,
  };
}
```

- [ ] **Step 4:** Run tests; all pricing tests pass.

```bash
cd apps/lighthouse && pnpm test
```

Expected: PASS.

- [ ] **Step 5:** Export a public `lib/pricing/index.ts` barrel.

```ts
export * from "./svi";
export * from "./spread";
```

- [ ] **Step 6:** Commit.

```bash
git add apps/lighthouse/lib/pricing apps/lighthouse/tests/unit/pricing.test.ts
git commit -m "feat(lighthouse): add utilization-aware spread with tests"
```

### Task 1.5: `lib/formatters.ts` — USD, countdown, address

**Files:**
- Create: `apps/lighthouse/tests/unit/formatters.test.ts`
- Create: `apps/lighthouse/lib/formatters.ts`

- [ ] **Step 1:** Write the test file first.

```ts
import { describe, it, expect } from "vitest";
import {
  formatUsd,
  formatUsdCompact,
  formatCountdown,
  formatCountdownCoarse,
  shortenAddress,
  formatPct,
} from "@/lib/formatters";

describe("formatUsd", () => {
  it("prefixes $ and uses 2 decimals by default", () => {
    expect(formatUsd(1234.5)).toBe("$1,234.50");
    expect(formatUsd(0)).toBe("$0.00");
  });
  it("negative becomes -$X.XX", () => {
    expect(formatUsd(-12.3)).toBe("-$12.30");
  });
  it("custom decimals", () => {
    expect(formatUsd(0.5124, 4)).toBe("$0.5124");
  });
});

describe("formatUsdCompact", () => {
  it("M/K abbreviations", () => {
    expect(formatUsdCompact(2_847_216)).toBe("$2,847,216");
    expect(formatUsdCompact(1_794_000)).toBe("$1,794k");
    expect(formatUsdCompact(18_420)).toBe("$18,420");
    expect(formatUsdCompact(500)).toBe("$500.00");
  });
});

describe("formatCountdown (live / second-resolution)", () => {
  it("days+hours+minutes+seconds", () => {
    const ms = (((7 * 24 + 16) * 60 + 32) * 60 + 14) * 1000;
    expect(formatCountdown(ms)).toBe("7d 16h 32m 14s");
  });
  it("hours+minutes+seconds when <1 day", () => {
    const ms = ((16 * 60 + 32) * 60 + 14) * 1000;
    expect(formatCountdown(ms)).toBe("16h 32m 14s");
  });
  it("minutes+seconds when <1 hour", () => {
    const ms = (32 * 60 + 14) * 1000;
    expect(formatCountdown(ms)).toBe("32m 14s");
  });
  it("seconds only when <1 minute", () => {
    expect(formatCountdown(14_000)).toBe("14s");
  });
  it("returns 'settled' when <=0", () => {
    expect(formatCountdown(0)).toBe("settled");
    expect(formatCountdown(-5)).toBe("settled");
  });
});

describe("formatCountdownCoarse (chip / minute-resolution)", () => {
  it("days+hours only", () => {
    const ms = (((7 * 24 + 16) * 60 + 32) * 60 + 14) * 1000;
    expect(formatCountdownCoarse(ms)).toBe("in 7d 16h");
  });
  it("hours+minutes when <1 day", () => {
    const ms = ((23 * 60 + 12) * 60) * 1000;
    expect(formatCountdownCoarse(ms)).toBe("in 23h 12m");
  });
  it("'pending' when <=0", () => {
    expect(formatCountdownCoarse(0)).toBe("pending");
  });
});

describe("shortenAddress", () => {
  it("truncates middle", () => {
    expect(shortenAddress("0x7f3abc1234567890abcdef1234567890abcdef1234567890abcdef1234c4d2"))
      .toBe("0x7f3a…c4d2");
  });
  it("returns input if too short", () => {
    expect(shortenAddress("0x1234")).toBe("0x1234");
  });
});

describe("formatPct", () => {
  it("2 decimals by default", () => {
    expect(formatPct(0.0696)).toBe("+6.96%");
    expect(formatPct(-0.1234)).toBe("-12.34%");
    expect(formatPct(0)).toBe("0.00%");
  });
});
```

- [ ] **Step 2:** Run — fail.

```bash
cd apps/lighthouse && pnpm test
```

Expected: FAIL with module not found.

- [ ] **Step 3:** Implement `lib/formatters.ts`.

```ts
export function formatUsd(value: number, decimals = 2): string {
  const sign = value < 0 ? "-" : "";
  const abs = Math.abs(value);
  return `${sign}$${abs.toLocaleString(undefined, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })}`;
}

export function formatUsdCompact(value: number): string {
  const abs = Math.abs(value);
  const sign = value < 0 ? "-" : "";
  if (abs >= 1_000_000) {
    return `${sign}$${value.toLocaleString(undefined, { maximumFractionDigits: 0 })}`;
  }
  if (abs >= 10_000) {
    return `${sign}$${Math.round(value / 1_000).toLocaleString()}k`;
  }
  return formatUsd(value);
}

export function formatCountdown(ms: number): string {
  if (ms <= 0) return "settled";
  const s = Math.floor(ms / 1000);
  const days = Math.floor(s / 86_400);
  const hours = Math.floor((s % 86_400) / 3600);
  const minutes = Math.floor((s % 3600) / 60);
  const seconds = s % 60;
  if (days > 0) return `${days}d ${hours}h ${minutes}m ${seconds}s`;
  if (hours > 0) return `${hours}h ${minutes}m ${seconds}s`;
  if (minutes > 0) return `${minutes}m ${seconds}s`;
  return `${seconds}s`;
}

export function formatCountdownCoarse(ms: number): string {
  if (ms <= 0) return "pending";
  const s = Math.floor(ms / 1000);
  const days = Math.floor(s / 86_400);
  const hours = Math.floor((s % 86_400) / 3600);
  const minutes = Math.floor((s % 3600) / 60);
  if (days > 0) return `in ${days}d ${hours}h`;
  return `in ${hours}h ${minutes}m`;
}

export function shortenAddress(addr: string): string {
  if (addr.length <= 10) return addr;
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export function formatPct(frac: number, decimals = 2): string {
  const sign = frac > 0 ? "+" : frac < 0 ? "-" : "";
  return `${sign}${Math.abs(frac * 100).toFixed(decimals)}%`;
}
```

- [ ] **Step 4:** Run tests; green.

```bash
cd apps/lighthouse && pnpm test
```

Expected: PASS (all pricing + formatter tests).

- [ ] **Step 5:** Commit.

```bash
git add apps/lighthouse/lib/formatters.ts apps/lighthouse/tests/unit/formatters.test.ts
git commit -m "feat(lighthouse): add USD/countdown/address formatters with tests"
```

### Task 1.6: `lib/sui/client.ts` — SuiClient singleton

**Files:**
- Create: `apps/lighthouse/lib/sui/client.ts`

No tests — this is a thin singleton over `@mysten/sui`.

- [ ] **Step 1:** Write `lib/sui/client.ts`.

```ts
import { SuiClient } from "@mysten/sui/client";
import { publicConfig } from "@/lib/config";

let _client: SuiClient | null = null;

export function getSuiClient(): SuiClient {
  if (_client) return _client;
  _client = new SuiClient({ url: publicConfig().suiRpcUrl });
  return _client;
}

export function resetSuiClient(): void {
  _client = null;
}
```

- [ ] **Step 2:** Typecheck.

```bash
cd apps/lighthouse && pnpm typecheck
```

Expected: PASS.

- [ ] **Step 3:** Commit.

```bash
git add apps/lighthouse/lib/sui/client.ts
git commit -m "feat(lighthouse): add SuiClient singleton"
```

### Task 1.7: `lib/api/predict-server.ts` — typed REST client

**Files:**
- Create: `apps/lighthouse/lib/api/predict-server.ts`

Endpoint map from `crates/predict-server/src/server.rs`:
| Route | Purpose |
|---|---|
| `/oracles` | list oracles |
| `/oracles/:id/svi/latest` | latest SVI params |
| `/oracles/:id/prices/latest` | latest spot + forward |
| `/oracles/:id/ask-bounds` | per-oracle ask bounds |
| `/managers` | list managers (filter by owner) |
| `/managers/:id/positions` | per-manager positions |
| `/positions/minted?manager_id=` | mint history |
| `/positions/redeemed?manager_id=` | redeem history |
| `/lp/supplies?supplier=` | user's supply events |
| `/lp/withdrawals?withdrawer=` | user's withdrawal events |
| `/status` | system health |
| `/config` | Predict config |

- [ ] **Step 1:** Write the fetcher.

```ts
import { publicConfig } from "@/lib/config";

export type Oracle = {
  oracle_id: string;
  underlying_asset: string;
  expiry: number;         // ms
  activated_at: number | null;
  settled_at: number | null;
  settlement_price: number | null;
  min_strike: number;
  tick_size: number;
};

export type OracleLatestSvi = {
  oracle_id: string;
  a: number;
  b: number;
  rho: number;    // I64 deserialized as signed
  m: number;      // I64 deserialized as signed
  sigma: number;
  timestamp: number;
};

export type OracleLatestPrice = {
  oracle_id: string;
  spot: number;
  forward: number;
  timestamp: number;
};

export type PositionRow = {
  manager_id: string;
  oracle_id: string;
  expiry: number;
  strike: number;
  is_up: boolean;
  quantity: number;         // aggregated current qty (net of redemptions)
  cost_basis: number;       // aggregated cost USD
};

export type Manager = {
  manager_id: string;
  owner: string;
  balance: number;          // in quote, smallest unit
};

async function get<T>(path: string): Promise<T> {
  const base = publicConfig().predictServerUrl;
  const res = await fetch(`${base}${path}`, {
    headers: { accept: "application/json" },
    cache: "no-store",
  });
  if (!res.ok) throw new Error(`predict-server ${path}: ${res.status}`);
  return res.json() as Promise<T>;
}

export const predictServer = {
  oracles: () => get<Oracle[]>("/oracles"),
  oracleLatestSvi: (id: string) => get<OracleLatestSvi>(`/oracles/${id}/svi/latest`),
  oracleLatestPrice: (id: string) => get<OracleLatestPrice>(`/oracles/${id}/prices/latest`),
  managersByOwner: (owner: string) => get<Manager[]>(`/managers?owner=${owner}`),
  managerPositions: (managerId: string) => get<PositionRow[]>(`/managers/${managerId}/positions`),
  status: () => get<{ ok: boolean }>("/status"),
  config: () => get<Record<string, unknown>>("/config"),
};
```

- [ ] **Step 2:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/lib/api/predict-server.ts
git commit -m "feat(lighthouse): add typed predict-server REST client"
```

### Task 1.8: `store/trade.ts` — Zustand store

**Files:**
- Create: `apps/lighthouse/store/trade.ts`

- [ ] **Step 1:** Write the store.

```ts
import { create } from "zustand";

export type Side = "UP" | "DOWN";

interface TradeState {
  selectedOracleId: string | null;
  selectedStrike: number | null;
  selectedSide: Side;
  sizeUsd: number;
  setOracleId: (id: string | null) => void;
  setStrike: (s: number) => void;
  setSide: (s: Side) => void;
  setSize: (v: number) => void;
  reset: () => void;
}

export const useTradeStore = create<TradeState>((set) => ({
  selectedOracleId: null,
  selectedStrike: null,
  selectedSide: "UP",
  sizeUsd: 50,
  setOracleId: (id) => set({ selectedOracleId: id }),
  setStrike: (s) => set({ selectedStrike: s }),
  setSide: (s) => set({ selectedSide: s }),
  setSize: (v) => set({ sizeUsd: Math.max(0, v) }),
  reset: () => set({ selectedOracleId: null, selectedStrike: null, selectedSide: "UP", sizeUsd: 50 }),
}));
```

- [ ] **Step 2:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/store/trade.ts
git commit -m "feat(lighthouse): add trade zustand store"
```

### Task 1.9: Gate — full unit test run

- [ ] **Step 1:** Run full vitest suite.

```bash
cd apps/lighthouse && pnpm test
```

Expected: All pricing + formatter tests PASS, no type errors.

- [ ] **Step 2:** Run typecheck.

```bash
cd apps/lighthouse && pnpm typecheck
```

Expected: PASS.

Checkpoint 1 done. Proceed to Checkpoint 2.

---

## Checkpoint 2 — zkLogin authentication

**Gate at end:** A user can click "Sign in with Google" on `/signin`, complete OAuth, land on `/trade` with a valid session keypair stored, and see their derived Sui address in the top-nav address pill. Session survives page reload within `maxEpoch`.

**Dependencies before starting:**
- Register an OAuth client at https://console.cloud.google.com (Application type = Web; authorized redirect URI = `http://localhost:3200/signin` for dev + your Vercel URL for prod). Paste the client ID into `NEXT_PUBLIC_GOOGLE_CLIENT_ID`.
- Provision an Upstash Redis database (free tier). Paste URL+token into `UPSTASH_REDIS_URL` / `UPSTASH_REDIS_TOKEN`.

### Task 2.1: Session utilities + tests

**Files:**
- Create: `apps/lighthouse/tests/unit/session.test.ts`
- Create: `apps/lighthouse/lib/zklogin/session.ts`

- [ ] **Step 1:** Write tests.

```ts
import { describe, it, expect } from "vitest";
import {
  computeMaxEpoch,
  isSessionValid,
  secondsUntilExpiry,
} from "@/lib/zklogin/session";

describe("computeMaxEpoch", () => {
  it("currentEpoch + 10 by default", () => {
    expect(computeMaxEpoch(1000)).toBe(1010);
  });
  it("custom horizon", () => {
    expect(computeMaxEpoch(1000, 5)).toBe(1005);
  });
});

describe("isSessionValid", () => {
  it("valid when currentEpoch < maxEpoch", () => {
    expect(isSessionValid({ maxEpoch: 1010, currentEpoch: 1005 })).toBe(true);
  });
  it("invalid when currentEpoch >= maxEpoch", () => {
    expect(isSessionValid({ maxEpoch: 1010, currentEpoch: 1010 })).toBe(false);
    expect(isSessionValid({ maxEpoch: 1010, currentEpoch: 1011 })).toBe(false);
  });
});

describe("secondsUntilExpiry", () => {
  it("computes wall-clock seconds from epoch delta + avg epoch duration", () => {
    // Sui testnet: ~300s per epoch
    const s = secondsUntilExpiry({
      maxEpoch: 1010,
      currentEpoch: 1005,
      avgEpochMs: 300_000,
    });
    expect(s).toBe(5 * 300);  // 5 epochs × 300s
  });
  it("returns 0 when already expired", () => {
    const s = secondsUntilExpiry({
      maxEpoch: 1000, currentEpoch: 1005, avgEpochMs: 300_000,
    });
    expect(s).toBe(0);
  });
});
```

- [ ] **Step 2:** Run — fail with module not found.

```bash
cd apps/lighthouse && pnpm test
```

- [ ] **Step 3:** Implement `lib/zklogin/session.ts`.

```ts
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { generateNonce, generateRandomness, jwtToAddress } from "@mysten/zklogin";

export interface SessionStateV1 {
  version: 1;
  ephemeralSecretKey: string;      // base64 of 32-byte secret
  jwt: string;
  salt: string;
  userAddress: string;
  maxEpoch: number;
  randomness: string;
  zkProof: unknown | null;          // filled after /api/zklogin/prove
}

const STORAGE_KEY = "lighthouse.session.v1";

export function computeMaxEpoch(currentEpoch: number, horizon = 10): number {
  return currentEpoch + horizon;
}

export function isSessionValid(input: { maxEpoch: number; currentEpoch: number }): boolean {
  return input.currentEpoch < input.maxEpoch;
}

export function secondsUntilExpiry(input: {
  maxEpoch: number;
  currentEpoch: number;
  avgEpochMs: number;
}): number {
  const delta = Math.max(0, input.maxEpoch - input.currentEpoch);
  return Math.floor((delta * input.avgEpochMs) / 1000);
}

export function newEphemeralKeypair(): { kp: Ed25519Keypair; secretKeyB64: string } {
  const kp = new Ed25519Keypair();
  const secret = kp.getSecretKey();  // returns bech32; we store as-is
  return { kp, secretKeyB64: secret };
}

export function restoreEphemeralKeypair(secretKeyB64: string): Ed25519Keypair {
  return Ed25519Keypair.fromSecretKey(secretKeyB64);
}

export function buildOauthNonce(maxEpoch: number, kp: Ed25519Keypair, randomness: string): string {
  return generateNonce(kp.getPublicKey(), maxEpoch, randomness);
}

export function deriveAddressFromJwt(jwt: string, salt: string): string {
  return jwtToAddress(jwt, salt);
}

export function saveSession(state: SessionStateV1): void {
  if (typeof window === "undefined") return;
  window.sessionStorage.setItem(STORAGE_KEY, JSON.stringify(state));
}

export function loadSession(): SessionStateV1 | null {
  if (typeof window === "undefined") return null;
  const raw = window.sessionStorage.getItem(STORAGE_KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as SessionStateV1;
    return parsed.version === 1 ? parsed : null;
  } catch {
    return null;
  }
}

export function clearSession(): void {
  if (typeof window === "undefined") return;
  window.sessionStorage.removeItem(STORAGE_KEY);
}

export { generateRandomness };
```

- [ ] **Step 4:** Run tests.

```bash
cd apps/lighthouse && pnpm test
```

Expected: PASS.

- [ ] **Step 5:** Commit.

```bash
git add apps/lighthouse/lib/zklogin/session.ts apps/lighthouse/tests/unit/session.test.ts
git commit -m "feat(lighthouse): add zkLogin session utilities with tests"
```

### Task 2.2: Server route — `/api/zklogin/salt`

**Files:**
- Create: `apps/lighthouse/lib/zklogin/salt.ts`
- Create: `apps/lighthouse/app/api/zklogin/salt/route.ts`

- [ ] **Step 1:** Write `lib/zklogin/salt.ts` — salt derivation + Redis persistence.

```ts
import { createHash, randomBytes } from "node:crypto";

/**
 * Resolve a per-user salt. If Redis has one, return it; else generate
 * a deterministic salt from a server-side secret + user sub, and persist.
 *
 * NOTE: In production you'd use a dedicated salt service. For testnet we
 * generate + cache. The salt MUST NOT leak to other users.
 */
export async function resolveSalt(args: {
  jwtSub: string;
  redisUrl: string;
  redisToken: string;
}): Promise<string> {
  const cacheKey = `zklogin:salt:${args.jwtSub}`;
  const existing = await redisGet(args.redisUrl, args.redisToken, cacheKey);
  if (existing) return existing;

  const bytes = randomBytes(16);
  const salt = BigInt("0x" + bytes.toString("hex")).toString();
  await redisSet(args.redisUrl, args.redisToken, cacheKey, salt);
  return salt;
}

async function redisGet(url: string, token: string, key: string): Promise<string | null> {
  const res = await fetch(`${url}/get/${encodeURIComponent(key)}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!res.ok) return null;
  const body = (await res.json()) as { result: string | null };
  return body.result;
}

async function redisSet(url: string, token: string, key: string, value: string): Promise<void> {
  await fetch(`${url}/set/${encodeURIComponent(key)}/${encodeURIComponent(value)}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
  });
}
```

- [ ] **Step 2:** Write the route.

```ts
// app/api/zklogin/salt/route.ts
import { NextResponse } from "next/server";
import { jwtDecode } from "jwt-decode";
import { resolveSalt } from "@/lib/zklogin/salt";
import { serverConfig } from "@/lib/config";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const { jwt } = (await req.json()) as { jwt: string };
  if (!jwt) return NextResponse.json({ error: "missing jwt" }, { status: 400 });

  const claims = jwtDecode<{ sub: string; aud: string | string[]; iss: string }>(jwt);
  if (!claims.sub) return NextResponse.json({ error: "bad jwt" }, { status: 400 });

  const { redisUrl, redisToken } = serverConfig();
  const salt = await resolveSalt({ jwtSub: claims.sub, redisUrl, redisToken });
  return NextResponse.json({ salt });
}
```

- [ ] **Step 3:** Add `jwt-decode` to deps.

```bash
cd apps/lighthouse && pnpm add jwt-decode
```

- [ ] **Step 4:** Typecheck.

```bash
cd apps/lighthouse && pnpm typecheck
```

Expected: PASS.

- [ ] **Step 5:** Commit.

```bash
git add apps/lighthouse/lib/zklogin/salt.ts apps/lighthouse/app/api/zklogin/salt apps/lighthouse/package.json pnpm-lock.yaml
git commit -m "feat(lighthouse): add /api/zklogin/salt server route"
```

### Task 2.3: Server route — `/api/zklogin/prove`

**Files:**
- Create: `apps/lighthouse/app/api/zklogin/prove/route.ts`

- [ ] **Step 1:** Write the prover proxy.

```ts
// app/api/zklogin/prove/route.ts
import { NextResponse } from "next/server";
import { publicConfig } from "@/lib/config";

export const runtime = "nodejs";

interface ProveRequest {
  jwt: string;
  extendedEphemeralPublicKey: string;
  maxEpoch: number;
  jwtRandomness: string;
  salt: string;
  keyClaimName: "sub";
}

export async function POST(req: Request) {
  const body = (await req.json()) as ProveRequest;
  const url = `${publicConfig().zkLoginProverUrl}/prove`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const proof = await res.json();
  if (!res.ok) return NextResponse.json({ error: "prover failed", detail: proof }, { status: 502 });
  return NextResponse.json(proof);
}
```

- [ ] **Step 2:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/app/api/zklogin/prove
git commit -m "feat(lighthouse): add /api/zklogin/prove proxy to Mysten prover"
```

### Task 2.4: Sign-in page

**Files:**
- Create: `apps/lighthouse/app/signin/page.tsx`
- Create: `apps/lighthouse/lib/zklogin/oauth.ts`

- [ ] **Step 1:** Write `lib/zklogin/oauth.ts`.

```ts
import { publicConfig } from "@/lib/config";

export function buildGoogleOauthUrl(nonce: string, redirectUri: string): string {
  const params = new URLSearchParams({
    client_id: publicConfig().googleClientId,
    response_type: "id_token",
    redirect_uri: redirectUri,
    scope: "openid email profile",
    nonce,
  });
  return `https://accounts.google.com/o/oauth2/v2/auth?${params.toString()}`;
}

export function parseIdTokenFromHash(hash: string): string | null {
  const params = new URLSearchParams(hash.replace(/^#/, ""));
  return params.get("id_token");
}
```

- [ ] **Step 2:** Write `app/signin/page.tsx`. The flow:
  1. On click, generate ephemeral keypair + randomness.
  2. Fetch current epoch → compute maxEpoch.
  3. Build nonce.
  4. Persist ephemeral state to sessionStorage (pre-OAuth).
  5. Redirect to Google.
  6. Google redirects back to `/signin#id_token=...` — we detect that in the same page and complete the flow: fetch salt → derive address → fetch zkProof → save full session → redirect to `/trade`.

```tsx
"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { getSuiClient } from "@/lib/sui/client";
import {
  generateRandomness,
  newEphemeralKeypair,
  restoreEphemeralKeypair,
  buildOauthNonce,
  deriveAddressFromJwt,
  computeMaxEpoch,
  saveSession,
  loadSession,
  type SessionStateV1,
} from "@/lib/zklogin/session";
import { buildGoogleOauthUrl, parseIdTokenFromHash } from "@/lib/zklogin/oauth";
import { getExtendedEphemeralPublicKey } from "@mysten/zklogin";

const PREOAUTH_KEY = "lighthouse.preoauth.v1";

interface PreOauth {
  secretKeyB64: string;
  randomness: string;
  maxEpoch: number;
}

export default function SignIn() {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // 1. Detect OAuth callback on mount
  useEffect(() => {
    const existing = loadSession();
    if (existing) {
      router.replace("/trade");
      return;
    }
    const jwt = typeof window !== "undefined" ? parseIdTokenFromHash(window.location.hash) : null;
    if (!jwt) return;

    const pre = JSON.parse(window.sessionStorage.getItem(PREOAUTH_KEY) ?? "null") as PreOauth | null;
    if (!pre) {
      setError("Lost pre-auth state. Please sign in again.");
      return;
    }

    (async () => {
      setBusy(true);
      try {
        // 2. Fetch salt
        const saltRes = await fetch("/api/zklogin/salt", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ jwt }),
        });
        if (!saltRes.ok) throw new Error(`salt ${saltRes.status}`);
        const { salt } = (await saltRes.json()) as { salt: string };

        const userAddress = deriveAddressFromJwt(jwt, salt);
        const kp = restoreEphemeralKeypair(pre.secretKeyB64);
        const extendedPk = getExtendedEphemeralPublicKey(kp.getPublicKey());

        // 3. Fetch zkProof
        const proveRes = await fetch("/api/zklogin/prove", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            jwt,
            extendedEphemeralPublicKey: extendedPk,
            maxEpoch: pre.maxEpoch,
            jwtRandomness: pre.randomness,
            salt,
            keyClaimName: "sub",
          }),
        });
        if (!proveRes.ok) throw new Error(`prove ${proveRes.status}`);
        const zkProof = await proveRes.json();

        // 4. Save session, clear preOauth, redirect
        const session: SessionStateV1 = {
          version: 1,
          ephemeralSecretKey: pre.secretKeyB64,
          jwt,
          salt,
          userAddress,
          maxEpoch: pre.maxEpoch,
          randomness: pre.randomness,
          zkProof,
        };
        saveSession(session);
        window.sessionStorage.removeItem(PREOAUTH_KEY);
        window.history.replaceState(null, "", "/signin");
        router.replace("/trade");
      } catch (e) {
        setError(String((e as Error).message ?? e));
        setBusy(false);
      }
    })();
  }, [router]);

  async function onSignIn() {
    setBusy(true);
    try {
      const client = getSuiClient();
      const { epoch } = await client.getLatestSuiSystemState();
      const currentEpoch = Number(epoch);
      const maxEpoch = computeMaxEpoch(currentEpoch);
      const { kp, secretKeyB64 } = newEphemeralKeypair();
      const randomness = generateRandomness();
      const nonce = buildOauthNonce(maxEpoch, kp, randomness);

      const preOauth: PreOauth = { secretKeyB64, randomness, maxEpoch };
      window.sessionStorage.setItem(PREOAUTH_KEY, JSON.stringify(preOauth));

      const redirect = `${window.location.origin}/signin`;
      window.location.href = buildGoogleOauthUrl(nonce, redirect);
    } catch (e) {
      setError(String(e));
      setBusy(false);
    }
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-bg-base text-white">
      <div className="max-w-md w-full rounded-xl border border-border-faint bg-bg-surface p-10 text-center">
        <div className="w-16 h-16 mx-auto mb-5 rounded-2xl flex items-center justify-center font-extrabold text-2xl"
          style={{ background: "linear-gradient(135deg, rgba(220,180,50,0.9), rgba(240,140,80,0.85))", color: "#0a0a14" }}>
          L
        </div>
        <h1 className="text-xl font-bold">Welcome to Lighthouse</h1>
        <p className="text-sm text-white/50 mt-2 mb-8 leading-relaxed">
          Predict where BTC settles at expiry — on a vault-backed prediction market running on Sui testnet.
          Sign in to get a testnet address, fund it with testnet USDsui, and start trading.
        </p>
        <button
          onClick={onSignIn}
          disabled={busy}
          className="w-full py-3 rounded-lg bg-white text-black font-semibold flex items-center gap-3 justify-center disabled:opacity-50"
        >
          {busy ? "Connecting…" : "Sign in with Google"}
        </button>
        {error && <div className="text-red text-xs mt-4">{error}</div>}
        <p className="text-[10px] text-white/30 mt-6 leading-relaxed">
          Testnet only · no real funds at risk · gas sponsored.
        </p>
      </div>
    </div>
  );
}
```

- [ ] **Step 3:** Typecheck.

```bash
cd apps/lighthouse && pnpm typecheck
```

Expected: PASS. If `getExtendedEphemeralPublicKey` import path differs in the installed `@mysten/zklogin` version, adjust; the function is part of the public API.

- [ ] **Step 4:** Commit.

```bash
git add apps/lighthouse/app/signin apps/lighthouse/lib/zklogin/oauth.ts
git commit -m "feat(lighthouse): add /signin page with zkLogin flow"
```

### Task 2.5: Auth boundary in root layout

**Files:**
- Create: `apps/lighthouse/components/nav/AuthBoundary.tsx`
- Modify: `apps/lighthouse/app/layout.tsx`

- [ ] **Step 1:** Write `components/nav/AuthBoundary.tsx` — client component that redirects unauthenticated users to `/signin` (except when already on `/signin`).

```tsx
"use client";

import { useEffect, useState } from "react";
import { usePathname, useRouter } from "next/navigation";
import { loadSession, type SessionStateV1 } from "@/lib/zklogin/session";

export function AuthBoundary({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();
  const [session, setSession] = useState<SessionStateV1 | null | "loading">("loading");

  useEffect(() => {
    const s = loadSession();
    setSession(s);
    if (!s && pathname !== "/signin") {
      router.replace("/signin");
    }
  }, [pathname, router]);

  if (session === "loading") return null;
  if (!session && pathname !== "/signin") return null;
  return <>{children}</>;
}
```

- [ ] **Step 2:** Update `app/layout.tsx`.

```tsx
import type { ReactNode } from "react";
import { AuthBoundary } from "@/components/nav/AuthBoundary";
import "./globals.css";

export const metadata = {
  title: "Lighthouse — DeepBook Predict",
  description: "Predict where BTC settles. Vault-backed prediction markets on Sui testnet.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <AuthBoundary>{children}</AuthBoundary>
      </body>
    </html>
  );
}
```

- [ ] **Step 3:** Commit.

```bash
git add apps/lighthouse/components/nav/AuthBoundary.tsx apps/lighthouse/app/layout.tsx
git commit -m "feat(lighthouse): redirect unauthenticated users to /signin"
```

Checkpoint 2 done. Proceed to Checkpoint 3.

---

## Checkpoint 3 — PTB builders, sponsored tx, faucet

**Gate at end:** From a signed-in session, calling `submit(tx)` with any of the builders successfully executes a testnet transaction (the user sees a digest). Faucet route mints testnet USDsui to a new user's wallet.

### Task 3.1: PTB builders

**Files:**
- Create: `apps/lighthouse/lib/sui/ptb.ts`

The builders return an unsigned `Transaction` — signing + execution happens in the sponsor route.

- [ ] **Step 1:** Write `lib/sui/ptb.ts`.

```ts
import { Transaction } from "@mysten/sui/transactions";
import { publicConfig } from "@/lib/config";
import { SUI_CLOCK_OBJECT_ID } from "@mysten/sui/utils";

/**
 * Create a fresh PredictManager for the signer. First-time users must call this
 * before minting any positions. The created manager is transferred to the sender.
 */
export function buildCreateManager(): Transaction {
  const { predictPackageId } = publicConfig();
  const tx = new Transaction();
  const managerId = tx.moveCall({
    target: `${predictPackageId}::predict_manager::create_manager`,
    arguments: [],
  });
  // create_manager returns the ID; the manager object itself is transferred inside the Move fn
  return tx;
}

/**
 * Deposit USDsui from the signer's wallet into their PredictManager (trading balance).
 */
export function buildDepositBalance(args: {
  managerId: string;
  amount: bigint;           // smallest unit
  walletCoinId: string;     // object ID of a USDsui Coin in the sender's wallet
}): Transaction {
  const { predictPackageId, usdsuiType } = publicConfig();
  const tx = new Transaction();
  const amountCoin = tx.splitCoins(tx.object(args.walletCoinId), [args.amount]);
  tx.moveCall({
    target: `${predictPackageId}::predict_manager::deposit`,
    typeArguments: [usdsuiType],
    arguments: [tx.object(args.managerId), amountCoin],
  });
  return tx;
}

/**
 * Withdraw USDsui from the PredictManager back into the signer's wallet.
 */
export function buildWithdrawBalance(args: {
  managerId: string;
  amount: bigint;
}): Transaction {
  const { predictPackageId, usdsuiType } = publicConfig();
  const tx = new Transaction();
  const coin = tx.moveCall({
    target: `${predictPackageId}::predict_manager::withdraw`,
    typeArguments: [usdsuiType],
    arguments: [tx.object(args.managerId), tx.pure.u64(args.amount)],
  });
  tx.transferObjects([coin], tx.pure.address("@sender"));
  return tx;
}

/**
 * Open a directional position (UP or DOWN at a given strike on a given oracle).
 * Requires a MarketKey (oracle_id, expiry, strike, is_up) constructed on-chain.
 */
export function buildMintPosition(args: {
  predictId: string;
  managerId: string;
  oracleId: string;
  expiryMs: bigint;
  strike: bigint;
  isUp: boolean;
  quantity: bigint;
}): Transaction {
  const { predictPackageId, usdsuiType } = publicConfig();
  const tx = new Transaction();
  const marketKey = tx.moveCall({
    target: `${predictPackageId}::market_key::new`,
    arguments: [
      tx.pure.address(args.oracleId),
      tx.pure.u64(args.expiryMs),
      tx.pure.u64(args.strike),
      tx.pure.bool(args.isUp),
    ],
  });
  tx.moveCall({
    target: `${predictPackageId}::predict::mint`,
    typeArguments: [usdsuiType],
    arguments: [
      tx.object(args.predictId),
      tx.object(args.managerId),
      tx.object(args.oracleId),
      marketKey,
      tx.pure.u64(args.quantity),
      tx.object(SUI_CLOCK_OBJECT_ID),
    ],
  });
  return tx;
}

/**
 * Close/redeem an open position. If the market is settled the payout is
 * deterministic (0 or 1 per contract); if active it's a vault bid.
 */
export function buildRedeemPosition(args: {
  predictId: string;
  managerId: string;
  oracleId: string;
  expiryMs: bigint;
  strike: bigint;
  isUp: boolean;
  quantity: bigint;
}): Transaction {
  const { predictPackageId, usdsuiType } = publicConfig();
  const tx = new Transaction();
  const marketKey = tx.moveCall({
    target: `${predictPackageId}::market_key::new`,
    arguments: [
      tx.pure.address(args.oracleId),
      tx.pure.u64(args.expiryMs),
      tx.pure.u64(args.strike),
      tx.pure.bool(args.isUp),
    ],
  });
  tx.moveCall({
    target: `${predictPackageId}::predict::redeem`,
    typeArguments: [usdsuiType],
    arguments: [
      tx.object(args.predictId),
      tx.object(args.managerId),
      tx.object(args.oracleId),
      marketKey,
      tx.pure.u64(args.quantity),
      tx.object(SUI_CLOCK_OBJECT_ID),
    ],
  });
  return tx;
}

/**
 * Supply USDsui to the PLP vault. Returns a PLP coin transferred to the sender.
 */
export function buildSupplyPlp(args: {
  predictId: string;
  amount: bigint;
  walletCoinId: string;
}): Transaction {
  const { predictPackageId, usdsuiType } = publicConfig();
  const tx = new Transaction();
  const amountCoin = tx.splitCoins(tx.object(args.walletCoinId), [args.amount]);
  const plpCoin = tx.moveCall({
    target: `${predictPackageId}::predict::supply`,
    typeArguments: [usdsuiType],
    arguments: [tx.object(args.predictId), amountCoin, tx.object(SUI_CLOCK_OBJECT_ID)],
  });
  tx.transferObjects([plpCoin], tx.pure.address("@sender"));
  return tx;
}

/**
 * Burn PLP and withdraw underlying USDsui.
 */
export function buildWithdrawPlp(args: {
  predictId: string;
  plpCoinId: string;
  amount: bigint;
}): Transaction {
  const { predictPackageId, usdsuiType } = publicConfig();
  const tx = new Transaction();
  const burnCoin = tx.splitCoins(tx.object(args.plpCoinId), [args.amount]);
  const usdsuiCoin = tx.moveCall({
    target: `${predictPackageId}::predict::withdraw`,
    typeArguments: [usdsuiType],
    arguments: [tx.object(args.predictId), burnCoin, tx.object(SUI_CLOCK_OBJECT_ID)],
  });
  tx.transferObjects([usdsuiCoin], tx.pure.address("@sender"));
  return tx;
}
```

- [ ] **Step 2:** Typecheck.

```bash
cd apps/lighthouse && pnpm typecheck
```

Expected: PASS. The `tx.pure.address("@sender")` special-cases: the sender address gets filled by the SDK during signing; this is safe for sponsored txs because the sponsor signs too.

- [ ] **Step 3:** Commit.

```bash
git add apps/lighthouse/lib/sui/ptb.ts
git commit -m "feat(lighthouse): add PTB builders for user txs"
```

### Task 3.2: Sponsor gas route — `/api/tx/sponsor`

**Files:**
- Create: `apps/lighthouse/app/api/tx/sponsor/route.ts`

The flow: client sends `{txBytes, signature}` (signature = user's zkLogin-wrapped ephemeral signature over the tx bytes). Server signs the gas side with the sponsor keypair, assembles the tx, and executes.

- [ ] **Step 1:** Write the route.

```ts
// app/api/tx/sponsor/route.ts
import { NextResponse } from "next/server";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { publicConfig, serverConfig } from "@/lib/config";

export const runtime = "nodejs";

interface SponsorRequest {
  txBytes: string;       // base64-encoded tx kind bytes (sender-less)
  userAddress: string;   // zkLogin-derived address (will be set as sender)
  userSignature: string; // zkLogin signature over the full bytes
}

export async function POST(req: Request) {
  const body = (await req.json()) as SponsorRequest;
  const { sponsorKey } = serverConfig();
  const { secretKey } = decodeSuiPrivateKey(sponsorKey);
  const sponsor = Ed25519Keypair.fromSecretKey(secretKey);
  const client = new SuiClient({ url: publicConfig().suiRpcUrl });

  // Rebuild tx from client-sent kind bytes
  const tx = Transaction.fromKind(Buffer.from(body.txBytes, "base64"));
  tx.setSender(body.userAddress);
  tx.setGasOwner(sponsor.toSuiAddress());

  const [gasCoin] = await client.getCoins({
    owner: sponsor.toSuiAddress(),
    coinType: "0x2::sui::SUI",
    limit: 1,
  }).then((r) => r.data);
  if (!gasCoin) return NextResponse.json({ error: "sponsor out of gas" }, { status: 503 });

  tx.setGasPayment([{
    objectId: gasCoin.coinObjectId,
    version: gasCoin.version,
    digest: gasCoin.digest,
  }]);
  tx.setGasBudget(50_000_000n);

  const fullBytes = await tx.build({ client });
  const sponsorSig = (await sponsor.signTransaction(fullBytes)).signature;

  const result = await client.executeTransactionBlock({
    transactionBlock: fullBytes,
    signature: [body.userSignature, sponsorSig],
    options: { showEffects: true, showEvents: true },
  });

  return NextResponse.json({ digest: result.digest, effects: result.effects });
}
```

- [ ] **Step 2:** Typecheck.

```bash
cd apps/lighthouse && pnpm typecheck
```

- [ ] **Step 3:** Commit.

```bash
git add apps/lighthouse/app/api/tx/sponsor
git commit -m "feat(lighthouse): add /api/tx/sponsor for sponsored execution"
```

### Task 3.3: Client-side tx executor hook

**Files:**
- Create: `apps/lighthouse/lib/sui/execute.ts`

- [ ] **Step 1:** Write the executor.

```ts
import { Transaction } from "@mysten/sui/transactions";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { genAddressSeed, getZkLoginSignature } from "@mysten/zklogin";
import { jwtDecode } from "jwt-decode";
import { restoreEphemeralKeypair, loadSession } from "@/lib/zklogin/session";
import { getSuiClient } from "@/lib/sui/client";

export interface ExecuteResult {
  digest: string;
  effects: unknown;
}

export async function executeSponsored(tx: Transaction): Promise<ExecuteResult> {
  const session = loadSession();
  if (!session) throw new Error("no session");
  if (!session.zkProof) throw new Error("no zkProof in session");

  const kp = restoreEphemeralKeypair(session.ephemeralSecretKey);
  const client: SuiClient = getSuiClient();

  // Build kind-only bytes (no gas yet)
  tx.setSender(session.userAddress);
  const kindBytes = await tx.build({ client, onlyTransactionKind: true });

  // Request sponsor to add gas + build full bytes
  // We actually do a round-trip: send kind to /api/tx/sponsor, server builds full bytes,
  // returns them to us, we sign, then server re-receives + executes.
  // For simpler flow: we build full bytes server-side, sign server-side, but zkLogin sig
  // needs the FULL tx bytes — so the server must send them back.
  //
  // Simpler alt: execute entirely client-side WITHOUT sponsor (works on testnet if
  // user has SUI). For MVP, use a two-step: /api/tx/sponsor-prepare -> /api/tx/sponsor-execute.
  // For brevity this MVP route does client-sign, sponsor-cosign, server-execute.

  // 1. Ask server to prepare full bytes with sponsor as gas owner
  const prep = await fetch("/api/tx/sponsor/prepare", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      kindBytes: Buffer.from(kindBytes).toString("base64"),
      userAddress: session.userAddress,
    }),
  });
  if (!prep.ok) throw new Error(`sponsor/prepare ${prep.status}`);
  const { fullBytesB64 } = (await prep.json()) as { fullBytesB64: string };
  const fullBytes = new Uint8Array(Buffer.from(fullBytesB64, "base64"));

  // 2. Sign full bytes client-side with ephemeral key + wrap in zkLogin envelope
  const { signature: userSig } = await kp.signTransaction(fullBytes);
  const { sub, aud } = jwtDecode<{ sub: string; aud: string | string[] }>(session.jwt);
  const addressSeed = genAddressSeed(
    BigInt(session.salt),
    "sub",
    sub,
    Array.isArray(aud) ? aud[0] : aud,
  ).toString();
  const zkLoginSig = getZkLoginSignature({
    inputs: { ...(session.zkProof as object), addressSeed },
    maxEpoch: session.maxEpoch,
    userSignature: userSig,
  });

  // 3. Send full bytes + zkLoginSig to server to execute
  const exec = await fetch("/api/tx/sponsor/execute", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      fullBytesB64,
      userSignature: zkLoginSig,
    }),
  });
  if (!exec.ok) throw new Error(`sponsor/execute ${exec.status}`);
  return exec.json() as Promise<ExecuteResult>;
}
```

**Note to the implementer:** The two-step `/api/tx/sponsor/prepare` + `/api/tx/sponsor/execute` split is required because zkLogin signs the **full** transaction bytes (including gas payment), but the user's ephemeral key is on the client. Replace the single `/api/tx/sponsor/route.ts` from Task 3.2 with two routes as shown in the next task.

- [ ] **Step 2:** Commit (as WIP — paired with Task 3.4).

```bash
git add apps/lighthouse/lib/sui/execute.ts
git commit -m "feat(lighthouse): client-side sponsored tx executor"
```

### Task 3.4: Split sponsor route into prepare + execute

**Files:**
- Delete: `apps/lighthouse/app/api/tx/sponsor/route.ts`
- Create: `apps/lighthouse/app/api/tx/sponsor/prepare/route.ts`
- Create: `apps/lighthouse/app/api/tx/sponsor/execute/route.ts`

- [ ] **Step 1:** Delete the old single route.

```bash
rm apps/lighthouse/app/api/tx/sponsor/route.ts
```

- [ ] **Step 2:** Write `prepare/route.ts`.

```ts
// app/api/tx/sponsor/prepare/route.ts
import { NextResponse } from "next/server";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { publicConfig, serverConfig } from "@/lib/config";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const body = (await req.json()) as { kindBytes: string; userAddress: string };
  const { sponsorKey } = serverConfig();
  const { secretKey } = decodeSuiPrivateKey(sponsorKey);
  const sponsor = Ed25519Keypair.fromSecretKey(secretKey);
  const client = new SuiClient({ url: publicConfig().suiRpcUrl });

  const tx = Transaction.fromKind(Buffer.from(body.kindBytes, "base64"));
  tx.setSender(body.userAddress);
  tx.setGasOwner(sponsor.toSuiAddress());

  const { data: coins } = await client.getCoins({
    owner: sponsor.toSuiAddress(),
    coinType: "0x2::sui::SUI",
    limit: 1,
  });
  if (!coins[0]) return NextResponse.json({ error: "sponsor out of gas" }, { status: 503 });

  tx.setGasPayment([{
    objectId: coins[0].coinObjectId,
    version: coins[0].version,
    digest: coins[0].digest,
  }]);
  tx.setGasBudget(50_000_000n);

  const fullBytes = await tx.build({ client });
  return NextResponse.json({ fullBytesB64: Buffer.from(fullBytes).toString("base64") });
}
```

- [ ] **Step 3:** Write `execute/route.ts`.

```ts
// app/api/tx/sponsor/execute/route.ts
import { NextResponse } from "next/server";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { publicConfig, serverConfig } from "@/lib/config";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const body = (await req.json()) as { fullBytesB64: string; userSignature: string };
  const { sponsorKey } = serverConfig();
  const { secretKey } = decodeSuiPrivateKey(sponsorKey);
  const sponsor = Ed25519Keypair.fromSecretKey(secretKey);
  const client = new SuiClient({ url: publicConfig().suiRpcUrl });

  const fullBytes = new Uint8Array(Buffer.from(body.fullBytesB64, "base64"));
  const sponsorSig = (await sponsor.signTransaction(fullBytes)).signature;

  try {
    const result = await client.executeTransactionBlock({
      transactionBlock: fullBytes,
      signature: [body.userSignature, sponsorSig],
      options: { showEffects: true, showEvents: true },
    });
    return NextResponse.json({ digest: result.digest, effects: result.effects });
  } catch (e) {
    return NextResponse.json({ error: String(e) }, { status: 400 });
  }
}
```

- [ ] **Step 4:** Typecheck.

```bash
cd apps/lighthouse && pnpm typecheck
```

- [ ] **Step 5:** Commit.

```bash
git add apps/lighthouse/app/api/tx/sponsor
git commit -m "feat(lighthouse): split sponsor into prepare+execute routes"
```

### Task 3.5: Faucet route — `/api/faucet/mint`

**Files:**
- Create: `apps/lighthouse/app/api/faucet/mint/route.ts`

Mints 10,000 testnet USDsui (from the `dusdcMint.ts` flow, but server-side). The faucet admin key owns the `TreasuryCap` for USDsui on testnet.

- [ ] **Step 1:** Write the route.

```ts
// app/api/faucet/mint/route.ts
import { NextResponse } from "next/server";
import { SuiClient } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { publicConfig, serverConfig } from "@/lib/config";

export const runtime = "nodejs";

const MINT_AMOUNT = 10_000_000_000n;       // 10_000 USDsui with 6 decimals
const USDSUI_TREASURY_CAP_ID = process.env.USDSUI_TREASURY_CAP_ID!;

export async function POST(req: Request) {
  const { recipient } = (await req.json()) as { recipient: string };
  if (!/^0x[0-9a-f]{64}$/i.test(recipient)) {
    return NextResponse.json({ error: "bad recipient" }, { status: 400 });
  }
  const { faucetKey } = serverConfig();
  const { secretKey } = decodeSuiPrivateKey(faucetKey);
  const faucet = Ed25519Keypair.fromSecretKey(secretKey);
  const client = new SuiClient({ url: publicConfig().suiRpcUrl });

  const tx = new Transaction();
  const minted = tx.moveCall({
    target: `0x2::coin::mint`,
    typeArguments: [publicConfig().usdsuiType],
    arguments: [tx.object(USDSUI_TREASURY_CAP_ID), tx.pure.u64(MINT_AMOUNT)],
  });
  tx.transferObjects([minted], tx.pure.address(recipient));

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer: faucet,
    options: { showEffects: true },
  });
  return NextResponse.json({ digest: result.digest });
}
```

- [ ] **Step 2:** Add `USDSUI_TREASURY_CAP_ID` + `FAUCET_ADMIN_KEY` to `.env.example`.

```bash
# append to apps/lighthouse/.env.example
USDSUI_TREASURY_CAP_ID=
```

- [ ] **Step 3:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/app/api/faucet apps/lighthouse/.env.example
git commit -m "feat(lighthouse): add /api/faucet/mint route"
```

Checkpoint 3 done. Proceed to Checkpoint 4.

---

## Checkpoint 4 — Nav shell + routing

**Gate at end:** Signed-in user sees TopNav on all three pages; `/trade`, `/vault`, `/portfolio` each render placeholder page content under the shared nav.

### Task 4.1: `StatusPill` + `Countdown` + `RefreshRing` common components

**Files:**
- Create: `apps/lighthouse/components/common/StatusPill.tsx`
- Create: `apps/lighthouse/components/common/Countdown.tsx`
- Create: `apps/lighthouse/components/common/RefreshRing.tsx`

- [ ] **Step 1:** Write `StatusPill.tsx`.

```tsx
type Status = "active" | "awaiting" | "settled";
const palette: Record<Status, { bg: string; text: string; label: string }> = {
  active:   { bg: "rgba(60,200,120,0.15)",  text: "rgba(60,200,120,0.95)",  label: "Active" },
  awaiting: { bg: "rgba(240,180,80,0.15)",  text: "rgba(240,180,80,0.95)",  label: "Awaiting settlement" },
  settled:  { bg: "rgba(170,180,240,0.15)", text: "rgba(170,180,240,0.95)", label: "Settled" },
};

export function StatusPill({ status }: { status: Status }) {
  const p = palette[status];
  return (
    <span
      className="text-[10px] font-semibold uppercase tracking-wider px-2 py-0.5 rounded-full"
      style={{ background: p.bg, color: p.text }}
    >
      ● {p.label}
    </span>
  );
}
```

- [ ] **Step 2:** Write `Countdown.tsx`.

```tsx
"use client";
import { useEffect, useState } from "react";
import { formatCountdown, formatCountdownCoarse } from "@/lib/formatters";

export function Countdown({
  targetMs,
  resolution = "second",
  className = "",
}: {
  targetMs: number;
  resolution?: "second" | "minute";
  className?: string;
}) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const tickMs = resolution === "second" ? 1000 : 30_000;
    const id = setInterval(() => setNow(Date.now()), tickMs);
    return () => clearInterval(id);
  }, [resolution]);
  const delta = targetMs - now;
  const label = resolution === "second" ? formatCountdown(delta) : formatCountdownCoarse(delta);
  return <span className={className}>{label}</span>;
}
```

- [ ] **Step 3:** Write `RefreshRing.tsx`.

```tsx
"use client";
import { useEffect, useState } from "react";

/**
 * Circular progress ring that depletes clockwise over `periodMs` and resets.
 * Uses CSS stroke-dashoffset animation keyed on a cycle counter so the ring
 * visibly restarts when a new quote arrives.
 */
export function RefreshRing({ periodMs = 3000, size = 20 }: { periodMs?: number; size?: number }) {
  const [cycle, setCycle] = useState(0);
  useEffect(() => {
    const id = setInterval(() => setCycle((c) => c + 1), periodMs);
    return () => clearInterval(id);
  }, [periodMs]);
  const r = size / 2 - 2;
  const circ = 2 * Math.PI * r;
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ transform: "rotate(-90deg)" }}>
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="rgba(255,255,255,0.08)" strokeWidth={2} />
      <circle
        key={cycle}
        cx={size / 2}
        cy={size / 2}
        r={r}
        fill="none"
        stroke="rgba(220,180,50,0.85)"
        strokeWidth={2}
        strokeLinecap="round"
        strokeDasharray={circ}
        style={{
          animation: `lh-refresh ${periodMs}ms linear forwards`,
          filter: "drop-shadow(0 0 2px rgba(220,180,50,0.5))",
        }}
      />
      <style>{`@keyframes lh-refresh { from { stroke-dashoffset: 0; } to { stroke-dashoffset: ${circ}; } }`}</style>
    </svg>
  );
}
```

- [ ] **Step 4:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/components/common
git commit -m "feat(lighthouse): add common StatusPill/Countdown/RefreshRing"
```

### Task 4.2: `TopNav` component

**Files:**
- Create: `apps/lighthouse/components/nav/TopNav.tsx`
- Create: `apps/lighthouse/components/nav/WalletMenu.tsx`

- [ ] **Step 1:** Write `WalletMenu.tsx`.

```tsx
"use client";
import { useState } from "react";
import { shortenAddress } from "@/lib/formatters";
import { loadSession, clearSession } from "@/lib/zklogin/session";
import { useRouter } from "next/navigation";

export function WalletMenu() {
  const [open, setOpen] = useState(false);
  const router = useRouter();
  const session = loadSession();
  if (!session) return null;

  function onSignOut() {
    clearSession();
    router.replace("/signin");
  }

  async function copy() {
    await navigator.clipboard.writeText(session!.userAddress);
  }

  return (
    <div className="relative">
      <button
        onClick={() => setOpen((v) => !v)}
        className="px-3 py-[7px] bg-white/5 rounded-full text-[11px] text-white/80 font-mono flex items-center gap-2"
      >
        <span
          className="w-4 h-4 rounded-full"
          style={{ background: "linear-gradient(135deg, rgba(60,200,120,0.8), rgba(100,150,240,0.8))" }}
        />
        {shortenAddress(session.userAddress)}
      </button>
      {open && (
        <div className="absolute right-0 mt-2 w-64 bg-bg-surface border border-border-faint rounded-lg p-3 z-50">
          <div className="text-xs text-white/60">Signed in</div>
          <div className="text-sm font-mono mt-1">{shortenAddress(session.userAddress)}</div>
          <button onClick={copy} className="mt-3 w-full text-left text-xs text-white/70 hover:text-white/95">
            Copy address
          </button>
          <button onClick={onSignOut} className="mt-2 w-full text-left text-xs text-red hover:opacity-80">
            Sign out
          </button>
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 2:** Write `TopNav.tsx`.

```tsx
"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { WalletMenu } from "./WalletMenu";

const tabs = [
  { href: "/trade", label: "Trade" },
  { href: "/vault", label: "Vault" },
  { href: "/portfolio", label: "Portfolio" },
];

export function TopNav() {
  const pathname = usePathname();
  return (
    <div className="flex items-center px-6 py-3 border-b border-border-faint gap-7">
      <div className="flex items-center gap-2 font-extrabold text-sm tracking-wide">
        <span
          className="w-2 h-2 rounded-full"
          style={{
            background: "linear-gradient(135deg, rgba(220,180,50,0.95), rgba(240,140,80,0.9))",
            boxShadow: "0 0 10px rgba(220,180,50,0.5)",
          }}
        />
        Lighthouse
        <span className="text-white/35 font-medium text-[10px] ml-1 tracking-widest">TESTNET</span>
      </div>
      <nav className="flex gap-1 flex-1">
        {tabs.map((t) => {
          const active = pathname?.startsWith(t.href);
          return (
            <Link
              key={t.href}
              href={t.href}
              className={`px-4 py-[7px] text-xs font-semibold rounded-md ${
                active ? "bg-gold-bg text-gold" : "text-white/50 hover:text-white/85"
              }`}
            >
              {t.label}
            </Link>
          );
        })}
      </nav>
      <WalletMenu />
    </div>
  );
}
```

- [ ] **Step 3:** Update `app/layout.tsx` to render the nav above all pages except `/signin`.

```tsx
import type { ReactNode } from "react";
import { headers } from "next/headers";
import { AuthBoundary } from "@/components/nav/AuthBoundary";
import { TopNav } from "@/components/nav/TopNav";
import "./globals.css";

export const metadata = {
  title: "Lighthouse — DeepBook Predict",
  description: "Predict where BTC settles. Vault-backed prediction markets on Sui testnet.",
};

export default async function RootLayout({ children }: { children: ReactNode }) {
  const pathname = (await headers()).get("x-pathname") ?? "";
  const hideNav = pathname === "/signin";
  return (
    <html lang="en">
      <body>
        <AuthBoundary>
          {!hideNav && <TopNav />}
          {children}
        </AuthBoundary>
      </body>
    </html>
  );
}
```

Since `x-pathname` is not set by default in Next 15, the cleaner alternative is to just always render TopNav and have `/signin` use a route group `(signin)` with its own layout. Swap to that pattern if the header approach is brittle.

- [ ] **Step 4:** Alternative cleaner layout — route groups. Delete the header-based switch and use `app/(app)/layout.tsx` for authenticated routes. For this plan step, keep the simpler approach: wrap TopNav in a client component that reads `usePathname` and self-hides.

Rewrite `TopNav.tsx` to self-hide:

```tsx
// Add at top of TopNav component, inside `export function TopNav`:
const pathname = usePathname();
if (pathname === "/signin") return null;
// ...rest unchanged
```

And revert layout.tsx to always render TopNav.

```tsx
import type { ReactNode } from "react";
import { AuthBoundary } from "@/components/nav/AuthBoundary";
import { TopNav } from "@/components/nav/TopNav";
import "./globals.css";

export const metadata = {
  title: "Lighthouse — DeepBook Predict",
  description: "Predict where BTC settles. Vault-backed prediction markets on Sui testnet.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <AuthBoundary>
          <TopNav />
          {children}
        </AuthBoundary>
      </body>
    </html>
  );
}
```

- [ ] **Step 5:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/components/nav apps/lighthouse/app/layout.tsx
git commit -m "feat(lighthouse): add TopNav + WalletMenu"
```

### Task 4.3: Placeholder pages for `/trade`, `/vault`, `/portfolio`

**Files:**
- Create: `apps/lighthouse/app/trade/page.tsx`
- Create: `apps/lighthouse/app/vault/page.tsx`
- Create: `apps/lighthouse/app/portfolio/page.tsx`

- [ ] **Step 1:** Write `app/trade/page.tsx`.

```tsx
export default function TradePage() {
  return (
    <main className="p-6">
      <div className="text-xs tracking-widest uppercase text-white/40">Trade</div>
      <div className="mt-4 text-sm text-white/60">Checkpoint 5 will render the trade view here.</div>
    </main>
  );
}
```

- [ ] **Step 2:** Write `app/vault/page.tsx`.

```tsx
export default function VaultPage() {
  return (
    <main className="p-6">
      <div className="text-xs tracking-widest uppercase text-white/40">Vault</div>
      <div className="mt-4 text-sm text-white/60">Checkpoint 7 will render the vault page here.</div>
    </main>
  );
}
```

- [ ] **Step 3:** Write `app/portfolio/page.tsx`.

```tsx
export default function PortfolioPage() {
  return (
    <main className="p-6">
      <div className="text-xs tracking-widest uppercase text-white/40">Portfolio</div>
      <div className="mt-4 text-sm text-white/60">Checkpoint 8 will render the portfolio here.</div>
    </main>
  );
}
```

- [ ] **Step 4:** Build and boot dev server. Visit each route manually; nav should be visible on all three, hidden on `/signin`.

```bash
cd apps/lighthouse && pnpm build
cd apps/lighthouse && pnpm dev
```

Expected: build succeeds; dev boots. (Manual browser check is fine for MVP; Playwright e2e in Checkpoint 9 will regress this.)

- [ ] **Step 5:** Commit.

```bash
git add apps/lighthouse/app/trade apps/lighthouse/app/vault apps/lighthouse/app/portfolio
git commit -m "feat(lighthouse): add placeholder routes under nav shell"
```

Checkpoint 4 done. Proceed to Checkpoint 5.

---

## Checkpoint 5 — Trade view: chart, wheel, quote rail, live pricing

**Gate at end:** `/trade` renders the full trade view against real testnet data — expiry chips, BTC chart, strike wheel, live UP/DOWN prices updating on each oracle event. Clicking "Buy" submits a real sponsored tx and shows a digest.

### Task 5.1: Event subscription — `lib/sui/events.ts`

**Files:**
- Create: `apps/lighthouse/lib/sui/events.ts`

- [ ] **Step 1:** Write event subscriber.

```ts
import { getSuiClient } from "./client";
import { publicConfig } from "@/lib/config";

export interface OraclePricesEvent {
  oracle_id: string;
  spot: string;
  forward: string;
  timestamp: string;
}

export interface OracleSviEvent {
  oracle_id: string;
  a: string;
  b: string;
  rho: { magnitude: string; is_negative: boolean };
  m: { magnitude: string; is_negative: boolean };
  sigma: string;
  timestamp: string;
}

export type OracleEvent =
  | { kind: "prices"; parsed: OraclePricesEvent }
  | { kind: "svi"; parsed: OracleSviEvent };

export function subscribeOracleEvents(
  oracleId: string,
  onEvent: (e: OracleEvent) => void,
): () => void {
  const client = getSuiClient();
  const { predictPackageId } = publicConfig();

  let alive = true;
  let unsubscribe: null | (() => Promise<boolean>) = null;

  (async () => {
    try {
      unsubscribe = await client.subscribeEvent({
        filter: {
          All: [
            { Package: predictPackageId },
            { MoveModule: { package: predictPackageId, module: "oracle" } },
          ],
        },
        onMessage: (raw) => {
          if (!alive) return;
          const type = raw.type;
          const parsedJson = raw.parsedJson as Record<string, unknown>;
          if (parsedJson && parsedJson["oracle_id"] !== oracleId) return;
          if (type.endsWith("::OraclePricesUpdated")) {
            onEvent({ kind: "prices", parsed: parsedJson as unknown as OraclePricesEvent });
          } else if (type.endsWith("::OracleSVIUpdated")) {
            onEvent({ kind: "svi", parsed: parsedJson as unknown as OracleSviEvent });
          }
        },
      });
    } catch (e) {
      console.warn("oracle ws failed, falling back to poll", e);
      startPoller(oracleId, onEvent, () => alive);
    }
  })();

  return () => {
    alive = false;
    if (unsubscribe) unsubscribe().catch(() => {});
  };
}

async function startPoller(
  oracleId: string,
  onEvent: (e: OracleEvent) => void,
  alive: () => boolean,
) {
  const { predictServer } = await import("@/lib/api/predict-server");
  while (alive()) {
    try {
      const [prices, svi] = await Promise.all([
        predictServer.oracleLatestPrice(oracleId),
        predictServer.oracleLatestSvi(oracleId),
      ]);
      onEvent({
        kind: "prices",
        parsed: {
          oracle_id: prices.oracle_id,
          spot: String(prices.spot),
          forward: String(prices.forward),
          timestamp: String(prices.timestamp),
        },
      });
      onEvent({
        kind: "svi",
        parsed: {
          oracle_id: svi.oracle_id,
          a: String(svi.a),
          b: String(svi.b),
          rho: { magnitude: String(Math.abs(svi.rho)), is_negative: svi.rho < 0 },
          m: { magnitude: String(Math.abs(svi.m)), is_negative: svi.m < 0 },
          sigma: String(svi.sigma),
          timestamp: String(svi.timestamp),
        },
      });
    } catch { /* swallow */ }
    await new Promise((r) => setTimeout(r, 3000));
  }
}
```

- [ ] **Step 2:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/lib/sui/events.ts
git commit -m "feat(lighthouse): subscribe to on-chain oracle events"
```

### Task 5.2: `useLivePricing` hook

**Files:**
- Create: `apps/lighthouse/lib/pricing/useLivePricing.ts`

- [ ] **Step 1:** Write the hook.

```ts
"use client";
import { useEffect, useState } from "react";
import { subscribeOracleEvents } from "@/lib/sui/events";
import { computeUpPrice, computeDownPrice, type SviParams } from "./svi";

export interface LiveState {
  spot: number | null;
  forward: number | null;
  svi: SviParams | null;
  lastUpdateMs: number | null;
}

const SCALE_PRICE = 1_000_000;   // prices arrive in 1e-6 integer units
const SCALE_SVI = 1_000_000;     // SVI params arrive scaled

function i64(v: { magnitude: string; is_negative: boolean }): number {
  return (Number(v.magnitude) / SCALE_SVI) * (v.is_negative ? -1 : 1);
}

export function useLivePricing(oracleId: string | null): LiveState {
  const [state, setState] = useState<LiveState>({ spot: null, forward: null, svi: null, lastUpdateMs: null });
  useEffect(() => {
    if (!oracleId) return;
    const unsub = subscribeOracleEvents(oracleId, (e) => {
      if (e.kind === "prices") {
        setState((s) => ({
          ...s,
          spot: Number(e.parsed.spot) / SCALE_PRICE,
          forward: Number(e.parsed.forward) / SCALE_PRICE,
          lastUpdateMs: Number(e.parsed.timestamp),
        }));
      } else {
        setState((s) => ({
          ...s,
          svi: {
            a: Number(e.parsed.a) / SCALE_SVI,
            b: Number(e.parsed.b) / SCALE_SVI,
            rho: i64(e.parsed.rho),
            m: i64(e.parsed.m),
            sigma: Number(e.parsed.sigma) / SCALE_SVI,
          },
          lastUpdateMs: Number(e.parsed.timestamp),
        }));
      }
    });
    return unsub;
  }, [oracleId]);
  return state;
}

export function computeLiveQuote(input: {
  live: LiveState;
  strike: number;
  expiryMs: number;
  riskFreeRateBps?: number;
}): { up: number; down: number } | null {
  const { live, strike, expiryMs, riskFreeRateBps = 0 } = input;
  if (!live.spot || !live.forward || !live.svi) return null;
  const base = {
    spot: live.spot,
    forward: live.forward,
    strike,
    svi: live.svi,
    nowMs: Date.now(),
    expiryMs,
    riskFreeRateBps,
  };
  return { up: computeUpPrice(base), down: computeDownPrice(base) };
}
```

- [ ] **Step 2:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/lib/pricing/useLivePricing.ts
git commit -m "feat(lighthouse): useLivePricing hook wiring events -> SVI -> UP/DOWN"
```

### Task 5.3: `ExpiryChips` component

**Files:**
- Create: `apps/lighthouse/components/trade/ExpiryChips.tsx`

- [ ] **Step 1:** Write the component.

```tsx
"use client";
import { Countdown } from "@/components/common/Countdown";
import type { Oracle } from "@/lib/api/predict-server";

export function ExpiryChips({
  oracles,
  selectedId,
  onSelect,
}: {
  oracles: Oracle[];
  selectedId: string | null;
  onSelect: (id: string) => void;
}) {
  return (
    <div className="flex gap-1.5 flex-1 justify-center">
      {oracles.map((o) => {
        const active = o.oracle_id === selectedId;
        const date = new Date(o.expiry).toUTCString().slice(5, 11);
        const urgent = o.expiry - Date.now() < 24 * 3600 * 1000;
        return (
          <button
            key={o.oracle_id}
            onClick={() => onSelect(o.oracle_id)}
            className={`px-3.5 py-2.5 rounded-lg min-w-[98px] text-center border transition ${
              active
                ? "bg-gold-bg text-gold border-gold-border"
                : "bg-white/5 text-white/50 border-transparent hover:bg-white/10"
            }`}
          >
            <div className="text-xs font-semibold">{date}</div>
            <div
              className={`text-[11px] mt-0.5 font-mono ${
                urgent && !active ? "text-amber" : active ? "text-gold-dim" : "text-white/35"
              }`}
            >
              <Countdown targetMs={o.expiry} resolution="minute" />
            </div>
          </button>
        );
      })}
    </div>
  );
}
```

- [ ] **Step 2:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/components/trade/ExpiryChips.tsx
git commit -m "feat(lighthouse): expiry chips with coarse countdowns"
```

### Task 5.4: `StrikeWheel` component (canvas)

**Files:**
- Create: `apps/lighthouse/components/trade/StrikeWheel.tsx`

This is a React wrapper around a canvas; the drawing + interaction logic is ported verbatim from `charts_btc.html` lines 444–620 (the `drawWheel` + scroll handlers).

- [ ] **Step 1:** Write the component.

```tsx
"use client";
import { useEffect, useRef } from "react";

export interface StrikeWheelProps {
  centerStrike: number;     // the strike nearest center (selected)
  minStrike: number;
  maxStrike: number;
  tickSize: number;         // dollar step between adjacent strikes
  onChange: (strike: number) => void;
  height?: number;          // CSS px; canvas is 2x for retina
  width?: number;
}

export function StrikeWheel({
  centerStrike,
  minStrike,
  maxStrike,
  tickSize,
  onChange,
  height = 500,
  width = 90,
}: StrikeWheelProps) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const stateRef = useRef({
    scrollPos: 0,
    velocity: 0,
    isDragging: false,
    lastY: 0,
  });

  useEffect(() => {
    const strikeCount = Math.floor((maxStrike - minStrike) / tickSize) + 1;
    const idx = Math.round((maxStrike - centerStrike) / tickSize);
    stateRef.current.scrollPos = Math.max(0, Math.min(strikeCount - 1, idx));
  }, [centerStrike, minStrike, maxStrike, tickSize]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const W = canvas.width;  // retina-doubled
    const H = canvas.height;
    const ITEM_H = 60;       // canvas px per item
    const strikeCount = Math.floor((maxStrike - minStrike) / tickSize) + 1;

    function draw() {
      ctx.clearRect(0, 0, W, H);
      const centerY = H / 2;
      const center = stateRef.current.scrollPos;
      const visible = Math.ceil(H / ITEM_H) + 4;

      for (let off = -Math.floor(visible / 2); off <= Math.ceil(visible / 2); off++) {
        const i = Math.round(center) + off;
        if (i < 0 || i >= strikeCount) continue;
        const strike = maxStrike - i * tickSize;
        const y = centerY + (i - center) * ITEM_H;
        const dist = Math.abs(y - centerY);
        const maxDist = H / 2;
        const norm = Math.min(dist / maxDist, 1);
        const fontSize = 28 - norm * 10;
        const opacity = Math.max(0, 0.9 - norm * 1.1);
        if (opacity <= 0) continue;
        const isCenter = dist < ITEM_H * 0.5;
        ctx.fillStyle = isCenter
          ? `rgba(220, 180, 50, ${opacity})`
          : `rgba(255, 255, 255, ${opacity * 0.45})`;
        ctx.font = `${isCenter ? 700 : 500} ${fontSize.toFixed(0)}px 'SF Mono', monospace`;
        ctx.textAlign = "center";
        ctx.fillText(`$${strike.toLocaleString()}`, W / 2, y);
      }
    }

    function animate() {
      const s = stateRef.current;
      if (!s.isDragging && Math.abs(s.velocity) > 0.01) {
        s.scrollPos += s.velocity;
        s.velocity *= 0.92;
        s.scrollPos = Math.max(0, Math.min(strikeCount - 1, s.scrollPos));
        draw();
        const strike = maxStrike - Math.round(s.scrollPos) * tickSize;
        onChange(strike);
      } else if (!s.isDragging && Math.abs(s.scrollPos - Math.round(s.scrollPos)) > 0.01) {
        // Snap to nearest integer strike
        s.scrollPos += (Math.round(s.scrollPos) - s.scrollPos) * 0.2;
        draw();
      }
      requestAnimationFrame(animate);
    }

    function onWheel(e: WheelEvent) {
      e.preventDefault();
      const s = stateRef.current;
      s.scrollPos += e.deltaY / 60;
      s.scrollPos = Math.max(0, Math.min(strikeCount - 1, s.scrollPos));
      draw();
      onChange(maxStrike - Math.round(s.scrollPos) * tickSize);
    }

    function onMouseDown(e: MouseEvent) {
      stateRef.current.isDragging = true;
      stateRef.current.lastY = e.clientY;
      stateRef.current.velocity = 0;
    }
    function onMouseMove(e: MouseEvent) {
      const s = stateRef.current;
      if (!s.isDragging) return;
      const dy = e.clientY - s.lastY;
      s.lastY = e.clientY;
      s.scrollPos -= dy / (ITEM_H / 2);
      s.scrollPos = Math.max(0, Math.min(strikeCount - 1, s.scrollPos));
      s.velocity = -dy / (ITEM_H / 2);
      draw();
      onChange(maxStrike - Math.round(s.scrollPos) * tickSize);
    }
    function onMouseUp() {
      stateRef.current.isDragging = false;
    }

    draw();
    const rafId = requestAnimationFrame(animate);
    canvas.addEventListener("wheel", onWheel, { passive: false });
    canvas.addEventListener("mousedown", onMouseDown);
    window.addEventListener("mousemove", onMouseMove);
    window.addEventListener("mouseup", onMouseUp);

    return () => {
      cancelAnimationFrame(rafId);
      canvas.removeEventListener("wheel", onWheel);
      canvas.removeEventListener("mousedown", onMouseDown);
      window.removeEventListener("mousemove", onMouseMove);
      window.removeEventListener("mouseup", onMouseUp);
    };
  }, [minStrike, maxStrike, tickSize, onChange]);

  return (
    <div className="relative" style={{ width, height, background: "var(--bg-wheel, #14141f)" }}>
      <div className="absolute top-0 left-0 right-0 py-1.5 text-center text-[9px] uppercase tracking-widest text-white/35 font-semibold border-b border-white/5">
        Strike
      </div>
      <canvas
        ref={canvasRef}
        width={width * 2}
        height={height * 2}
        style={{ width, height, display: "block", cursor: "ns-resize" }}
      />
      <div
        className="absolute left-0 right-0 pointer-events-none"
        style={{
          top: "50%",
          height: 30,
          marginTop: -15,
          background: "rgba(220,180,50,0.06)",
          borderTop: "1px solid rgba(220,180,50,0.2)",
          borderBottom: "1px solid rgba(220,180,50,0.2)",
        }}
      />
      <div
        className="absolute top-0 left-0 right-0 pointer-events-none"
        style={{ height: 80, background: "linear-gradient(to bottom, var(--bg-wheel, #14141f), transparent)" }}
      />
      <div
        className="absolute bottom-0 left-0 right-0 pointer-events-none"
        style={{ height: 80, background: "linear-gradient(to top, var(--bg-wheel, #14141f), transparent)" }}
      />
    </div>
  );
}
```

- [ ] **Step 2:** Add `--bg-wheel` to `globals.css`.

```css
:root {
  --bg-base: #0a0a14;
  --bg-surface: #12121e;
  --bg-rail: #0e0e18;
  --bg-wheel: #14141f;
}
```

- [ ] **Step 3:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/components/trade/StrikeWheel.tsx apps/lighthouse/app/globals.css
git commit -m "feat(lighthouse): port charts_btc.html strike wheel as React canvas"
```

### Task 5.5: `HeroChart` component (BTC spot)

**Files:**
- Create: `apps/lighthouse/components/trade/HeroChart.tsx`

- [ ] **Step 1:** Write the component using `lightweight-charts`.

```tsx
"use client";
import { useEffect, useRef } from "react";
import { createChart, ColorType, type IChartApi, type ISeriesApi } from "lightweight-charts";

export interface PricePoint { time: number; value: number; }

export function HeroChart({
  series,
  strike,
  height = 380,
}: {
  series: PricePoint[];
  strike: number | null;
  height?: number;
}) {
  const ref = useRef<HTMLDivElement | null>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const lineRef = useRef<ISeriesApi<"Area"> | null>(null);

  useEffect(() => {
    if (!ref.current) return;
    const chart = createChart(ref.current, {
      height,
      autoSize: true,
      layout: {
        background: { type: ColorType.Solid, color: "transparent" },
        textColor: "rgba(255,255,255,0.45)",
      },
      grid: {
        vertLines: { color: "rgba(255,255,255,0.04)" },
        horzLines: { color: "rgba(255,255,255,0.04)" },
      },
      rightPriceScale: { borderVisible: false },
      timeScale: { borderVisible: false, timeVisible: true, secondsVisible: false },
    });
    const area = chart.addAreaSeries({
      topColor: "rgba(220,180,50,0.3)",
      bottomColor: "rgba(220,180,50,0.01)",
      lineColor: "rgba(220,180,50,0.95)",
      lineWidth: 2,
    });
    chartRef.current = chart;
    lineRef.current = area;
    return () => chart.remove();
  }, [height]);

  useEffect(() => {
    if (!lineRef.current) return;
    lineRef.current.setData(series.map((p) => ({ time: (p.time / 1000) as any, value: p.value })));
  }, [series]);

  useEffect(() => {
    if (!chartRef.current || !lineRef.current || strike === null) return;
    lineRef.current.createPriceLine({
      price: strike,
      color: "rgba(220,180,50,0.6)",
      lineStyle: 2, // dashed
      lineWidth: 1,
      axisLabelVisible: true,
      title: `$${strike.toLocaleString()}`,
    });
  }, [strike]);

  return <div ref={ref} style={{ height }} />;
}
```

- [ ] **Step 2:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/components/trade/HeroChart.tsx
git commit -m "feat(lighthouse): BTC hero chart via lightweight-charts"
```

### Task 5.6: `QuoteRail` component

**Files:**
- Create: `apps/lighthouse/components/trade/QuoteRail.tsx`

- [ ] **Step 1:** Write the component.

```tsx
"use client";
import { useTradeStore } from "@/store/trade";
import { RefreshRing } from "@/components/common/RefreshRing";
import { formatUsd } from "@/lib/formatters";

export interface QuoteRailProps {
  strike: number | null;
  upPrice: number | null;
  downPrice: number | null;
  spreadBps: number | null;
  onBuy: () => void;
  busy?: boolean;
}

export function QuoteRail(props: QuoteRailProps) {
  const { strike, upPrice, downPrice, spreadBps, onBuy, busy } = props;
  const { selectedSide, setSide, sizeUsd, setSize } = useTradeStore();

  const priceThisSide = selectedSide === "UP" ? upPrice : downPrice;
  const maxPayout = priceThisSide ? sizeUsd / priceThisSide : 0;

  return (
    <aside className="w-[300px] bg-bg-rail flex flex-col">
      <div className="flex justify-between items-center px-4 py-3 border-b border-border-faint">
        <div className="text-[11px] uppercase tracking-wider text-white/50 font-semibold">
          Quote <span className="text-white/75 normal-case tracking-normal font-mono">live</span>
        </div>
        <RefreshRing periodMs={3000} />
      </div>

      <div className="p-4 flex flex-col gap-3">
        {strike !== null && (
          <div className="px-3 py-2.5 rounded-md border border-gold-border bg-gold-bg/60">
            <div className="text-[10px] uppercase tracking-wider text-gold-dim font-semibold">Selected strike</div>
            <div className="text-xl font-bold font-mono text-gold">${strike.toLocaleString()}</div>
          </div>
        )}

        <div>
          <h4 className="text-[10px] uppercase tracking-wider text-white/40 font-semibold mb-1.5">Side</h4>
          <div className="flex flex-col gap-1.5">
            <button
              onClick={() => setSide("UP")}
              className={`px-3.5 py-3 rounded-lg border flex justify-between items-center ${
                selectedSide === "UP"
                  ? "border-green-500/45 bg-green-500/10"
                  : "border-white/6 bg-transparent"
              }`}
            >
              <div className="flex flex-col gap-0.5 text-left">
                <span className="text-[10px] font-semibold tracking-wide text-white/50">UP</span>
                <span className="text-[10px] text-white/35">BTC &gt; ${strike?.toLocaleString() ?? "—"}</span>
              </div>
              <span className="text-lg font-bold font-mono text-green">
                {upPrice !== null ? `$${upPrice.toFixed(4)}` : "—"}
              </span>
            </button>
            <button
              onClick={() => setSide("DOWN")}
              className={`px-3.5 py-3 rounded-lg border flex justify-between items-center ${
                selectedSide === "DOWN"
                  ? "border-red/35 bg-red-bg"
                  : "border-white/6 bg-transparent"
              }`}
            >
              <div className="flex flex-col gap-0.5 text-left">
                <span className="text-[10px] font-semibold tracking-wide text-white/50">DOWN</span>
                <span className="text-[10px] text-white/35">BTC ≤ ${strike?.toLocaleString() ?? "—"}</span>
              </div>
              <span className="text-lg font-bold font-mono text-red">
                {downPrice !== null ? `$${downPrice.toFixed(4)}` : "—"}
              </span>
            </button>
          </div>
        </div>

        <div>
          <h4 className="text-[10px] uppercase tracking-wider text-white/40 font-semibold mb-1.5">Size</h4>
          <div className="px-4 py-3.5 rounded-lg bg-white/2 border border-white/5">
            <div className="flex justify-between items-baseline">
              <input
                type="number"
                value={sizeUsd}
                onChange={(e) => setSize(Number(e.target.value))}
                className="bg-transparent text-2xl font-bold font-mono outline-none w-32"
              />
              <span className="text-[11px] text-white/40">USDsui</span>
            </div>
            <div className="text-[11px] text-white/40 mt-1">
              ≈ {priceThisSide ? Math.floor(sizeUsd / priceThisSide) : 0} contracts
            </div>
          </div>
          <div className="grid grid-cols-4 gap-1 mt-1.5">
            {[10, 50, 100, 500].map((v) => (
              <button
                key={v}
                onClick={() => setSize(v)}
                className={`py-1.5 text-[11px] rounded ${
                  sizeUsd === v ? "bg-gold-bg text-gold" : "bg-white/4 text-white/60"
                }`}
              >
                ${v}
              </button>
            ))}
          </div>
        </div>

        <div className="text-[11px] flex flex-col gap-1.5 p-2.5 bg-white/2 rounded-md">
          <div className="flex justify-between">
            <span className="text-white/45">Ask price</span>
            <b className="font-mono text-white/90">
              {priceThisSide !== null ? `$${priceThisSide.toFixed(4)}` : "—"}
            </b>
          </div>
          <div className="flex justify-between">
            <span className="text-white/45">Max payout</span>
            <b className="font-mono text-white/90">{formatUsd(maxPayout)}</b>
          </div>
          <div className="flex justify-between">
            <span className="text-white/45">Spread</span>
            <b className="font-mono text-white/90">
              {spreadBps !== null ? `${(spreadBps / 100).toFixed(2)}%` : "—"}
            </b>
          </div>
        </div>

        <button
          disabled={busy || priceThisSide === null || strike === null}
          onClick={onBuy}
          className="w-full py-3.5 bg-green text-black font-bold text-sm rounded-lg disabled:opacity-50"
          style={{ background: selectedSide === "DOWN" ? "rgba(240,100,100,0.9)" : "rgba(60,200,120,0.9)" }}
        >
          {busy ? "Submitting…" : `Buy ${selectedSide} ${selectedSide === "UP" ? ">" : "≤"} $${strike?.toLocaleString() ?? "—"} → ${formatUsd(sizeUsd)}`}
        </button>
      </div>
    </aside>
  );
}
```

- [ ] **Step 2:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/components/trade/QuoteRail.tsx
git commit -m "feat(lighthouse): QuoteRail with UP/DOWN pills, size presets, CTA"
```

### Task 5.7: Wire Trade page end-to-end

**Files:**
- Modify: `apps/lighthouse/app/trade/page.tsx`

- [ ] **Step 1:** Replace the placeholder with the real trade page.

```tsx
"use client";
import useSWR from "swr";
import { useEffect, useState } from "react";
import { predictServer, type Oracle } from "@/lib/api/predict-server";
import { useTradeStore } from "@/store/trade";
import { useLivePricing, computeLiveQuote } from "@/lib/pricing/useLivePricing";
import { applySpread } from "@/lib/pricing/spread";
import { ExpiryChips } from "@/components/trade/ExpiryChips";
import { StrikeWheel } from "@/components/trade/StrikeWheel";
import { HeroChart } from "@/components/trade/HeroChart";
import { QuoteRail } from "@/components/trade/QuoteRail";
import { StatusPill } from "@/components/common/StatusPill";
import { Countdown } from "@/components/common/Countdown";
import { buildMintPosition } from "@/lib/sui/ptb";
import { executeSponsored } from "@/lib/sui/execute";
import { publicConfig } from "@/lib/config";
import { loadSession } from "@/lib/zklogin/session";

export default function TradePage() {
  const { data: oracles } = useSWR<Oracle[]>("/oracles", () => predictServer.oracles(), { refreshInterval: 10_000 });
  const { selectedOracleId, setOracleId, selectedStrike, setStrike, sizeUsd, selectedSide } = useTradeStore();
  const [busy, setBusy] = useState(false);
  const [digest, setDigest] = useState<string | null>(null);

  const active = oracles?.filter((o) => !o.settled_at) ?? [];
  useEffect(() => {
    if (!selectedOracleId && active[0]) setOracleId(active[0].oracle_id);
  }, [active, selectedOracleId, setOracleId]);

  const oracle = active.find((o) => o.oracle_id === selectedOracleId) ?? null;
  const live = useLivePricing(oracle?.oracle_id ?? null);

  const strike = selectedStrike ?? (oracle?.min_strike ? Math.round(live.spot ?? oracle.min_strike) : null);
  const quote = oracle && strike !== null
    ? computeLiveQuote({ live, strike, expiryMs: oracle.expiry })
    : null;

  const spreadBps = 40;  // TODO fetch from predict.pricing_config via /config; placeholder 0.4%
  const midUp = quote?.up ?? null;
  const midDown = quote?.down ?? null;
  const askUp = midUp !== null ? applySpread({ midPrice: midUp, baseSpreadBps: spreadBps, utilizationPct: 37, utilizationMultiplier: 2, minSpreadBps: 5 }).ask : null;
  const askDown = midDown !== null ? applySpread({ midPrice: midDown, baseSpreadBps: spreadBps, utilizationPct: 37, utilizationMultiplier: 2, minSpreadBps: 5 }).ask : null;

  async function onBuy() {
    if (!oracle || strike === null) return;
    const session = loadSession();
    if (!session) return;
    const ask = (selectedSide === "UP" ? askUp : askDown) ?? 0;
    if (ask <= 0) return;
    const quantity = BigInt(Math.floor(sizeUsd / ask));
    if (quantity <= 0n) return;
    setBusy(true);
    try {
      // Manager is provisioned separately in Task 5.8 (getOrCreateManager).
      // This temporary read-from-sessionStorage gets replaced in that task.
      const managerId = window.sessionStorage.getItem("lighthouse.managerId");
      if (!managerId) throw new Error("manager not provisioned");
      const tx = buildMintPosition({
        predictId: publicConfig().predictId,
        managerId,
        oracleId: oracle.oracle_id,
        expiryMs: BigInt(oracle.expiry),
        strike: BigInt(strike * 1_000_000),  // match Move u64 scale (strikes in 1e-6 USD)
        isUp: selectedSide === "UP",
        quantity,
      });
      const res = await executeSponsored(tx);
      setDigest(res.digest);
    } catch (e) {
      alert(`Mint failed: ${(e as Error).message}`);
    } finally {
      setBusy(false);
    }
  }

  if (!oracle) return <div className="p-6 text-white/50">Loading oracles…</div>;

  return (
    <main className="text-white">
      <div className="flex justify-between items-center px-5 py-3.5 border-b border-border-faint gap-4">
        <div className="flex flex-col gap-0.5">
          <div className="font-bold text-base flex gap-2 items-center">
            BTC <StatusPill status={oracle.settled_at ? "settled" : (oracle.expiry < Date.now() ? "awaiting" : "active")} />
          </div>
          <div className="text-[10px] text-white/40">Oracle · Block Scholes SVI · updates ~1–2s</div>
        </div>
        <ExpiryChips oracles={active} selectedId={selectedOracleId} onSelect={setOracleId} />
        <div className="text-right text-[10px] text-white/50">
          Trading balance
          <div className="text-sm font-mono text-white/95 mt-0.5">—</div>
        </div>
      </div>

      <div className="grid" style={{ gridTemplateColumns: "1fr 90px 300px" }}>
        <div className="p-4 border-r border-border-faint">
          <div className="flex justify-between items-start mb-3">
            <div>
              <div className="text-2xl font-bold">
                {live.spot !== null ? `$${live.spot.toLocaleString(undefined, { maximumFractionDigits: 0 })}` : "—"}
              </div>
              <div className="text-[10px] text-white/35 mt-0.5">BTC spot · 24h</div>
            </div>
            <div className="text-right">
              <div className="text-[9px] uppercase tracking-widest text-white/35 font-semibold">Settles in</div>
              <div className="text-sm font-semibold text-gold font-mono mt-0.5">
                <Countdown targetMs={oracle.expiry} resolution="second" />
              </div>
              <div className="text-[10px] text-white/30 mt-0.5">
                {new Date(oracle.expiry).toISOString().slice(0, 16).replace("T", " ")} UTC
              </div>
            </div>
          </div>
          <HeroChart series={[]} strike={strike} />
        </div>
        <StrikeWheel
          centerStrike={strike ?? Math.round(live.spot ?? oracle.min_strike)}
          minStrike={oracle.min_strike}
          maxStrike={oracle.min_strike + 100_000 * oracle.tick_size}
          tickSize={oracle.tick_size}
          onChange={setStrike}
          height={440}
        />
        <QuoteRail
          strike={strike}
          upPrice={askUp}
          downPrice={askDown}
          spreadBps={spreadBps}
          onBuy={onBuy}
          busy={busy}
        />
      </div>

      {digest && (
        <div className="px-5 py-3 text-[11px] text-green font-mono">
          ✓ Tx submitted: {digest}
        </div>
      )}
    </main>
  );
}
```

Note: the placeholder `managerId` lookup from `sessionStorage` is temporary — Task 5.8 provisions it.

- [ ] **Step 2:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/app/trade/page.tsx
git commit -m "feat(lighthouse): wire trade page end-to-end with live pricing"
```

### Task 5.8: Auto-provision PredictManager on first load

**Files:**
- Create: `apps/lighthouse/lib/sui/manager.ts`
- Modify: `apps/lighthouse/app/trade/page.tsx`

- [ ] **Step 1:** Write `lib/sui/manager.ts` — lookup-or-create a `PredictManager` for the user.

```ts
import { getSuiClient } from "./client";
import { publicConfig } from "@/lib/config";
import { buildCreateManager } from "./ptb";
import { executeSponsored } from "./execute";

const LS_KEY = "lighthouse.managerId";

export async function getOrCreateManager(userAddress: string): Promise<string> {
  if (typeof window !== "undefined") {
    const cached = window.sessionStorage.getItem(LS_KEY);
    if (cached) return cached;
  }
  const client = getSuiClient();
  const { predictPackageId } = publicConfig();
  const objs = await client.getOwnedObjects({
    owner: userAddress,
    filter: { StructType: `${predictPackageId}::predict_manager::PredictManager` },
    options: { showType: true },
  });
  if (objs.data[0]?.data?.objectId) {
    const id = objs.data[0].data.objectId;
    window.sessionStorage.setItem(LS_KEY, id);
    return id;
  }
  const tx = buildCreateManager();
  await executeSponsored(tx);
  const objs2 = await client.getOwnedObjects({
    owner: userAddress,
    filter: { StructType: `${predictPackageId}::predict_manager::PredictManager` },
    options: { showType: true },
  });
  const id = objs2.data[0]?.data?.objectId;
  if (!id) throw new Error("manager creation did not produce an object");
  window.sessionStorage.setItem(LS_KEY, id);
  return id;
}
```

- [ ] **Step 2:** In `app/trade/page.tsx`, call `getOrCreateManager` on mount and store the result.

```tsx
// Add imports
import { getOrCreateManager } from "@/lib/sui/manager";

// Inside TradePage, after loadSession check:
const [managerId, setManagerId] = useState<string | null>(null);
useEffect(() => {
  const s = loadSession();
  if (!s) return;
  getOrCreateManager(s.userAddress).then(setManagerId).catch(console.error);
}, []);

// Update onBuy to use the state instead of reading from sessionStorage:
const managerIdNow = managerId;
if (!managerIdNow) return;
// ...use managerIdNow in buildMintPosition
```

- [ ] **Step 3:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/lib/sui/manager.ts apps/lighthouse/app/trade/page.tsx
git commit -m "feat(lighthouse): auto-provision PredictManager on first trade page load"
```

### Task 5.9: Gate — live trade view on testnet

- [ ] **Step 1:** Boot dev server.

```bash
cd apps/lighthouse && pnpm dev
```

- [ ] **Step 2:** Manual check in browser: open http://localhost:3200, sign in with Google, verify:
  - Top nav shows Lighthouse + tabs + address pill
  - `/trade` loads, ExpiryChips populate from `predictServer.oracles()`
  - Selecting an expiry subscribes to oracle events (watch DevTools Network / console)
  - UP/DOWN prices show non-zero numbers
  - Strike wheel scrolls with mousewheel; center strike updates the highlighted strike in QuoteRail
  - "Buy UP" button fires a tx and returns a digest

If any step fails, consult:
- Sui testnet fullnode is reachable at `NEXT_PUBLIC_SUI_RPC_URL`
- `predict-server.testnet.mystenlabs.com/oracles` returns a non-empty array (if not, redeploy per `scripts/transactions/predict/redeploy.ts`)
- zkLogin prover is up: `curl https://prover-dev.mystenlabs.com/v1/ping`
- Sponsor wallet has SUI balance

Checkpoint 5 done. Proceed to Checkpoint 6.

---

## Checkpoint 6 — Positions table + lifecycle states

**Gate at end:** Positions table renders under the trade view with open/awaiting/settled rows; Sell and Redeem actions submit real txs; status pill + timer + quote rail adapt when the selected expiry is in Awaiting or Settled state.

### Task 6.1: `PositionsTable` component

**Files:**
- Create: `apps/lighthouse/components/trade/PositionsTable.tsx`

- [ ] **Step 1:** Write the table.

```tsx
"use client";
import useSWR from "swr";
import { predictServer, type PositionRow } from "@/lib/api/predict-server";
import { formatUsd, formatCountdownCoarse } from "@/lib/formatters";

type Tab = "all" | "open" | "redeem" | "history";

interface Props {
  managerId: string | null;
  onSell: (row: PositionRow) => void;
  onRedeem: (row: PositionRow) => void;
}

export function PositionsTable({ managerId, onSell, onRedeem }: Props) {
  const { data: rows } = useSWR<PositionRow[]>(
    managerId ? `/managers/${managerId}/positions` : null,
    () => predictServer.managerPositions(managerId!),
    { refreshInterval: 5000 },
  );

  if (!managerId) return <div className="p-5 text-white/40 text-sm">Connect a session to see positions.</div>;
  if (!rows) return <div className="p-5 text-white/40 text-sm">Loading positions…</div>;
  if (rows.length === 0) return <div className="p-5 text-white/40 text-sm">No positions yet.</div>;

  return (
    <div className="border-t border-border-faint">
      <div className="flex justify-between items-center px-5 py-4 border-b border-border-faint">
        <div className="flex gap-3 items-center">
          <h3 className="text-sm font-bold tracking-wide">Your positions</h3>
          <span className="text-[10px] px-2 py-0.5 rounded-full bg-white/6 text-white/60 font-semibold">
            {rows.length} {rows.length === 1 ? "position" : "positions"}
          </span>
        </div>
      </div>
      <table className="w-full">
        <thead>
          <tr className="text-[9px] uppercase tracking-wider text-white/40 font-semibold">
            <th className="text-left px-3 py-2.5 pl-5">Expiry</th>
            <th className="text-left px-3 py-2.5">Strike · Side</th>
            <th className="text-right px-3 py-2.5">Qty</th>
            <th className="text-right px-3 py-2.5">Cost</th>
            <th className="text-right px-3 py-2.5">Status</th>
            <th className="text-right px-3 py-2.5 pr-5"></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => {
            const now = Date.now();
            const expired = r.expiry < now;
            const state: Tab = !expired ? "open" : "redeem";
            return (
              <tr key={i} className="border-b border-white/4 text-xs hover:bg-white/1.5">
                <td className="px-3 py-3.5 pl-5">
                  <div className="font-semibold">{new Date(r.expiry).toUTCString().slice(5, 11)}</div>
                  <div className="text-[10px] text-white/35 font-mono">{formatCountdownCoarse(r.expiry - now)}</div>
                </td>
                <td className="px-3 py-3.5">
                  <span className="font-mono font-semibold text-white/90">${r.strike.toLocaleString()}</span>
                  <span
                    className={`ml-2 text-[10px] font-bold tracking-wide px-1.5 py-0.5 rounded ${
                      r.is_up ? "bg-green-bg text-green" : "bg-red-bg text-red"
                    }`}
                  >
                    {r.is_up ? "UP" : "DOWN"}
                  </span>
                </td>
                <td className="px-3 py-3.5 text-right font-mono">{r.quantity}</td>
                <td className="px-3 py-3.5 text-right font-mono">{formatUsd(r.cost_basis)}</td>
                <td className="px-3 py-3.5 text-right">
                  <span
                    className={`text-[10px] uppercase tracking-wider font-bold px-2 py-0.5 rounded ${
                      state === "open" ? "bg-green-bg text-green" : "bg-lavender-bg text-lavender"
                    }`}
                  >
                    {state === "open" ? "Active" : "To redeem"}
                  </span>
                </td>
                <td className="px-3 py-3.5 pr-5 text-right">
                  {state === "open" ? (
                    <button
                      onClick={() => onSell(r)}
                      className="text-[11px] font-bold px-3 py-1.5 rounded bg-white/6 border border-white/8 text-white/85"
                    >
                      Sell
                    </button>
                  ) : (
                    <button
                      onClick={() => onRedeem(r)}
                      className="text-[11px] font-bold px-3 py-1.5 rounded text-black"
                      style={{ background: "rgba(170,180,240,0.95)" }}
                    >
                      Redeem
                    </button>
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
```

- [ ] **Step 2:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/components/trade/PositionsTable.tsx
git commit -m "feat(lighthouse): PositionsTable component"
```

### Task 6.2: Wire PositionsTable into TradePage + implement Sell/Redeem

**Files:**
- Modify: `apps/lighthouse/app/trade/page.tsx`

- [ ] **Step 1:** Import and render the table.

```tsx
// Add imports at top
import { PositionsTable } from "@/components/trade/PositionsTable";
import { buildRedeemPosition } from "@/lib/sui/ptb";
import type { PositionRow } from "@/lib/api/predict-server";

// Inside TradePage, add handlers:
async function onSellOrRedeem(row: PositionRow) {
  if (!managerId) return;
  setBusy(true);
  try {
    const tx = buildRedeemPosition({
      predictId: publicConfig().predictId,
      managerId,
      oracleId: row.oracle_id,
      expiryMs: BigInt(row.expiry),
      strike: BigInt(row.strike * 1_000_000),
      isUp: row.is_up,
      quantity: BigInt(row.quantity),
    });
    const res = await executeSponsored(tx);
    setDigest(res.digest);
  } catch (e) {
    alert(`Redeem failed: ${(e as Error).message}`);
  } finally {
    setBusy(false);
  }
}

// Add below the three-column grid, inside <main>:
<PositionsTable managerId={managerId} onSell={onSellOrRedeem} onRedeem={onSellOrRedeem} />
```

- [ ] **Step 2:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/app/trade/page.tsx
git commit -m "feat(lighthouse): render positions table with Sell/Redeem"
```

### Task 6.3: `LifecycleBanner` — awaiting + settled variants

**Files:**
- Create: `apps/lighthouse/components/trade/LifecycleBanner.tsx`
- Modify: `apps/lighthouse/app/trade/page.tsx`

- [ ] **Step 1:** Write the banner.

```tsx
interface Props {
  kind: "awaiting" | "settled";
  settlementPrice?: number | null;
  strike: number;
  onTradeNext?: () => void;
}

export function LifecycleBanner({ kind, settlementPrice, strike, onTradeNext }: Props) {
  if (kind === "awaiting") {
    return (
      <div className="mx-5 my-3 px-4 py-3.5 rounded-lg border border-amber/30 bg-amber/10">
        <div className="text-[11px] font-bold text-amber uppercase tracking-wider">Waiting for settlement price</div>
        <p className="text-[11px] text-white/70 mt-1 leading-snug">
          The oracle will push the final BTC settlement price shortly. Trading is disabled for this expiry until it resolves.
          Your open positions remain safe.
        </p>
        {onTradeNext && (
          <button onClick={onTradeNext} className="mt-2 text-[11px] text-amber font-semibold hover:underline">
            Trade the next expiry →
          </button>
        )}
      </div>
    );
  }
  const won = settlementPrice !== null && settlementPrice !== undefined && settlementPrice > strike;
  return (
    <div className="mx-5 my-3 px-4 py-3.5 rounded-lg border border-lavender/30 bg-lavender/10">
      <div className="text-[11px] font-bold text-lavender uppercase tracking-wider">Settled</div>
      <p className="text-[11px] text-white/80 mt-1 leading-snug font-mono">
        Final BTC ${settlementPrice?.toLocaleString() ?? "—"} {won ? ">" : "≤"} strike ${strike.toLocaleString()} → {won ? "UP won" : "DOWN won"}.
      </p>
      {onTradeNext && (
        <button onClick={onTradeNext} className="mt-2 text-[11px] text-lavender font-semibold hover:underline">
          Trade the next expiry →
        </button>
      )}
    </div>
  );
}
```

- [ ] **Step 2:** In `app/trade/page.tsx`, render LifecycleBanner based on oracle state, and disable the `Buy` CTA when not active.

```tsx
import { LifecycleBanner } from "@/components/trade/LifecycleBanner";

// Derive lifecycle:
const lifecycle = oracle.settled_at
  ? "settled"
  : oracle.expiry < Date.now()
  ? "awaiting"
  : "active";

// In the JSX between the top bar and the grid:
{lifecycle !== "active" && strike !== null && (
  <LifecycleBanner
    kind={lifecycle}
    settlementPrice={oracle.settlement_price}
    strike={strike}
    onTradeNext={() => {
      const next = active.find((o) => o.oracle_id !== oracle.oracle_id && !o.settled_at && o.expiry > Date.now());
      if (next) setOracleId(next.oracle_id);
    }}
  />
)}

// Pass `disabled={lifecycle !== "active"}` through to QuoteRail via its `busy` prop.
```

- [ ] **Step 3:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/components/trade/LifecycleBanner.tsx apps/lighthouse/app/trade/page.tsx
git commit -m "feat(lighthouse): lifecycle banners for awaiting/settled states"
```

Checkpoint 6 done. Proceed to Checkpoint 7.

---

## Checkpoint 7 — Vault page

**Gate at end:** `/vault` renders hero stats, performance chart, metrics grid, composition bar, Supply/Withdraw rail. Supply and Withdraw actions submit real txs.

### Task 7.1: Vault data hooks

**Files:**
- Create: `apps/lighthouse/lib/api/vault.ts`

- [ ] **Step 1:** Extend the predict-server client with vault endpoints. **Note:** `/vault/metrics` and `/vault/performance` may not yet exist in `crates/predict-server` — if missing, this task includes adding them server-side (in a separate crate PR) OR fall back to deriving from on-chain reads. For MVP, we derive on-chain.

```ts
import { getSuiClient } from "@/lib/sui/client";
import { publicConfig } from "@/lib/config";

export interface VaultMetrics {
  tvlUsd: number;
  plpPriceUsd: number;
  utilizationPct: number;
  availableLiquidityUsd: number;
  openExposureUsd: number;
  fees7dUsd: number;
  yourPlpBalance: number;
}

export async function readVaultMetrics(userAddress: string): Promise<VaultMetrics> {
  const client = getSuiClient();
  const { predictPackageId, predictId } = publicConfig();

  const predict = await client.getObject({
    id: predictId,
    options: { showContent: true, showType: true },
  });
  const fields = (predict.data?.content as any)?.fields ?? {};
  const vault = fields?.vault?.fields ?? {};
  const vaultValue = Number(vault?.vault_value ?? 0) / 1_000_000;
  const totalMaxPayout = Number(vault?.total_max_payout ?? 0) / 1_000_000;
  const balance = Number(vault?.balance ?? 0) / 1_000_000;
  const totalSupply = Number(fields?.treasury_cap?.fields?.total_supply?.fields?.value ?? 0) / 1_000_000;
  const utilizationPct = vaultValue > 0 ? (totalMaxPayout / vaultValue) * 100 : 0;

  // PLP coin balance of the user
  let yourPlpBalance = 0;
  try {
    const plpType = `${predictPackageId}::predict::PLP`;
    const coins = await client.getCoins({ owner: userAddress, coinType: plpType });
    yourPlpBalance = coins.data.reduce((sum, c) => sum + Number(c.balance), 0) / 1_000_000;
  } catch {}

  return {
    tvlUsd: vaultValue,
    plpPriceUsd: totalSupply > 0 ? vaultValue / totalSupply : 1,
    utilizationPct,
    availableLiquidityUsd: balance > totalMaxPayout ? balance - totalMaxPayout : 0,
    openExposureUsd: totalMaxPayout,
    fees7dUsd: 0,          // needs a historical aggregator; leave 0 until server supports it
    yourPlpBalance,
  };
}
```

- [ ] **Step 2:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/lib/api/vault.ts
git commit -m "feat(lighthouse): derive vault metrics from on-chain reads"
```

### Task 7.2: Vault page layout components

**Files:**
- Create: `apps/lighthouse/components/vault/VaultHero.tsx`
- Create: `apps/lighthouse/components/vault/MetricsGrid.tsx`
- Create: `apps/lighthouse/components/vault/CompositionBar.tsx`
- Create: `apps/lighthouse/components/vault/PerformanceChart.tsx`

- [ ] **Step 1:** Write `VaultHero.tsx`.

```tsx
import { formatUsdCompact } from "@/lib/formatters";
import type { VaultMetrics } from "@/lib/api/vault";

export function VaultHero({ m }: { m: VaultMetrics }) {
  const yourUsd = m.yourPlpBalance * m.plpPriceUsd;
  return (
    <div className="px-6 py-5 grid border-b border-border-faint items-end gap-5" style={{ gridTemplateColumns: "1fr 1fr 1fr 1fr" }}>
      <div>
        <h1 className="text-xl font-bold">PLP Vault</h1>
        <div className="text-xs text-white/45 mt-1">Predict Liquidity Provider · underwrites every market</div>
      </div>
      <Stat label="TVL" value={formatUsdCompact(m.tvlUsd)} />
      <Stat label="PLP value" value={`$${m.plpPriceUsd.toFixed(4)}`} />
      <Stat label="Your position" value={`${m.yourPlpBalance.toFixed(2)} PLP`} sub={`≈ ${formatUsdCompact(yourUsd)}`} gold />
    </div>
  );
}

function Stat({ label, value, sub, gold }: { label: string; value: string; sub?: string; gold?: boolean }) {
  return (
    <div className="flex flex-col gap-1">
      <span className="text-[10px] text-white/40 uppercase tracking-wider font-semibold">{label}</span>
      <span className={`text-xl font-bold font-mono ${gold ? "text-gold" : ""}`}>{value}</span>
      {sub && <span className="text-[11px] text-white/45 font-medium">{sub}</span>}
    </div>
  );
}
```

- [ ] **Step 2:** Write `MetricsGrid.tsx`.

```tsx
import { formatUsdCompact } from "@/lib/formatters";
import type { VaultMetrics } from "@/lib/api/vault";

export function MetricsGrid({ m }: { m: VaultMetrics }) {
  return (
    <div className="grid gap-2.5" style={{ gridTemplateColumns: "1fr 1fr 1fr 1fr" }}>
      <Card label="Utilization" value={`${m.utilizationPct.toFixed(1)}%`} bar={m.utilizationPct} />
      <Card label="Available liquidity" value={formatUsdCompact(m.availableLiquidityUsd)} sub="Withdrawable now" />
      <Card label="Open exposure" value={formatUsdCompact(m.openExposureUsd)} sub="Net directional" />
      <Card label="Fees · 7d" value={formatUsdCompact(m.fees7dUsd)} sub="Spread revenue" />
    </div>
  );
}

function Card({ label, value, sub, bar }: { label: string; value: string; sub?: string; bar?: number }) {
  return (
    <div className="px-4 py-3.5 bg-bg-surface border border-border-faint rounded-lg">
      <div className="text-[10px] text-white/40 uppercase tracking-wider font-semibold">{label}</div>
      <div className="text-base font-bold font-mono mt-1">{value}</div>
      {sub && <div className="text-[10px] text-white/35 mt-0.5">{sub}</div>}
      {bar !== undefined && (
        <div className="h-1 bg-white/6 rounded mt-2 overflow-hidden">
          <div className="h-full" style={{ width: `${bar}%`, background: "rgba(220,180,50,0.8)" }} />
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 3:** Write `CompositionBar.tsx`.

```tsx
import type { VaultMetrics } from "@/lib/api/vault";

/**
 * Simplified composition: Available (cash) / Locked (max payout exposure) / PnL buffer.
 * These are derived from the three numbers we already have in VaultMetrics.
 */
export function CompositionBar({ m }: { m: VaultMetrics }) {
  const total = Math.max(m.tvlUsd, 1);
  const availablePct = (m.availableLiquidityUsd / total) * 100;
  const lockedPct = (m.openExposureUsd / total) * 100;
  const bufferPct = Math.max(0, 100 - availablePct - lockedPct);
  return (
    <div className="px-5 py-4 bg-bg-surface border border-border-faint rounded-lg flex gap-3 items-center">
      <span className="text-[10px] uppercase tracking-wider text-white/40 font-semibold shrink-0">Composition</span>
      <div className="flex flex-1 gap-0.5 h-2 rounded overflow-hidden">
        <div style={{ width: `${availablePct}%`, background: "rgba(60,200,120,0.85)" }} />
        <div style={{ width: `${lockedPct}%`, background: "rgba(220,180,50,0.85)" }} />
        <div style={{ width: `${bufferPct}%`, background: "rgba(240,100,100,0.8)" }} />
      </div>
      <div className="flex gap-3.5 text-[11px]">
        <Legend color="rgba(60,200,120,0.85)" label="Available" pct={availablePct} />
        <Legend color="rgba(220,180,50,0.85)" label="Locked" pct={lockedPct} />
        <Legend color="rgba(240,100,100,0.8)" label="Buffer" pct={bufferPct} />
      </div>
    </div>
  );
}

function Legend({ color, label, pct }: { color: string; label: string; pct: number }) {
  return (
    <span className="flex items-center gap-1.5 text-white/70">
      <span className="w-2 h-2 rounded-sm" style={{ background: color }} />
      {label} {pct.toFixed(0)}%
    </span>
  );
}
```

- [ ] **Step 4:** Write `PerformanceChart.tsx` — stub for now (historical data requires indexer changes; render a flat placeholder).

```tsx
"use client";
import { useEffect, useRef } from "react";
import { createChart, ColorType } from "lightweight-charts";

export function PerformanceChart({ height = 220 }: { height?: number }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!ref.current) return;
    const chart = createChart(ref.current, {
      height, autoSize: true,
      layout: { background: { type: ColorType.Solid, color: "transparent" }, textColor: "rgba(255,255,255,0.45)" },
      grid: { vertLines: { color: "rgba(255,255,255,0.04)" }, horzLines: { color: "rgba(255,255,255,0.04)" } },
      rightPriceScale: { borderVisible: false },
      timeScale: { borderVisible: false, timeVisible: false },
    });
    const area = chart.addAreaSeries({
      topColor: "rgba(60,200,120,0.25)",
      bottomColor: "rgba(60,200,120,0.02)",
      lineColor: "rgba(60,200,120,0.95)",
      lineWidth: 2,
    });
    // Placeholder: flat line until historical endpoint exists
    const now = Math.floor(Date.now() / 1000);
    const series = Array.from({ length: 30 }, (_, i) => ({
      time: (now - (29 - i) * 86400) as any,
      value: 1 + i * 0.001,
    }));
    area.setData(series);
    return () => chart.remove();
  }, [height]);
  return <div ref={ref} style={{ height }} />;
}
```

- [ ] **Step 5:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/components/vault
git commit -m "feat(lighthouse): vault hero/metrics/composition/performance components"
```

### Task 7.3: `ProvideLiquidityRail`

**Files:**
- Create: `apps/lighthouse/components/vault/ProvideLiquidityRail.tsx`

- [ ] **Step 1:** Write the rail.

```tsx
"use client";
import { useState } from "react";
import { formatUsd } from "@/lib/formatters";
import type { VaultMetrics } from "@/lib/api/vault";

type Mode = "supply" | "withdraw";

export function ProvideLiquidityRail({
  m,
  walletUsdsuiBalance,
  onSupply,
  onWithdraw,
  busy,
}: {
  m: VaultMetrics;
  walletUsdsuiBalance: number;
  onSupply: (amountUsd: number) => void;
  onWithdraw: (amountPlp: number) => void;
  busy?: boolean;
}) {
  const [mode, setMode] = useState<Mode>("supply");
  const [amount, setAmount] = useState(500);
  const plpOut = mode === "supply" ? amount / m.plpPriceUsd : 0;
  const usdOut = mode === "withdraw" ? amount * m.plpPriceUsd : 0;
  const maxIn = mode === "supply" ? walletUsdsuiBalance : m.yourPlpBalance;

  return (
    <aside className="bg-bg-rail flex flex-col">
      <div className="flex justify-between items-center px-4 py-3.5 border-b border-border-faint">
        <div className="text-[11px] uppercase tracking-wider text-white/50 font-semibold">Provide liquidity</div>
        <div className="flex rounded-md overflow-hidden border border-border-subtle">
          <button onClick={() => setMode("supply")} className={`px-3 py-1 text-[10px] font-semibold ${mode === "supply" ? "bg-green-bg text-green" : "text-white/40"}`}>Supply</button>
          <button onClick={() => setMode("withdraw")} className={`px-3 py-1 text-[10px] font-semibold ${mode === "withdraw" ? "bg-amber-bg text-amber" : "text-white/40"}`}>Withdraw</button>
        </div>
      </div>
      <div className="p-4 flex flex-col gap-3.5">
        <div className="px-4 py-3.5 rounded-lg bg-white/2 border border-border-faint">
          <div className="flex justify-between items-baseline">
            <input
              type="number"
              value={amount}
              onChange={(e) => setAmount(Number(e.target.value))}
              className="bg-transparent text-2xl font-bold font-mono outline-none w-full"
            />
            <span className="text-[11px] text-white/40">{mode === "supply" ? "USDsui" : "PLP"}</span>
          </div>
          <div className="text-[11px] text-white/40 mt-1">Max: {maxIn.toFixed(2)}</div>
          <div className="grid grid-cols-4 gap-1 mt-2">
            {[0.25, 0.5, 0.75, 1].map((f) => (
              <button key={f} onClick={() => setAmount(Number((maxIn * f).toFixed(2)))} className="py-1.5 text-[11px] rounded bg-white/4 text-white/60">
                {f === 1 ? "Max" : `${f * 100}%`}
              </button>
            ))}
          </div>
        </div>
        <div className="flex justify-center"><span className="text-white/30">↓</span></div>
        <div className="px-4 py-3.5 rounded-lg border border-gold-border bg-gold-bg/60">
          <div className="text-[10px] uppercase tracking-wider text-gold-dim font-semibold">You receive</div>
          <div className="text-lg font-bold font-mono text-gold mt-1">
            {mode === "supply" ? `${plpOut.toFixed(2)} PLP` : formatUsd(usdOut)}
          </div>
          <div className="text-[10px] text-white/40 mt-0.5">at ${m.plpPriceUsd.toFixed(4)} per share</div>
        </div>
        <button
          disabled={busy || amount <= 0}
          onClick={() => (mode === "supply" ? onSupply(amount) : onWithdraw(amount))}
          className="py-3.5 rounded-lg font-bold text-sm text-black disabled:opacity-50"
          style={{ background: mode === "supply" ? "rgba(60,200,120,0.9)" : "rgba(240,180,80,0.9)" }}
        >
          {busy ? "Submitting…" : mode === "supply" ? `Supply ${formatUsd(amount)}` : `Withdraw ${amount.toFixed(2)} PLP`}
        </button>
      </div>
    </aside>
  );
}
```

- [ ] **Step 2:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/components/vault/ProvideLiquidityRail.tsx
git commit -m "feat(lighthouse): ProvideLiquidityRail supply/withdraw UI"
```

### Task 7.4: Wire Vault page

**Files:**
- Modify: `apps/lighthouse/app/vault/page.tsx`

- [ ] **Step 1:** Replace placeholder with real page.

```tsx
"use client";
import useSWR from "swr";
import { useState } from "react";
import { readVaultMetrics } from "@/lib/api/vault";
import { loadSession } from "@/lib/zklogin/session";
import { VaultHero } from "@/components/vault/VaultHero";
import { MetricsGrid } from "@/components/vault/MetricsGrid";
import { CompositionBar } from "@/components/vault/CompositionBar";
import { PerformanceChart } from "@/components/vault/PerformanceChart";
import { ProvideLiquidityRail } from "@/components/vault/ProvideLiquidityRail";
import { buildSupplyPlp, buildWithdrawPlp } from "@/lib/sui/ptb";
import { executeSponsored } from "@/lib/sui/execute";
import { publicConfig } from "@/lib/config";
import { getSuiClient } from "@/lib/sui/client";

export default function VaultPage() {
  const session = loadSession();
  const [busy, setBusy] = useState(false);
  const { data: m } = useSWR(
    session?.userAddress ? ["vault-metrics", session.userAddress] : null,
    () => readVaultMetrics(session!.userAddress),
    { refreshInterval: 10_000 },
  );
  const { data: walletBal } = useSWR(
    session?.userAddress ? ["wallet-usdsui", session.userAddress] : null,
    async () => {
      const client = getSuiClient();
      const coins = await client.getCoins({
        owner: session!.userAddress,
        coinType: publicConfig().usdsuiType,
      });
      return coins.data.reduce((s, c) => s + Number(c.balance), 0) / 1_000_000;
    },
    { refreshInterval: 10_000 },
  );

  async function onSupply(usdAmount: number) {
    if (!session) return;
    setBusy(true);
    try {
      const client = getSuiClient();
      const coins = await client.getCoins({
        owner: session.userAddress,
        coinType: publicConfig().usdsuiType,
      });
      if (!coins.data[0]) throw new Error("no USDsui in wallet");
      const tx = buildSupplyPlp({
        predictId: publicConfig().predictId,
        amount: BigInt(Math.floor(usdAmount * 1_000_000)),
        walletCoinId: coins.data[0].coinObjectId,
      });
      await executeSponsored(tx);
    } finally { setBusy(false); }
  }

  async function onWithdraw(plpAmount: number) {
    if (!session) return;
    setBusy(true);
    try {
      const client = getSuiClient();
      const plpType = `${publicConfig().predictPackageId}::predict::PLP`;
      const plpCoins = await client.getCoins({ owner: session.userAddress, coinType: plpType });
      if (!plpCoins.data[0]) throw new Error("no PLP in wallet");
      const tx = buildWithdrawPlp({
        predictId: publicConfig().predictId,
        plpCoinId: plpCoins.data[0].coinObjectId,
        amount: BigInt(Math.floor(plpAmount * 1_000_000)),
      });
      await executeSponsored(tx);
    } finally { setBusy(false); }
  }

  if (!m) return <div className="p-6 text-white/50">Loading vault…</div>;
  return (
    <main>
      <VaultHero m={m} />
      <div className="grid" style={{ gridTemplateColumns: "1fr 320px" }}>
        <div className="p-6 border-r border-border-faint flex flex-col gap-5">
          <div className="bg-bg-surface border border-border-faint rounded-lg p-4">
            <div className="text-[11px] font-bold uppercase tracking-wider text-white/75 mb-3">Vault performance</div>
            <PerformanceChart />
          </div>
          <MetricsGrid m={m} />
          <CompositionBar m={m} />
        </div>
        <ProvideLiquidityRail
          m={m}
          walletUsdsuiBalance={walletBal ?? 0}
          onSupply={onSupply}
          onWithdraw={onWithdraw}
          busy={busy}
        />
      </div>
    </main>
  );
}
```

- [ ] **Step 2:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/app/vault/page.tsx
git commit -m "feat(lighthouse): wire vault page with supply/withdraw"
```

Checkpoint 7 done. Proceed to Checkpoint 8.

---

## Checkpoint 8 — Portfolio page

**Gate at end:** `/portfolio` renders account value, PnL chart, and Deposit/Withdraw transfer card that moves USDsui between wallet and PredictManager.

### Task 8.1: Portfolio page

**Files:**
- Modify: `apps/lighthouse/app/portfolio/page.tsx`
- Create: `apps/lighthouse/components/portfolio/AccountValueHeader.tsx`
- Create: `apps/lighthouse/components/portfolio/PnlChart.tsx`
- Create: `apps/lighthouse/components/portfolio/TransferCard.tsx`

- [ ] **Step 1:** Write `AccountValueHeader.tsx`.

```tsx
import { formatUsd, formatPct } from "@/lib/formatters";

export function AccountValueHeader({
  totalValue,
  allTimeDelta,
}: {
  totalValue: number;
  allTimeDelta: number;
}) {
  const pct = totalValue - allTimeDelta !== 0 ? allTimeDelta / (totalValue - allTimeDelta) : 0;
  const pos = allTimeDelta >= 0;
  return (
    <div>
      <div className="text-[11px] text-white/45 uppercase tracking-wider font-semibold">Account value</div>
      <div className="text-4xl font-extrabold font-mono -tracking-[0.02em] mt-1.5 leading-none">
        {formatUsd(totalValue)}
      </div>
      <div className={`text-sm font-semibold mt-1.5 ${pos ? "text-green" : "text-red"}`}>
        {pos ? "+" : ""}{formatUsd(allTimeDelta)} ({formatPct(pct)}) · all-time
      </div>
    </div>
  );
}
```

- [ ] **Step 2:** Write `PnlChart.tsx` (placeholder series until the indexer has PnL history).

```tsx
"use client";
import { useEffect, useRef } from "react";
import { createChart, ColorType } from "lightweight-charts";

export function PnlChart({ height = 300 }: { height?: number }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!ref.current) return;
    const chart = createChart(ref.current, {
      height, autoSize: true,
      layout: { background: { type: ColorType.Solid, color: "transparent" }, textColor: "rgba(255,255,255,0.45)" },
      grid: { vertLines: { color: "rgba(255,255,255,0.04)" }, horzLines: { color: "rgba(255,255,255,0.04)" } },
      rightPriceScale: { borderVisible: false },
      timeScale: { borderVisible: false, timeVisible: false },
    });
    const area = chart.addAreaSeries({
      topColor: "rgba(60,200,120,0.25)",
      bottomColor: "rgba(60,200,120,0.01)",
      lineColor: "rgba(60,200,120,0.95)",
      lineWidth: 2,
    });
    const now = Math.floor(Date.now() / 1000);
    const series = Array.from({ length: 30 }, (_, i) => ({
      time: (now - (29 - i) * 86400) as any,
      value: i * 15 + Math.sin(i / 3) * 10,
    }));
    area.setData(series);
    return () => chart.remove();
  }, [height]);
  return <div ref={ref} style={{ height }} />;
}
```

- [ ] **Step 3:** Write `TransferCard.tsx`.

```tsx
"use client";
import { useState } from "react";
import { formatUsd } from "@/lib/formatters";

type Mode = "deposit" | "withdraw";

export function TransferCard({
  walletBalance,
  tradingBalance,
  onDeposit,
  onWithdraw,
  busy,
}: {
  walletBalance: number;
  tradingBalance: number;
  onDeposit: (amount: number) => void;
  onWithdraw: (amount: number) => void;
  busy?: boolean;
}) {
  const [mode, setMode] = useState<Mode>("deposit");
  const [amount, setAmount] = useState(250);
  const fromBal = mode === "deposit" ? walletBalance : tradingBalance;
  const toBalAfter = mode === "deposit" ? tradingBalance + amount : walletBalance + amount;

  return (
    <div className="bg-bg-surface border border-border-faint rounded-xl overflow-hidden">
      <div className="flex justify-between items-center px-4.5 py-3.5 border-b border-border-faint">
        <div className="text-[11px] font-bold uppercase tracking-wider text-white/65">Transfer</div>
        <div className="flex border border-border-subtle rounded-md overflow-hidden">
          <button onClick={() => setMode("deposit")} className={`px-3 py-1 text-[10px] font-semibold ${mode === "deposit" ? "bg-gold-bg text-gold" : "text-white/40"}`}>Deposit</button>
          <button onClick={() => setMode("withdraw")} className={`px-3 py-1 text-[10px] font-semibold ${mode === "withdraw" ? "bg-gold-bg text-gold" : "text-white/40"}`}>Withdraw</button>
        </div>
      </div>
      <div className="p-4.5 flex flex-col gap-3">
        <Lane top={mode === "deposit" ? "From · Wallet" : "From · Trading"} amount={amount} onAmount={setAmount} unit="USDsui" balance={fromBal} />
        <div className="flex justify-center -my-1"><span className="text-gold">↓</span></div>
        <Lane top={mode === "deposit" ? "To · Trading" : "To · Wallet"} amount={toBalAfter} unit="after" readOnly />
        <button
          disabled={busy || amount <= 0}
          onClick={() => (mode === "deposit" ? onDeposit(amount) : onWithdraw(amount))}
          className="py-3.5 rounded-lg font-bold text-sm text-black disabled:opacity-50"
          style={{ background: "rgba(220,180,50,0.9)" }}
        >
          {busy ? "Submitting…" : `${mode === "deposit" ? "Deposit" : "Withdraw"} ${formatUsd(amount)}`}
        </button>
      </div>
    </div>
  );
}

function Lane({
  top, amount, onAmount, unit, balance, readOnly,
}: {
  top: string; amount: number; onAmount?: (v: number) => void; unit: string; balance?: number; readOnly?: boolean;
}) {
  return (
    <div className="px-3.5 py-3.5 bg-white/2 border border-border-faint rounded-lg">
      <div className="text-[10px] text-white/40 uppercase tracking-wider font-semibold">{top}</div>
      <div className="flex justify-between items-baseline mt-1">
        {readOnly ? (
          <span className="text-xl font-bold font-mono">{formatUsd(amount)}</span>
        ) : (
          <input
            type="number"
            value={amount}
            onChange={(e) => onAmount?.(Number(e.target.value))}
            className="bg-transparent text-xl font-bold font-mono outline-none w-full"
          />
        )}
        <span className="text-[11px] text-white/40">{unit}</span>
      </div>
      {balance !== undefined && <div className="text-[11px] text-white/40 mt-1">Balance {formatUsd(balance)}</div>}
    </div>
  );
}
```

- [ ] **Step 4:** Write the page.

```tsx
"use client";
import useSWR from "swr";
import { useState } from "react";
import { loadSession } from "@/lib/zklogin/session";
import { AccountValueHeader } from "@/components/portfolio/AccountValueHeader";
import { PnlChart } from "@/components/portfolio/PnlChart";
import { TransferCard } from "@/components/portfolio/TransferCard";
import { getSuiClient } from "@/lib/sui/client";
import { publicConfig } from "@/lib/config";
import { buildDepositBalance, buildWithdrawBalance } from "@/lib/sui/ptb";
import { executeSponsored } from "@/lib/sui/execute";
import { getOrCreateManager } from "@/lib/sui/manager";
import { useEffect } from "react";

export default function PortfolioPage() {
  const session = loadSession();
  const [managerId, setManagerId] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!session) return;
    getOrCreateManager(session.userAddress).then(setManagerId).catch(console.error);
  }, [session?.userAddress]);

  const { data: walletBal } = useSWR(
    session?.userAddress ? ["wallet-usdsui", session.userAddress] : null,
    async () => {
      const client = getSuiClient();
      const coins = await client.getCoins({ owner: session!.userAddress, coinType: publicConfig().usdsuiType });
      return coins.data.reduce((s, c) => s + Number(c.balance), 0) / 1_000_000;
    },
    { refreshInterval: 5000 },
  );

  const { data: tradingBal } = useSWR(
    managerId ? ["manager-bal", managerId] : null,
    async () => {
      const client = getSuiClient();
      const obj = await client.getObject({ id: managerId!, options: { showContent: true } });
      const fields = (obj.data?.content as any)?.fields ?? {};
      const entries = fields?.balances?.fields?.contents ?? [];
      const usdsui = entries.find((e: any) => e.fields?.key === publicConfig().usdsuiType);
      return Number(usdsui?.fields?.value ?? 0) / 1_000_000;
    },
    { refreshInterval: 5000 },
  );

  async function onDeposit(amount: number) {
    if (!session || !managerId) return;
    setBusy(true);
    try {
      const client = getSuiClient();
      const coins = await client.getCoins({ owner: session.userAddress, coinType: publicConfig().usdsuiType });
      if (!coins.data[0]) throw new Error("no USDsui in wallet");
      const tx = buildDepositBalance({
        managerId,
        amount: BigInt(Math.floor(amount * 1_000_000)),
        walletCoinId: coins.data[0].coinObjectId,
      });
      await executeSponsored(tx);
    } finally { setBusy(false); }
  }

  async function onWithdraw(amount: number) {
    if (!managerId) return;
    setBusy(true);
    try {
      const tx = buildWithdrawBalance({
        managerId,
        amount: BigInt(Math.floor(amount * 1_000_000)),
      });
      await executeSponsored(tx);
    } finally { setBusy(false); }
  }

  const totalValue = (walletBal ?? 0) + (tradingBal ?? 0);
  const allTimeDelta = 0;  // needs PnL endpoint; stub

  return (
    <main className="p-8 grid gap-8 items-start" style={{ gridTemplateColumns: "1fr 340px" }}>
      <div className="grid gap-6" style={{ gridTemplateRows: "auto 1fr" }}>
        <AccountValueHeader totalValue={totalValue} allTimeDelta={allTimeDelta} />
        <div className="bg-bg-surface border border-border-faint rounded-xl p-4">
          <div className="text-[11px] font-bold uppercase tracking-wider text-white/65 mb-3">PnL over time</div>
          <PnlChart />
        </div>
      </div>
      <div className="grid gap-6" style={{ gridTemplateRows: "auto 1fr" }}>
        <div>
          <div className="text-[11px] text-white/45 uppercase tracking-wider font-semibold">Trading balance</div>
          <div className="text-4xl font-extrabold font-mono -tracking-[0.02em] mt-1.5 leading-none">
            ${(tradingBal ?? 0).toFixed(2)}
          </div>
          <div className="text-sm text-white/45 mt-1.5">USDsui · available to trade</div>
        </div>
        <TransferCard
          walletBalance={walletBal ?? 0}
          tradingBalance={tradingBal ?? 0}
          onDeposit={onDeposit}
          onWithdraw={onWithdraw}
          busy={busy}
        />
      </div>
    </main>
  );
}
```

- [ ] **Step 5:** Typecheck + commit.

```bash
cd apps/lighthouse && pnpm typecheck
git add apps/lighthouse/app/portfolio apps/lighthouse/components/portfolio
git commit -m "feat(lighthouse): portfolio page with deposit/withdraw"
```

Checkpoint 8 done. Proceed to Checkpoint 9.

---

## Checkpoint 9 — Integration, e2e, deploy

**Gate at end:** Playwright smoke suite passes against a preview deploy; Vercel deploy URL is live; all four pages (signin, trade, vault, portfolio) exercised in CI.

### Task 9.1: Playwright setup

**Files:**
- Create: `apps/lighthouse/playwright.config.ts`
- Create: `apps/lighthouse/tests/e2e/smoke.spec.ts`

- [ ] **Step 1:** Install Playwright browsers.

```bash
cd apps/lighthouse && pnpm exec playwright install --with-deps chromium
```

- [ ] **Step 2:** Write `playwright.config.ts`.

```ts
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: true,
  retries: 1,
  reporter: [["list"]],
  use: {
    baseURL: process.env.LIGHTHOUSE_BASE_URL ?? "http://localhost:3200",
    trace: "retain-on-failure",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  webServer: process.env.LIGHTHOUSE_BASE_URL
    ? undefined
    : {
        command: "pnpm dev",
        port: 3200,
        reuseExistingServer: true,
      },
});
```

- [ ] **Step 3:** Write `tests/e2e/smoke.spec.ts` — signed-out smoke (no OAuth flow — that'd require real creds).

```ts
import { test, expect } from "@playwright/test";

test.describe("Lighthouse signed-out smoke", () => {
  test("root redirects to /trade and then to /signin", async ({ page }) => {
    await page.goto("/");
    await page.waitForURL(/\/signin$/);
    await expect(page.getByRole("heading", { name: /Welcome to Lighthouse/i })).toBeVisible();
  });

  test("signin page has Google button", async ({ page }) => {
    await page.goto("/signin");
    await expect(page.getByRole("button", { name: /Sign in with Google/i })).toBeVisible();
  });

  test("/trade redirects unauthenticated to /signin", async ({ page }) => {
    await page.goto("/trade");
    await page.waitForURL(/\/signin$/);
  });

  test("/vault redirects unauthenticated to /signin", async ({ page }) => {
    await page.goto("/vault");
    await page.waitForURL(/\/signin$/);
  });

  test("/portfolio redirects unauthenticated to /signin", async ({ page }) => {
    await page.goto("/portfolio");
    await page.waitForURL(/\/signin$/);
  });
});
```

- [ ] **Step 4:** Run e2e locally.

```bash
cd apps/lighthouse && pnpm e2e
```

Expected: 5 tests PASS.

- [ ] **Step 5:** Commit.

```bash
git add apps/lighthouse/playwright.config.ts apps/lighthouse/tests/e2e
git commit -m "test(lighthouse): Playwright signed-out smoke tests"
```

### Task 9.2: Vercel config

**Files:**
- Create: `apps/lighthouse/vercel.json`

- [ ] **Step 1:** Write `vercel.json`.

```json
{
  "buildCommand": "cd ../.. && pnpm install && pnpm --filter lighthouse build",
  "outputDirectory": ".next",
  "framework": "nextjs",
  "regions": ["iad1"]
}
```

- [ ] **Step 2:** Commit.

```bash
git add apps/lighthouse/vercel.json
git commit -m "chore(lighthouse): vercel.json for monorepo deploys"
```

### Task 9.3: GitHub Actions CI workflow

**Files:**
- Create: `.github/workflows/lighthouse-ci.yml`

- [ ] **Step 1:** Write the workflow.

```yaml
name: lighthouse-ci
on:
  pull_request:
    paths:
      - "apps/lighthouse/**"
      - "pnpm-workspace.yaml"
      - ".github/workflows/lighthouse-ci.yml"
  push:
    branches: [main]
    paths:
      - "apps/lighthouse/**"

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
        with:
          version: 9
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: "pnpm"
      - run: pnpm install --frozen-lockfile
      - run: pnpm --filter lighthouse typecheck
      - run: pnpm --filter lighthouse test
      - run: pnpm --filter lighthouse build
      - run: pnpm --filter lighthouse exec playwright install --with-deps chromium
      - run: pnpm --filter lighthouse e2e
```

- [ ] **Step 2:** Commit.

```bash
git add .github/workflows/lighthouse-ci.yml
git commit -m "ci(lighthouse): add GitHub Actions workflow"
```

### Task 9.4: Final gate — deploy + verify

- [ ] **Step 1:** Push branch, open PR.

```bash
git push -u origin predict-testnet-4-16
gh pr create --title "feat(lighthouse): initial testnet frontend" --body "Implements docs/superpowers/specs/2026-04-16-lighthouse-frontend-design.md."
```

- [ ] **Step 2:** In Vercel dashboard, import the repo, set the Root Directory to `apps/lighthouse`, and add env vars from `.env.example` (including the server-side ones: `SPONSOR_WALLET_PRIVATE_KEY`, `UPSTASH_REDIS_URL/TOKEN`, `FAUCET_ADMIN_KEY`, `USDSUI_TREASURY_CAP_ID`).

- [ ] **Step 3:** Watch the preview deploy URL and exercise the success-criteria checklist from §12 of the spec:

  - [ ] Sign in with Google as a brand-new testnet user
  - [ ] Auto-faucet mints 10,000 USDsui to the wallet
  - [ ] Deposit $1,000 USDsui to trading
  - [ ] Buy an UP position on the nearest expiry
  - [ ] See it in the positions table with live MTM
  - [ ] Sell it (or wait for settlement + redeem)
  - [ ] Switch to `/vault`, supply $100 USDsui, see PLP balance grow
  - [ ] Withdraw some PLP
  - [ ] Verify PnL chart and account value update on `/portfolio`
  - [ ] All three lifecycle states (Active / Awaiting / Settled) visible on at least one expiry
  - [ ] Quote ring ticks visibly; UP/DOWN prices shift as oracle pushes SVI updates

- [ ] **Step 4:** On success, merge the PR. On failure, file sub-issues per broken item and iterate.

Checkpoint 9 done. Plan complete.

---

## Notes for the implementer

- **Checkpoint skipping**: Each checkpoint is independently testable. If you hit a blocker in C5 (e.g., prover is down), continue to C6/C7/C8 using mock data.
- **Spec Question mapping**: The six open questions in spec §13 surface during implementation. Track them as separate issues.
- **Naming drift**: if any imported symbol name diverges between checkpoints (e.g., `@mysten/sui` API churn), prefer updating all call sites to the latest SDK rather than pinning.
- **zkLogin caveat**: the OAuth "client ID" registered at Google must list your exact Vercel preview URL + localhost as authorized redirect URIs. Wildcards don't work.
- **Sponsor wallet drainage**: the sponsor wallet funding test users' gas is a real attack surface on testnet. Add a per-IP or per-address rate limit to `/api/tx/sponsor/*` before publishing the URL to the waitlist. (Out of scope for this plan; file follow-up.)

