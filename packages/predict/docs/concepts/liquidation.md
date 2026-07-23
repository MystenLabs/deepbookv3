# Liquidation

Liquidation removes a leveraged Predict position whose live value has decayed to or below its floor-derived knock-out level. It is a knock-out in the barrier-option sense — extinguishment with zero order payout — not an auction: the holder receives nothing from the knocked-out order, the order is struck from the live valuation indexes, and the holder's account position remains as its only record until closed. Only leveraged positions are subject to liquidation; an unleveraged (1x) position has no floor and cannot be liquidated. This document describes the trigger condition, the data structure that selects candidates, the bounded scan budgets, and what those bounds imply for liquidity providers.

For the contract model behind a position's floor and leverage, see [./leverage-and-floor.md](./leverage-and-floor.md). For LP exposure to bounded scans, see [../risks.md](../risks.md). Tunable parameters referenced below are defined in [../design/configuration.md](../design/configuration.md).

## Why only leveraged positions liquidate

Predict sells one binary (digital) contract per position, not a spot contract plus a separate debt overlay. A position's live value is its range-probability value minus a static floor, floored at zero. The floor is the financed share of the contract's entry premium -- the slice the pool funded on the holder's behalf when leverage was applied: at mint, the contract first computes `entry_value = floor(entry_probability × quantity / 1e9)`, then charges `net_premium = ceil(entry_value × 1e9 / leverage)` and seeds the exact remainder (`financed_amount = entry_value − net_premium`) into LP backing. That financed amount is stored as `floor_shares`, the static floor the holder must return to the pool out of the order's own value.

A 1x position has `financed_amount = 0`, hence `floor_shares = 0`. An `Order` is leveraged exactly when `floor_shares > 0`, and only leveraged orders are inserted into the liquidation index. The floor is limited-recourse to the order that created it: it can offset only that order's own live value, capped at that value. Once the live value falls to the floor, the holder's equity in the position is gone, and the pool's backing is exactly the floor it is owed. Liquidation closes the gap before the live value can fall *below* the floor, which would leave the pool under-recovered.

## The liquidation condition

For one active leveraged order, the liquidation check uses three quantities, all evaluated against the same fresh live oracle inputs:

- **gross value** — the position's probability-weighted live value, `gross_value = range_probability × quantity`, where `range_probability` is the live probability that settlement lands in the order's strike range (a 1e9-scaled fixed-point value).
- **floor amount** — the static floor the holder owes from this order's own value, `floor_amount = floor_shares`.
- **liquidation LTV** — a 1e9-scaled loan-to-value threshold snapshotted per expiry (`liquidation_ltv`), where a smaller value liquidates earlier.

The order is liquidated when

```
gross_value <= floor(floor_amount × 1e9 / liquidation_ltv)
```

The right-hand side is the **knock-out level**: the gross value at which the floor reaches the configured fraction (the LTV) of the position's value. Multiplications and divisions here are Predict's 1e9 fixed-point operations that round down, so the threshold is `floor(floor_amount × 1e9 / liquidation_ltv)`. In probability space the same barrier is the **knock-out probability** `p* = floor_amount / (liquidation_ltv × quantity)`: the order knocks out when its range probability falls to `p*`. Because the floor amount is static, a position becomes liquidatable when `range_probability` drops far enough -- the market moves away from the order's range or the live SVI curve reprices the range lower.

At mint, the same threshold relation is enforced in the opposite direction: entry must sit strictly above the liquidation threshold (`entry_value > floor(financed_amount × 1e9 / liquidation_ltv)`), where `entry_value = floor(entry_probability × quantity / 1e9)`. A position therefore always begins solvent and only crosses the threshold later if its range value falls.

## What liquidation does

Liquidation is a pure knock-out with zero order payout. When the condition holds, the protocol:

1. Removes the order from the liquidation index's active candidate set.
2. Removes the order's full live-index terms from both NAV and payout backing, so it no longer contributes to live pool valuation.
3. Emits `OrderLiquidated`.

No payout is computed and no cash moves at liquidation time. The holder's account is not touched — liquidation does not know which account holds the position, which is why `OrderLiquidated` carries no owner or account field and consumers join it to the original `OrderMinted` by `order_id`. After liquidation the account position is the order's only remaining record (the liquidated state is derived from the order's absence from the active index; nothing book-side is stored): while the market is live, the holder clears it through owner-auth `redeem_live`; after settlement, the holder can use `redeem_settled` or a keeper can use `redeem_settled_permissionless` while Predict app-auth remains authorized. Cleanup removes the account position and emits `LiquidatedOrderRedeemed` with a zero payout. This zero-payout cleanup does not exclude the account from the separate settled trading-loss rebate flow; after all of the account's positions in the expiry are closed, any rebate is computed from the normal expiry-level PnL and trader-paid fee basis.

```mermaid
stateDiagram-v2
    [*] --> Active: leveraged mint
    Active --> Active: market moves / SVI reprices
    Active --> Liquidated: gross_value <= threshold
    Liquidated --> Cleared: holder/keeper redeems (zero payout)
    Active --> Closed: live or settled redeem
    Cleared --> [*]
    Closed --> [*]
```

## Permissionless liquidation

Anyone may run a liquidation pass; no capability or admin authority is required. Both entrypoints take Propbook `PythFeed` plus BS spot/forward/SVI feed objects, and a pass is gated on the package version being allowed for the market, the protocol not being mid-valuation, those feeds matching Propbook's current canonical bindings for the market's underlying and expiry, and the market still being pre-expiry for live pricing. There are two entry shapes: a bounded pass that the caller hands a budget, and a single-order attempt by ID. Both re-derive the threshold from current feed state and liquidate only orders that are genuinely under their floor; an order that is checked but still solvent is left untouched.

Liquidation passes are also folded into the hot trade paths. Mint and live redeem each run a bounded pass (sized by the `trade_liquidation_budget`) before they touch exposure, so ordinary trading continuously clears under-floor positions even if no dedicated keeper is active. A live redeem additionally re-checks whether its own target became liquidated during that pass and, if so, diverts to the zero-payout cleanup path.

## The liquidation book

The active index is a sorted store of leveraged order IDs (`LiquidationBook`). Order IDs are held in ascending order across bounded pages, and the priority an order should be checked at is encoded directly in the bits of its packed `order_id`. The front of the index is therefore the highest-priority candidate, with no separate mutable ranking to maintain: insertion keeps the list sorted, and selection reads from the front.

The packed `order_id` lays out its highest bits as the quantity field, then floor shares, then the strike boundary ticks. Quantity and floor shares are stored as *complements* (`U32_MASK − quantity_lots`, `U64_MASK − floor_shares`), so larger values produce smaller packed keys and sort earlier. The resulting ascending order is, in priority order:

1. **larger quantity first** — bigger positions, which carry more pool risk, are checked before smaller ones;
2. **then larger floor shares** — among equal quantities, higher floor coverage has the higher liquidation threshold and more pool recovery at stake.

This ordering is a deterministic consequence of the encoding alone. The book never recomputes a health score to rank orders; it relies on the fact that the qualities that make an order worth checking first are baked into the same integer that identifies it.

The book also keeps a `passive_watermark`: the last order ID visited by the rolling passive scan, so that successive bounded passes advance through the tail of the index rather than re-checking the same orders.

## Bounded budgets

Every liquidation pass is bounded. A pass never scans the whole active set; it selects at most `budget` candidates and checks only those. There is one budget, `trade_liquidation_budget`, admin-tunable (see [../design/configuration.md](../design/configuration.md)) and spent on the inline pass that runs before each mint and live redeem. There is no separate valuation-time budget: the NAV flush values each market exactly with no liquidation pass (see [Consequence for valuation and LP exposure](#consequence-for-valuation-and-lp-exposure)).

Within a budget, candidates are drawn from two slices. The split ratio is fixed by the upgrade-required `liquidation_tail_scan_divisor` constant: the passive tail receives `budget / liquidation_tail_scan_divisor` rounded down, and the head receives the remainder. With the current divisor of `3`, this spends about two thirds of the budget on the head-priority slice and one third on passive tail rotation (`16/8` for the trade budget of `24`).

- **Head slice** — the budget remainder (`budget - floor(budget / liquidation_tail_scan_divisor)`) is always taken from the front of the index, i.e. the highest-priority orders. These large, high-risk positions are re-checked on every pass.
- **Passive slice** — up to `floor(budget / liquidation_tail_scan_divisor)` candidates continue a rolling scan from the `passive_watermark`, advancing through the rest of the index and wrapping back to the start of the tail. This guarantees that lower-priority orders are eventually visited over successive passes rather than being starved by the head slice.

Selecting candidates advances the passive watermark, so the scan makes forward progress across calls even when each individual pass is small.

## Consequence for valuation and LP exposure

The knock-out is a *discretely monitored* barrier: it is enforced by bounded keeper passes, not continuous observation. Because scans are bounded, the protocol never proves in a single transaction that *every* leveraged order is above its floor — and it does not need to. Live pool NAV subtracts each leveraged order's floor from its own range value, capped at it (`min(quantity × range_price, floor_shares)`, summed as the NAV correction — see [leverage and the floor](./leverage-and-floor.md)). Because the cap is taken **per order**, each order's net contribution is `max(0, range_value − floor)` in every state: an order above its floor contributes its excess, and an order *below* its floor — economically exhausted, its true recoverable value zero — nets to exactly zero, never a negative or overstated amount.

`current_nav` is therefore **structurally complete whether or not the book has been swept**: it needs no valuation-time liquidation pass and is not conditional on the book being above floor (see [invariants](../design/invariants.md)). Its fixed-point center carries a certified numerical-error radius into the pool flush. Bounded liquidation exists to clear exhausted orders out of the live indexes — letting holders close worthless positions and releasing each removed order's backing buffer back to the pool — not to keep the NAV topology honest. Liquidation timeliness is thus a holder-facing and index-hygiene concern, not the LP-facing NAV-overstatement risk it would be under an aggregate-floor mark. Admin tuning of the budget and the liquidation LTV trades gas cost per pass against how promptly exhausted positions are cleared.

## Events

| Event | Emitted when | Notable fields |
| --- | --- | --- |
| `OrderLiquidated` | An order is removed by liquidation. | `expiry_market_id`, `order_id`, `quantity`, `gross_value` (live value checked against the threshold), `floor_amount` (current floor in DUSDC base units), `liquidation_ltv` (1e9-scaled threshold used). No owner/account — join `order_id` to `OrderMinted`. |
| `LiquidatedOrderRedeemed` | An account clears a liquidated position (zero payout). | `expiry_market_id`, `account_id`, `order_id`, `position_root_id`, `owner`, `quantity_closed`. |

`OrderLiquidated` reports the live value and floor at the moment of the knock-out; `LiquidatedOrderRedeemed` reports the later, separate act of the holder closing out the worthless position. The two are joined by `order_id` (and, across partial-close replacement chains, by `position_root_id`).
