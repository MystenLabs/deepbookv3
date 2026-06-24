# Economic attack catalog (reference)

Value-extraction patterns from DeFi exploit practice, mapped to concrete Predict surfaces. Lens 02 builds
chains from these; lens 09 reproduces them. Each entry: the pattern → where it could land in Predict.

## Mark-timing / LP dilution
Deposit before a favorable mark, withdraw after — extract value from incumbents.
- Predict: async supply/withdraw priced at the frozen flush `current_nav`. Can a supplier/withdrawer time
  requests around a flush, or force a mark to move (push oracle data, trigger liquidation) between request and
  drain, to mint cheap shares or redeem rich? Verify the single frozen mark + FIFO drain closes this.

## Oracle manipulation (within trust bounds)
Move a price you partially control to your benefit before it reverts.
- Predict: the BS operator is trusted (D031), but the *consumer envelope* is the only on-chain bound. Find a
  freshness-skew (spot vs forward vs svi at different times) or an envelope gap that lets an in-bounds push move
  mint admission / redeem / liquidation trigger / NAV / settlement in the attacker's favor.

## Settled-vs-live arbitrage
Exploit a discontinuity between the pre-settlement (live/backing) value and the terminal settled payout.
- Predict: live backing is a conservative upper bound; settled payout is exact. Find a sequence (redeem live vs
  settled, liquidate-then-settle — the #1080 path) where the two diverge in the user's favor or under-reserve.

## Rounding-direction abuse
Accumulate dust by driving many operations whose rounding favors the user.
- Predict: mint contribution/fee, redeem payout, floor split on partial close, LP share/withdraw pricing,
  rebate reserve. R2 says dust → protocol; find any site that rounds the wrong way at scale.

## Fee / penalty / builder interactions
Game the fee model: avoid a fee, double-collect, or shift cost.
- Predict: the exact-amount vs exact-quantity mint variants, the EWMA gas penalty, builder-fee attribution +
  claim, fee-incentive subsidy. Find a combination that under-charges the trader or double-credits a builder.

## Sequencing / intra-PTB
Interleave calls to observe or force an intermediate state.
- Predict: an order liquidated during its own redeem; supply/withdraw straddling a valuation lock; a mint that
  triggers a passive-liquidation pass mid-flow; shares priced against a half-built NAV.

## DoS / griefing for economic gain
Brick or starve a risk-reducing action to trap value or avoid loss.
- Predict: drive a backing subtraction to underflow-abort (R1); inflate liquidation-scan gas; starve settlement
  of an under-floor order; `deauthorize_app<PredictApp>` bricking permissionless cleanup.

## Sandwich / MEV-adjacent
Front/back-run a victim's value-moving tx.
- Predict: less classical without an AMM, but a keeper/LP can reorder around a victim's mint/redeem/flush —
  check whether any user-facing price/mark is observable-then-actionable within one block.
