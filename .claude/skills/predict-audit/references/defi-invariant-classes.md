# DeFi invariant classes (reference)

The four invariant classes property-based DeFi audits center on (per standard practice — Trail of Bits /
Recon-style invariant testing), mapped to Predict surfaces. Lens 01 builds the ledger; lens 09 fuzzes these.

## 1. Solvency / conservation
The protocol must always be able to pay what it owes; value is conserved across parties.
- `expiry_cash`: `cash_balance >= payout_liability + rebate_reserve` after EVERY cash mutation.
- Live backing (max-live payout) must bound the exact settled liability for every order.
- DUSDC is conserved across trader / LP / protocol / builder — no path mints value from nothing or strands it.
- LP NAV: the exact `current_nav` mark prices PLP supply AND withdraw identically (`supply_NAV == withdraw_NAV
  == TRUE`) at the valuation boundary — no over/under-count, so no dilution and no liveness clamp under-pays.

## 2. Access control
Only the intended actor can move value or change critical state (see the Move checklist).
- Every custody/payout move requires the right cap/proof/owner/app-auth; permissionless paths are safe to expose.
- Version-gating is consistent: risk-increasing and custody paths are gated wherever trade paths are.

## 3. Liquidation
Under-collateralized / under-floor positions are removed correctly and cannot be blocked.
- Passive liquidation of an under-floor leveraged order cannot be starved, skipped, double-applied, or griefed;
  paging cursors/watermarks cover all candidates under budgeted passes.
- The aggregate-floor NAV precondition holds: every active leveraged order is individually above its floor
  before valuation, else aggregate-floor subtraction overstates recoverable value.

## 4. Oracle integrity
Prices fed into value decisions are fresh, in-range, and provenance-correct.
- Staleness/zero/future gating on Pyth spot; the consumer envelope (forward>0, basis, |rho|<=1, sigma band,
  freshness) is enforced on every priced path.
- Settlement reads the exact post-expiry print and fails closed if absent; no weaker path pre-empts it.
- A trusted-operator BS push is bounded by the consumer envelope (the on-chain drift guards are intentionally
  removed — D031); the question is what the envelope does NOT bound.

## Edge dimensions the fuzzer must hit (where these invariants break in practice)
- **Rounding**: direction and accrual under adversarial magnitudes.
- **Sequencing**: intra-PTB interleavings (mint↔NAV↔liquidate↔settle↔flush) producing an assumed-impossible state.
- **Partial state**: partial-close → reinsert keeping exposure/payout-tree/accounting in lockstep; abort-after-
  partial-mutation.
- **Boundary**: max leverage, sentinel ticks, smallest/largest position, settlement exactly at expiry.
