# Lens 08 — Cross-Package Trust Boundaries

## STEP 0 — read shared context (required)
Read `../primer.md` in full first. Treat it as binding. If you cannot read it, stop and ask.

## Your lens
Cross-package trust boundaries. The oracle and custody layers were extracted out of `predict` into `propbook`
and `account`, with Block Scholes signature verification delegated to the external, provider-owned `bs_oracle`
package. From package version 4 the queued order flow lives in the `predict_orders` companion and the pricing
math and `LazerPrice` in `predict_math`. Each extraction created a SEAM: a place where `predict` (or `propbook`)
now **trusts** another package for something it used to own in-module. Your job: for every dependency edge,
state what the consumer trusts the producer for, whether that trust is validated at the boundary, and — the
central question — **whether the extraction silently DROPPED a validation the pre-split in-package code had.**
The split is only safe if it is behavior-preserving at every seam.

**Map each edge (consumer → producer): trust, enforcement, blast radius if violated.**

- **predict → propbook** (spot/forward/SVI + settlement). The pricing-safe envelope (forward>0, basis bounds,
  |rho|<=1, sigma band, freshness, pre-expiry gate) is **consumer-enforced in `predict::pricing`**, not in
  propbook — propbook stores raw provider fields. Verify predict enforces the FULL envelope on EVERY priced
  path (mint admission, redeem, liquidation trigger, NAV, settlement read); a store read that skips it trusts raw
  data. Verify binding correctness: market ↔ underlying ↔ the value/SVI store pair ↔ expiry — can a caller pass
  a wrong-underlying store into a priced flow (the registry's canonical binding is the check), and can a signed
  observation land in a slot it wasn't signed for (the sid derivation is the check)? Compare the pre-split
  in-package `market_oracle`/`pyth_source` checks against the post-split path and list anything not carried over.

- **predict → account** (USDC custody). Custody moved from the in-package manager into `account::Account`.
  Enumerate what auth/limits the old in-package custody enforced and confirm each is enforced across the new
  boundary: app-auth (`generate_auth_as_app<PredictApp>`) requires a `Permit<PredictApp>` (constructible only
  inside predict) AND registry authorization — confirm no keeper/anon path forges it; withdraw authority cannot
  exceed intent; `deauthorize_app` blast radius (which predict flows brick, is owner-redeem the guaranteed
  fallback); `account` has no version gate (confirm "custody not frozen by a predict version freeze" is the
  intended non-custodial property, not an exploitable escape hatch).

- **predict ↔ predict_orders** (the order-flow companion). Predict trusts an allowlisted witness type
  (`protocol_config::set_order_flow<OrderFlow>`, keyed by the original-ID type, so it survives companion
  upgrades) for `admit_mint`, `admit_sell`, `commit` and `try_fill`; `release` and `try_pay_settled` trust
  possession of the `OrderReceipt` instead. Verify: the witness cannot be built or leaked outside
  `order_flow.move`; no public companion function returns or exposes a receipt; every primitive re-binds the
  receipt to its market and re-checks its own gates (flow, version floor, cutover, pause, snapshot); each record's
  escrow is exactly what Predict's escrow checks expect; refunds and payouts survive the freeze, the witness
  being revoked, and the USDC deny list. Then list what Predict accepts on the companion's word alone (τ and the
  deadline window above Predict's own floors, cohort order, the backup-tick choice, the commit-time subsidy
  reservation it hands back as a free balance) and check `response-policies.md` RP-44 states that set
  completely. A companion upgrade is a trust root: name what an upgraded companion could do that the current
  one cannot.

- **predict / predict_orders → predict_math** (pure math and `LazerPrice`). A queued fill trusts only a
  `LazerPrice`, which is built from a verified `pyth_lazer::update::Update` (`from_update`) or package-internally
  (`from_parts`). Verify it cannot be built from anything else, that Predict's `chk_price` binds its feed,
  channel and timestamps to the receipt, and that every `math` function Predict calls returns a boolean, `none`
  or a code where Predict owns the abort. A `predict_math` upgrade that adds a constructor is a trust root.

- **propbook → bs_oracle** (the external verifier). Batches are mintable only by
  `verify::verify_and_create_{value,svi}_batch` after secp256k1/keccak signature verification against Block
  Scholes' shared `SignerRegistry`; holding a hot-potato `ValueBatch`/`SviBatch` IS the proof, so the relayer is
  untrusted by construction. The residual trust surface is Block Scholes itself: data quality, signer-key
  custody, and pause discretion (`set_paused` halts all minting — an accepted availability dependency). Confirm
  the batch types cannot be constructed or persisted outside `verify` (no `store` ability; test-only
  constructors excluded from publish), that the envelope timestamp is readable only from inside the signature,
  and that a malicious-but-signed batch is bounded by the store's skip rules plus the predict-side envelope
  (hand any envelope gap to lens 03).

- **propbook → pyth_lazer / wormhole** (signed spot). What is cryptographically verified upstream vs trusted in
  propbook; the published-at/original-id pinning in the manifests.

**Structural seam checks:**
- **Dependency direction & manifest style:** `account` is an old-style manifest (has `[addresses]`);
  `predict`/`propbook` are new-style. Confirm the allowed direction (old-style depended-on by new-style is
  fine; old-style cannot depend on new-style) and that the single `token`/`pyth_lazer`/`bs_oracle` package is
  resolved from ONE source across all consumers (a git-vs-local or rev mismatch makes two incompatible copies
  of the "same" package — a real, test-breaking failure mode here). For `bs_oracle` specifically, the
  `dep-replacements` published-at/original-id pinning IS the signature domain separator: a divergent
  resolution or an accidental republish rejects every provider signature.
- **Version / upgrade compatibility across packages:** what struct/type/version assumption must hold across an
  upgrade of one package but not the others; whether a type defined in `account`/`bs_oracle` and used by
  `predict`/`propbook` can drift (`bs_oracle`'s batch/update types deliberately lack `store`, so they cannot
  persist across independently published verifier versions).

## Output
For each seam: a trust row (consumer | producer | trusted-for | enforced-where | gap-if-any | blast-radius).
Call out every validation present pre-split but absent post-split as a finding. Emit in the primer's report
format with Evidence (the pre-split vs post-split code/grep/git diff). Top 3 = the seams most likely to leak.
Return structured findings to the orchestrator or write the solo report. Never modify source.
