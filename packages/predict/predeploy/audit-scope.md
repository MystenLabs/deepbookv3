# Predict Audit Scope

The cover for the external audit of the Predict on-chain system. It fixes what
is being audited, the trust assumptions the contracts rely on, what is left
out, and where the known-issue detail lives. It restates no finding: the detail
is in `open-items.md` (open work) and `response-policies.md` (risks accepted
with rationale).

## Snapshot

- Commit: the `deepbookv3` `main` commit tagged for the audit — stamped here
  when the tag is cut.
- Move packages in scope: `predict`, `propbook`, `block_scholes_oracle`,
  `account`, plus the shared libraries `fixed_math` and `dusdc`.

## Not in scope

- **Off-chain systems.** The indexer, server, keeper, and SDK live in other
  repositories and are not part of this snapshot.
- **The asynchronous NAV-flush rewrite.** The audited system values the pool in
  one atomic pool-flush transaction. A per-market asynchronous refresh is not
  part of this snapshot; the atomic flush is what is audited. Its known
  capacity limit is recorded as `open-items.md` C-1.
- **Code not present at this commit.** Only what exists in the four packages at
  the tagged commit is in scope. There is no token-staking reward system; the
  only stake references are the loss-rebate gaming-resistance gate, which is in
  scope.

## Trust model — what the contracts assume

Treat these as the system's stated assumptions, each tied to its tracked item.

- **The Block Scholes volatility surface is a trusted input.** Surface updates
  are permissionless and gated by source id, timestamp monotonicity, freshness,
  and a pricing-safe envelope — not by a signature verifier, which is currently
  a stub (`open-items.md` S-4, a deploy gate). Surface authenticity and quality
  are assumed until that verifier ships or the push surface is capability-gated.
  A malformed update also has a write-path gap (`open-items.md` P-5).
- **Oracle freshness bounds are policy, not proof.** Near-expiry pricing can
  consume a stale-but-fresh-enough surface (`open-items.md` P-2, O-1). Exact
  settlement trusts Propbook's exact-history key (`response-policies.md` RP-14).
- **Admin capabilities are trusted and non-rotatable.** The three root caps
  have no on-chain revoke or rotate path, and a leaked account admin cap can
  reach user custody (`open-items.md` G-1).
- **The pool flush is privileged, not permissionless** (`response-policies.md`
  RP-6). It executes at the exact NAV mark, with the pre-deploy price and basis
  circuit breakers intentionally removed (RP-1, RP-5).

## Known issues — where the detail lives

This snapshot ships with its open questions catalogued. Nothing here is hidden
from the audit; the two files below are the authoritative detail.

- **Open findings and undecided questions — `open-items.md`.** Deploy gate:
  S-4. Contract findings: P-2, P-5, P-8, P-10, P-11. Access and governance:
  G-1. Capacity and liveness: C-1. Oracle calibration: O-1. Maintainability:
  H-3, H-5, H-6, H-7.
- **Risks accepted with rationale — `response-policies.md` RP-1…RP-14 and the
  rounding policy R1–R3.** Live caveats an auditor should weigh: RP-11 (the
  liquidated-account cleanout gas is unmeasured under the shipped derived-state
  model and awaits re-measurement), RP-1 and RP-5 (price and basis circuit
  breakers were intentionally removed), RP-10 (large atomic transactions are
  cost-amplified by transaction-level metering).

## Deploy gates

Distinct from the audit: these carry an explicit decision before the system
holds real value — S-4 (the update verifier), P-8 (a protocol-reserve
withdrawal path), and G-1 (admin-capability rotation).
