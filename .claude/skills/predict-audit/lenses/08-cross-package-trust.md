# Lens 08 — Cross-Package Trust Boundaries

## STEP 0 — read shared context (required)
Read `../primer.md` in full first. Treat it as binding. If you cannot read it, stop and ask.

## Your lens
Cross-package trust boundaries. The oracle and custody layers were extracted out of `predict` into `propbook`,
`block_scholes_oracle`, and `account`. Each extraction created a SEAM: a place where `predict` (or `propbook`)
now **trusts** another package for something it used to own in-module. Your job: for every dependency edge,
state what the consumer trusts the producer for, whether that trust is validated at the boundary, and — the
central question — **whether the extraction silently DROPPED a validation the pre-split in-package code had.**
The split is only safe if it is behavior-preserving at every seam.

**Map each edge (consumer → producer): trust, enforcement, blast radius if violated.**

- **predict → propbook** (spot/forward/SVI + settlement). The pricing-safe envelope (forward>0, basis bounds,
  |rho|<=1, sigma band, freshness, pre-expiry gate) is **consumer-enforced in `predict::pricing`**, not in
  propbook — propbook stores raw operator fields. Verify predict enforces the FULL envelope on EVERY priced
  path (mint admission, redeem, liquidation trigger, NAV, settlement read); a feed read that skips it trusts raw
  data. Verify binding correctness: market ↔ underlying ↔ the specific spot/forward/svi feed objects ↔ expiry —
  can a caller pass a wrong-underlying or wrong-expiry feed object into a priced flow? Compare the pre-split
  in-package `market_oracle`/`pyth_source` checks against the post-split path and list anything not carried over.

- **predict → account** (DUSDC custody). Custody moved from the in-package manager into `account::Account`.
  Enumerate what auth/limits the old in-package custody enforced and confirm each is enforced across the new
  boundary: app-auth (`generate_auth_as_app<PredictApp>`) requires a `Permit<PredictApp>` (constructible only
  inside predict) AND registry authorization — confirm no keeper/anon path forges it; withdraw authority cannot
  exceed intent; `deauthorize_app` blast radius (which predict flows brick, is owner-redeem the guaranteed
  fallback); `account` has no version gate (confirm "custody not frozen by a predict version freeze" is the
  intended non-custodial property, not an exploitable escape hatch).

- **predict / propbook → block_scholes_oracle** (`update`). This module is a **stub**: BS update values are
  operator-supplied and NOT signature-verified (D031 trust model). Confirm the trust surface: exactly which
  cap/role can construct and push an update, that nothing outside the trusted operator can reach it, and that a
  malicious-but-authorized push is bounded only by the predict-side envelope (hand any envelope gap to lens 03).

- **propbook → pyth_lazer / wormhole** (signed spot). What is cryptographically verified upstream vs trusted in
  propbook; the published-at/original-id pinning in the manifests.

**Structural seam checks:**
- **Dependency direction & manifest style:** `account` and `block_scholes_oracle` are old-style manifests (have
  `[addresses]`); `predict`/`propbook` are new-style. Confirm the allowed direction (old-style depended-on by
  new-style is fine; old-style cannot depend on new-style) and that the single `block_scholes_oracle`/`token`/
  `pyth_lazer` package is resolved from ONE source across all consumers (a git-vs-local or rev mismatch makes
  two incompatible copies of the "same" package — a real, test-breaking failure mode here).
- **Version / upgrade compatibility across packages:** what struct/type/version assumption must hold across an
  upgrade of one package but not the others; whether a type defined in `account`/`block_scholes_oracle` and used
  by `predict` can drift.

## Output
For each seam: a trust row (consumer | producer | trusted-for | enforced-where | gap-if-any | blast-radius).
Call out every validation present pre-split but absent post-split as a finding. Emit in the primer's report
format with Evidence (the pre-split vs post-split code/grep/git diff). Top 3 = the seams most likely to leak.
Return structured findings to the orchestrator or write the solo report. Never modify source.
