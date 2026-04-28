# DeepBook Predict

DeepBook Predict is a prediction-market package that prices binary and vertical
range positions from an oracle probability curve. The protocol uses one fair
price and an explicit trade fee; it does not expose a separate bid/ask spread.

## Fee Model

`trade_quote` and `range_trade_quote` return `(fair_price, fee_rate)`.
Both values are per-unit prices in `FLOAT_SCALING` (`1_000_000_000 = 100%`).
`fee_rate` is an absolute price increment, not basis points of notional.

For minting, the all-in unit price is:

```text
mint_price = fair_price + fee_rate
fee_amount = math::mul(fee_rate, quantity)
```

For pre-settlement redemption, the user receives fair value less the explicit
fee:

```text
gross_payout = math::mul(fair_price, quantity)
fee_amount = math::mul(fee_rate, quantity)
net_payout = gross_payout - fee_amount
```

The contract computes the gross payout first, splits out the fee balance, and
returns the remaining balance to the trader. This makes `fee_amount` the
official accrued fee amount. Integer math rounds down through `deepbook::math`,
so any residual dust from the fair-value leg stays with the vault rather than
being counted as a fee.

Settlement redemption is zero-fee. Settled quotes return the settlement fair
value with `fee_rate = 0`, and no fee reserve counters are updated.

If a pre-settlement redeem quote has `fee_rate > fair_price`, redemption aborts
instead of clamping the payout to zero. The trader can wait for settlement, where
redemption is zero-fee.

## Fee Accounting

Fees are routed through `FeeReserve` with configurable distribution shares. The
defaults are:

- 60% LP share
- 20% protocol share
- 20% insurance share

The LP share is immediately deposited back into the vault and becomes LP-owned
NAV. Protocol and insurance shares are stored as concrete balances in the fee
reserve and counted separately through fee accrual counters.

`total_fees_accrued` is the official total generated fee counter. The split
counters track how much of that total accrued to LPs, protocol revenue, and
insurance. Protocol and insurance withdrawal or usage flows are intentionally
out of scope for the current package state.

## UI And Indexer Notes

Clients should display the fair price and fee separately. For mint previews,
display `fair_price`, `fee_rate`, `fee_amount`, and the all-in mint price. For
pre-settlement redeem previews, display `fair_price`, `fee_rate`, `fee_amount`,
and net payout. For settlement redemption, display zero fee.

Events expose both `fee_rate` and `fee_amount`. `fee_rate` is the quoted per-unit
fee, while `fee_amount` is the exact amount routed into fee accounting for that
trade.
