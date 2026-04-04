## Strike Matrix Optimization Diary

### 2026-04-03

- Baseline observations before this pass:
  - `PAGE_SLOTS = 256` gave about `182.5M` avg mint gas in the batched sim run `apr03-1537`.
  - `PAGE_SLOTS = 64` was much worse, around `307.8M` avg mint gas in `apr03-1546`.
  - `PAGE_SLOTS = 512` looked best on net gas, around `81.4M` avg mint gas in `apr03-1559`, with a clear first-touch/new-page high band and a much cheaper existing-page rewrite band.
- First optimization pass goals:
  - shrink each page object without changing behavior
  - remove redundant vault max-payout bookkeeping
- Changes in this pass:
  - removed per-node `qk_up` / `qk_dn` storage and derive exact strike-weighted values from `(q, strike)` when needed
  - removed unused stored `StrikeMatrix.max_strike`
  - simplified `Vault.total_max_payout` updates to direct `+/- quantity` because matrix `max_payout()` is the conservative sum of live quantities
- Measured result after this pass:
  - fresh `PAGE_SLOTS = 512` run `apr03-1958-2` improved to about `74.7M` avg mint gas
  - compared to the earlier `512` run `apr03-1559` at about `81.4M`

### 2026-04-04

- Second optimization pass goals:
  - shrink page objects further without changing evaluator semantics
  - keep the best-performing page size only if it still wins after storage reductions
- Changes in this pass:
  - removed exact per-node `q_up` / `q_dn` storage and derive point quantities from neighboring prefix/suffix aggregates
  - cleaned helper signatures so the final test run is warning-free
- Measured result after this pass:
  - fresh `PAGE_SLOTS = 512` run `apr03-2007` improved again to about `70.9M` avg mint gas
  - p95 gas dropped sharply from about `226.2M` in `apr03-1958-2` to about `163.7M`
- Page-size follow-up:
  - tested `PAGE_SLOTS = 1024` in run `apr03-2016`
  - result regressed to about `72.6M` avg mint gas
  - storage cost jumped back up (`~271.6M`) while computation stayed flat (`~60.8M` vs `~60.3M`), so larger pages are not helping anymore
- Current best measured configuration:
  - `PAGE_SLOTS = 512`
  - no stored exact `q*` or exact `qk*` on nodes
  - conservative `max_payout = total_q_up + total_q_dn`
- Remaining credible improvements now look deeper than local field pruning:
  - reduce live `evaluate()` compute directly
  - or redesign page summaries / risk refresh
  - simple page-size or node-field tweaks appear close to exhausted

- Eager allocation experiment:
  - changed `StrikeMatrix::new` to pre-create every page in the oracle grid and removed lazy page creation from `insert`
  - full predict test suite still passed (`345/345`)
  - simulation setup then showed that `create_oracle` became very expensive
  - the default simulation setup gas budget and then `5_000_000_000` were insufficient for `create_oracle`
  - updated the simulation harness so only `create_oracle` can use a larger setup-only gas budget, leaving the measured mint path unchanged
  - with `50_000_000_000`, oracle creation at least proceeded far enough to continue the simulation setup
