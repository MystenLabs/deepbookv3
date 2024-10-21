// module swap::swap;

// use deepbook::balance_manager::{BalanceManager, TradeProof};
// use deepbook::pool::Pool;
// use sui::clock::Clock;
// use sui::sui::SUI;

// const FLOAT_SCALING_U128: u128 = 1_000_000_000;

// public fun can_swap<DEEP, USDC>(
//     sui_usdc: &Pool<SUI, USDC>,
//     deep_usdc: &Pool<DEEP, USDC>,
//     deep_sui: &Pool<DEEP, SUI>,
//     clock: &Clock,
// ): (u64, u64) {
//     // start with USDC
//     let usdc = 1_000_000;
//     let sui = quantity_out(sui_usdc, usdc, true, clock);
//     let deep = quantity_out(deep_sui, sui, true, clock);
//     let usdc_out = quantity_out(deep_usdc, deep, false, clock);

//     // start with SUI
//     let sui = 1_000_000;
//     let usdc = quantity_out(sui_usdc, sui, false, clock);
//     let deep = quantity_out(deep_usdc, usdc, true, clock);
//     let sui_out = quantity_out(deep_sui, deep, false, clock);

//     (usdc_out, sui_out)
// }

// public fun swap<DEEP, USDC>(
//     sui_usdc: &mut Pool<SUI, USDC>,
//     deep_sui: &mut Pool<DEEP, SUI>,
//     deep_usdc: &mut Pool<DEEP, USDC>,
//     balance_manager: &mut BalanceManager,
//     quantity: u64,
//     buy: bool,
//     clock: &Clock,
//     ctx: &mut TxContext,
// ) {
//     let proof = balance_manager.generate_proof_as_owner(ctx);
//     if (buy) {
//         let sui_out = swap_buy(
//             sui_usdc,
//             balance_manager,
//             &proof,
//             quantity,
//             clock,
//             ctx,
//         );
//         let deep_out = swap_buy(
//             deep_sui,
//             balance_manager,
//             &proof,
//             sui_out,
//             clock,
//             ctx,
//         );
//         swap_sell(deep_usdc, balance_manager, &proof, deep_out, clock, ctx);
//     }
// }

// fun swap_buy<Base, Quote>(
//     pool: &mut Pool<Base, Quote>,
//     balance_manager: &mut BalanceManager,
//     proof: &TradeProof,
//     quantity: u64,
//     clock: &Clock,
//     ctx: &TxContext,
// ): u64 {
//     let (base_quantity, _, _) = pool.get_quantity_out(0, quantity, clock);
//     let (_, lot_size, _) = pool.pool_book_params();
//     let base_quantity = base_quantity - base_quantity % lot_size;
//     pool.place_market_order(
//         balance_manager,
//         proof,
//         0,
//         0,
//         base_quantity,
//         true,
//         true,
//         clock,
//         ctx,
//     );

//     base_quantity
// }

// fun swap_sell<Base, Quote>(
//     pool: &mut Pool<Base, Quote>,
//     balance_manager: &mut BalanceManager,
//     proof: &TradeProof,
//     quantity: u64,
//     clock: &Clock,
//     ctx: &TxContext,
// ): u64 {
//     pool.place_market_order(
//         balance_manager,
//         proof,
//         0,
//         0,
//         quantity,
//         false,
//         true,
//         clock,
//         ctx,
//     );

//     quantity
// }

// fun quantity_out<Base, Quote>(
//     pool: &Pool<Base, Quote>,
//     quantity_in: u64,
//     buy: bool,
//     clock: &Clock,
// ): u64 {
//     let (bid_price, _, ask_price, _) = next_tick(pool, clock);
//     if (buy) {
//         mul(quantity_in, ask_price)
//     } else {
//         div(quantity_in, bid_price)
//     }
// }

// fun next_tick<Base, Quote>(
//     pool: &Pool<Base, Quote>,
//     clock: &Clock,
// ): (u64, u64, u64, u64) {
//     let (
//         bid_prices,
//         bid_quantities,
//         ask_prices,
//         ask_quantities,
//     ) = pool.get_level2_ticks_from_mid(1, clock);
//     let bid_price = bid_prices[0];
//     let bid_quantity = bid_quantities[0];
//     let ask_price = ask_prices[0];
//     let ask_quantity = ask_quantities[0];

//     (bid_price, bid_quantity, ask_price, ask_quantity)
// }

// fun mul(x: u64, y: u64): u64 {
//     let (_, result) = mul_internal(x, y);

//     result
// }

// fun div(x: u64, y: u64): u64 {
//     let (_, result) = div_internal(x, y);

//     result
// }

// fun mul_internal(x: u64, y: u64): (u64, u64) {
//     let x = x as u128;
//     let y = y as u128;
//     let round = if ((x * y) % FLOAT_SCALING_U128 == 0) 0 else 1;

//     (round, (x * y / FLOAT_SCALING_U128) as u64)
// }

// fun div_internal(x: u64, y: u64): (u64, u64) {
//     let x = x as u128;
//     let y = y as u128;
//     let round = if ((x * FLOAT_SCALING_U128 % y) == 0) 0 else 1;

//     (round, (x * FLOAT_SCALING_U128 / y) as u64)
// }
