// Pool structure and creation (1)
module deepbookv3::pool {
    use sui::balance::{Balance};
    use sui::table::{Table};
    // use 0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::Deep::DEEP;

    // Temporary, remove after structs all available
    public struct UserData has store {}
    public struct DEEP has store {}

    public struct Pool<phantom BaseAsset, phantom QuoteAsset> has key, store {
        id: UID,
        tick_size: u64,
        lot_size: u64,
        // bids: BigVec<TickLevel>,
        // asks: BigVec<TickLevel>,
        next_bid_order_id: u64,
        next_ask_order_id: u64,
        deep_config: DeepPrice,
        users: Table<address, UserData>,

        // Where funds will be held while order is live
        base_balances: Balance<BaseAsset>,
        quote_balances: Balance<QuoteAsset>,
        deepbook_balance: Balance<DEEP>,

        // treasury and burn address
        treasury: address, // Input tokens
        burn_address: address, // DEEP tokens

        // Historical, current, and next PoolData.
        historical_pool_data: vector<PoolData>, // size constraint
        pool_data: PoolData,
        next_pool_data: PoolData,
    }

    // Pool Data for a specific Epoch (1)
	public struct PoolData has copy, store {
        pool_id: ID,
        epoch: u64,
        total_maker_volume: u64,
        total_staked_maker_volume: u64,
        total_fees_collected: u64,
        stake_required: u64,
        taker_fee: u64,
        maker_fee: u64,
	}
	
	// DEEP price points used for trading fee calculations (2)
	public struct DeepPrice has store{
		id: UID,
		last_insert_timestamp: u64,
		price_points_base: vector<u64>, // deque with a max size
		price_points_quote: vector<u64>,
		deep_per_base: u64,
		deep_per_quote: u64,
	}

    // // Creates a new pool through the manager using defaults stored in the manager.
    // public fun create_pool<BaseAsset, QuoteAsset>(
    //     base: BaseAsset,
    //     quote: QuoteAsset,
    //     state: &mut State,
    //     ctx: &mut TxContext,
    // ) {
    //     let my_params = state.get_defaults();
    //     let pool = Pool;
    //     state.track_pool(pool);
    //     transfer::public_share_object(pool);
    // }

    // // This will be automatically called if not enough assets in settled_funds
    // // User cannot manually deposit
    // // Deposit BaseAsset Tokens (2)
    // fun deposit_base<BaseAsset, QuoteAsset>(
    //     pool: &mut Pool<BaseAsset, QuoteAsset>,
    //     user_account: &mut Account,
    //     amount: u64,
    //     ctx: &mut TxContext,
    // ) {
    //     // a) Withdraw from user account
    //     let coin: Coin<BaseAsset> = deepbookv3::account::withdraw(user_account, amount, BalanceKey<BaseAsset>{}, ctx);
    //     let balance: Balance<BaseAsset> = coin.into_balance();
    //     // b) merge into pool balances
    //     pool.base_balances.join(balance);
    // }

    // // Deposit QuoteAsset Tokens
    // fun deposit_quote<BaseAsset, QuoteAsset>(
    //     pool: &mut Pool<BaseAsset, QuoteAsset>,
    //     user_account: &mut Account,
    //     amount: u64,
    //     ctx: &mut TxContext,
    // ) {
    //     // a) Withdraw from user account
    //     let coin: Coin<QuoteAsset> = deepbookv3::account::withdraw(user_account, amount, BalanceKey<QuoteAsset>{}, ctx);
    //     let balance: Balance<QuoteAsset> = coin.into_balance();
    //     // b) merge into pool balances
    //     pool.quote_balances.join(balance);
    // }

    // // Deposit DEEP Tokens
    // fun deposit_deep<BaseAsset, QuoteAsset>(
    //     pool: &mut Pool<BaseAsset, QuoteAsset>,
    //     user_account: &mut Account,
    //     amount: u64,
    //     ctx: &mut TxContext,
    // ) {
    //     // a) Withdraw from user account
    //     let coin: Coin<DEEP> = deepbook::account::withdraw(user_account, amount, BalanceKey<DEEP>{}, ctx);
    //     let balance: Balance<DEEP> = coin.into_balance();
    //     // b) merge into pool balances
    //     pool_custodian.deepbook_balances.join(balance);
    // }

    // // Withdraw settled funds (3)
    // public(package) fun withdraw_settled_funds(
    //     account: &mut Account,
    //     pool: &mut Pool,
    //     ctx: &mut TxContext,
    //     ) {
    //     // Check user's settled, unwithdrawn amounts.
    //     // Deposit them to the user's account.
    //     let user_data = pool.users[account.owner];
    //     let coin = // split coin from pool balances based on user_data
    //     deepbook::account::deposit(account, coin);
    // }

    // // Treasury/Burn (4)
    // public fun send_to_treasury<T: key + store>(
    //     pool: &Pool,
    //     fee: Coin<T>,
    // ){
    //     transfer::transfer(fee, pool.treasury)
    // }

    // public(package) fun burn(
    //     pool: &Pool,
    //     fee: Coin<DEEP>,
    // ){
    //     transfer::transfer(fee, pool.burn_address)
    // }

    // // Order management (5)
    // public(package) fun place_order(&mut Account, &mut Pool, other_params) {
    //     // // Refresh state as necessary
    //     // refresh_state();
        
    //     // // Optionally deposit from account
    //     // deposit_base();
    //     // deposit_quote();
    //     // deposit_deep();
        
    //     // // Place order
    //     // place_actual_order();
    // }

    // public(package) fun create_order() // Support creating multiple orders
    // // This may include different types of taker/maker orders
    // public(package) fun modify_order() // Support modifying multiple orders
    // public(package) fun cancel_order()
    // public(package) fun cancel_all()
    // public(package) fun get_order()
    // public(package) fun get_all_orders()
    // public(package) fun get_book()
    // public(package) fun get_base_asset()
    // public(package) fun get_quote_asset()
	
	// // Called by State when a proposal passes quorum (3)
	// public(package) fun update_next_state<BaseAsset, QuoteAsset>(
	//   pool: &mut Pool<BaseAsset, QuoteAsset>,
	//   state: PoolData,
	// ) {
	//   pool.next_pool_state = state;
	// }
	
	// // First interaction of each epoch processes this
	// fun refresh_state(
	//   pool: &mut Pool,
	//   ctx: &TxContext,
	// ) {
	//   let current_epoch = ctx.epoch();
	//   if (pool.current_pool_data.epoch == current_epoch) return;
	// 	pool.historical_pool_data.push_back(pool.current_pool_state);
	// 	pool.current_pool_data = pool.next_pool_data;
	// 	pool.current_pool_data.epoch = current_epoch;
	// }
}