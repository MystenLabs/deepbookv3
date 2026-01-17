# DeepBook Margin

DeepBook Margin is a decentralized margin trading protocol built on top of DeepBookV3 on Sui. It
enables leveraged trading by allowing users to borrow assets against their collateral, execute
margin orders on DeepBook's central limit order book, and manage risk with advanced features like
take profit and stop loss conditional orders. The protocol includes a lending pool where
suppliers can earn interest by providing liquidity for margin traders to borrow.

## DeepBook Margin Information

- [Package and Pools](https://docs.google.com/document/d/1uK4MNqYa0LdhVqBD4KqOcWG1N1nNNe3JwbeUZc1kH1I)
- [Contract Documentation](https://docs.sui.io/standards/deepbook-margin)
- [SDK Documentation](https://docs.sui.io/standards/deepbook-margin-sdk)
- [Example SDK Usage](https://github.com/MystenLabs/ts-sdks/tree/main/packages/deepbook-v3/examples)

## Margin Manager

The `MarginManager` is a shared object that represents a single margin trading account. It holds
collateral balances, tracks borrowed positions, and interfaces with both DeepBookV3 for trading
and the MarginPool for borrowing. Each MarginManager is linked to a specific DeepBook pool and
its corresponding MarginPool.

Users can deposit collateral (base, quote, or DEEP tokens), borrow assets to increase their
trading position, and repay loans. The MarginManager tracks the user's risk ratio, which
determines liquidation eligibility. If a position becomes undercollateralized, it can be
liquidated by any party.

## Margin Pool

The `MarginPool` is a lending pool that provides liquidity for margin traders. It consists of:

1. **Supply Side** - Users can supply assets to earn interest from borrowers. Suppliers receive
   shares representing their portion of the pool.
2. **Borrow Side** - Margin traders borrow from the pool to leverage their positions. Interest
   accrues based on utilization rate.
3. **Interest Model** - Dynamic interest rates adjust based on pool utilization to balance supply
   and demand.

Suppliers mint a `SupplierCap` to track their deposits and can withdraw their supplied assets
plus accrued interest at any time, subject to available liquidity.

## Take Profit / Stop Loss (TPSL)

DeepBook Margin supports conditional orders that automatically execute when price conditions are
met:

- **Take Profit** - Automatically close a position when the price reaches a favorable target
- **Stop Loss** - Automatically close a position to limit losses when price moves against you

Conditional orders are stored on-chain and can be executed by anyone (permissionlessly) once the
trigger price is reached. This enables automated risk management without requiring users to
monitor positions constantly.

## Liquidation

When a MarginManager's risk ratio exceeds the maximum threshold (position becomes
undercollateralized), it becomes eligible for liquidation. Any user can call the liquidate
function to:

1. Repay the outstanding debt
2. Receive the collateral plus a liquidation bonus

This mechanism ensures the protocol remains solvent and incentivizes liquidators to maintain
system health.
