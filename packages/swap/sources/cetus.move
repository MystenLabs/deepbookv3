module swap::cetus;

use cetus_clmm::pool::{calculate_swap_result, Pool, CalculatedSwapResult};

public fun quantity_out<Base, Quote>(
    pool: &Pool<Base, Quote>,
    quantity_in: u64,
    buy: bool,
): u64 {
    let result = calculate_swap_result(pool, buy, true, quantity_in);

    result.calculated_swap_result_amount_out()
}
