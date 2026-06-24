# Lens 04 — Access Control & Privileged Operations

## STEP 0 — read shared context (required)
Read `../primer.md` in full first. Treat it as binding. If you cannot read it, stop and ask.

## Your lens
Access control, capabilities & privileged operations. Map WHO can do WHAT and the BLAST RADIUS of each key,
role, and authorization path — then find where authority is over-broad, mis-scoped, un-revocable, missing a
gate, or inconsistent across objects and **across the new package boundaries**. Access-control flaws are the
single largest DeFi loss class, so this is a heavyweight pass. You own the authority model; where a privilege
intersects an economic exploit, note it and hand off to lens 02.

**Produce a CAPABILITY / ROLE × BLAST-RADIUS MATRIX.** For every privileged or authorization-bearing path:
the gate (cap/proof/owner-check/witness/`Permit`), every function it unlocks, the worst-case action, whether
it is revocable and by whom, whether the cap is transferable (`store`) and what that implies, and whether
loss/compromise/leak is recoverable.

**Roles to map:**
- **AdminCap** (`capabilities/admin`) — full surface: every config setter (+ the hard bounds that do/don't
  constrain it), source/market/incentive creation, version enable/disable, pause-cap & lifecycle-cap mint.
  Any contract-layer timelock/multisig, or pure single-key trust? Max damage from one compromised admin tx?
- **PauseCap** (`capabilities/pause_cap`) — pause trading / per-pool mint / disable versions; one-way vs
  reversible; transferability; revoke-by-id channel; can a leaked cap DoS, for how long?
- **MarketLifecycleCap** (`capabilities/market_lifecycle_cap`) — the **privileged flush** gate (the
  permissionless flush was removed to close the NAV-manipulation gate; admin keeps break-glass by minting
  itself one). Revocation by id; can a revoked cap still flush?
- **predict_account custody auth** — THE high-value user-custody surface. NOTE: the old predict-side
  `TradeCap`/`DepositCap`/`WithdrawCap`/trade-proof model was REMOVED when custody moved to the `account`
  package; do not hunt for it. The current model (`account::Auth` owner-auth + `Permit<PredictApp>` app-auth)
  is detailed under Cross-package auth below — verify here only the predict-side surface: which predict
  entrypoints require owner vs app auth, and that withdraw authority cannot exceed intent.
- **Cross-package auth (first-class here):**
  - `account` custody: `generate_auth_as_app<PredictApp>` requires both a `Permit<PredictApp>` (provable only
    inside predict) AND registry app-authorization — confirm a keeper/anon cannot forge app-auth to move funds.
    `AccountAdminCap.deauthorize_app` blast radius (bricks permissionless settled-redeem? owner fallback?).
    `account` has no version gate — confirm the "custody not frozen by a predict version freeze" property is
    intended, not an escape hatch.
  - Any deepbook `BalanceManager` / cross-package delegation assumed by predict_account.
- **Permissionless paths** — every function with no cap/owner gate (keeper sync/passive-liquidation, manager/
  builder/market creation, permissionless deposit, settled redeem). Confirm each is SAFE to expose: can an anon
  move funds, harm another party's state, or inject bad state?

**Move ownership & visibility audit:**
- Every function that mutates a `Balance`/custody field: is it in the module that DECLARES the field, and is
  `object::owner` / the right cap checked? Any `public` that should be `public(package)`? Any shared-object
  transition (`share_object`) that widens access unexpectedly?

**Version-gating consistency (first-class deliverable):**
- Enumerate EVERY state-mutating public/external entry across all four packages; build the version-gate on/off
  table. Find asymmetries — custody moves, fund-claim, object-creation NOT gated while sibling trade paths ARE;
  for each, deliberate escape hatch or oversight? The mirror-sync model (allowed_versions on Registry copied to
  each object via permissionless sync): failure modes of a partially-synced fleet; can the running version be
  disabled out from under live flows?
- **Cross-package version skew + permissionless `migrate` (the unowned seam — audit it here).** THREE
  independent version schemes coexist: predict's `ProtocolConfig.version_watermark`/`current_version!()`,
  propbook's PER-FEED `version`, and `account` has NO version gate at all. Nothing reconciles them — predict
  never reads `feed.version()`. Each propbook feed exposes a **`public` permissionless `migrate(feed)`** gated
  only by `current_version!() > feed.version`, and feed reads abort on version mismatch. Audit: can a
  half-migrated feed fleet (some feeds at the old version) silently abort predict's priced reads →
  market-wide liveness brick? Is forward-only `migrate` (no field re-init / struct-layout-drift handling) safe
  across a real upgrade? Can predict-frozen + propbook-feed-newer + account-ungated mis-authorize or strand custody?

## Output
For each finding: the exact gate, the over/under-authorized action, the recovery path (or lack), confidence,
Evidence. Distinguish "trusted role can do economic damage within design" (a trust note) from "authorization
is bypassable or missing" (a code bug). Emit in the primer's report format; list the entries you classified
for caller-authority and version-gating, any unresolved, and Top 3. Return structured findings to the
orchestrator or write the solo report. Never modify source.
