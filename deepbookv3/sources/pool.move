module deepbookv3::pool {
    use sui::balance::{Self,Balance};
    use sui::table::{Self, Table};
    use sui::sui::SUI;
    use sui::event;
    use sui::coin::{Self, Coin};
    use std::ascii::{Self, String};
    use std::type_name::{Self, TypeName};
    use sui::linked_table::{Self, LinkedTable};

    use deepbookv3::deep_price::{Self, DeepPrice};
    use deepbookv3::string_helper::{Self};
    use deepbookv3::critbit::{Self, CritbitTree, is_empty, borrow_mut_leaf_by_index, min_leaf, remove_leaf_by_index, max_leaf, next_leaf, previous_leaf, borrow_leaf_by_index, borrow_leaf_by_key, find_leaf, insert_leaf};
    use deepbookv3::math::Self as clob_math;
    use deepbookv3::user::{User};
    use deepbookv3::account::{Self, Account};
    // use 0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::Deep::DEEP;

    // <<<<<<<<<<<<<<<<<<<<<<<< Error Codes <<<<<<<<<<<<<<<<<<<<<<<<
    const EInvalidFee: u64 = 1;
    const ESameBaseAndQuote: u64 = 2;
    const EInvalidTickSizeLotSize: u64 = 3;
    const EUserNotFound: u64 = 4;

    // <<<<<<<<<<<<<<<<<<<<<<<< Constants <<<<<<<<<<<<<<<<<<<<<<<<
    const FEE_AMOUNT_FOR_CREATE_POOL: u64 = 100 * 1_000_000_000; // 100 SUI

    // <<<<<<<<<<<<<<<<<<<<<<<< Events <<<<<<<<<<<<<<<<<<<<<<<<
    /// Emitted when a new pool is created
    public struct PoolCreated has copy, store, drop {
        /// object ID of the newly created pool
        pool_id: ID,
        base_asset: TypeName,
        quote_asset: TypeName,
        // 10^9 scaling
        taker_fee: u64,
        maker_fee: u64,
        tick_size: u64,
        lot_size: u64,
    }

    // <<<<<<<<<<<<<<<<<<<<<<<< Structs <<<<<<<<<<<<<<<<<<<<<<<<

    // Temporary, remove after structs all available
    public struct DEEP has store {}

    public struct Order has store, drop {
        // For each pool, order id is incremental and unique for each opening order.
        // Orders that are submitted earlier has lower order ids.
        // 64 bits are sufficient for order ids whereas 32 bits are not.
        // Assuming a maximum TPS of 100K/s of Sui chain, it would take (1<<63) / 100000 / 3600 / 24 / 365 = 2924712 years to reach the full capacity.
        // The highest bit of the order id is used to denote the order type, 0 for bid, 1 for ask.
        order_id: u64,
        client_order_id: u64,
        // Only used for limit orders.
        price: u64,
        // quantity when the order first placed in
        original_quantity: u64,
        // quantity of the order currently held
        quantity: u64,
        is_bid: bool,
        /// Order can only be canceled by the `AccountCap` with this owner ID
        owner: address,
        // Expiration timestamp in ms.
        expire_timestamp: u64,
        // reserved field for prevent self_matching
        self_matching_prevention: u8
    }

    public struct TickLevel has store {
        price: u64,
        // The key is order's order_id.
        open_orders: LinkedTable<u64, Order>,
    }

    public struct Pool<phantom BaseAsset, phantom QuoteAsset> has key, store {
        id: UID,
        tick_size: u64,
        lot_size: u64,
        bids: CritbitTree<TickLevel>,
        asks: CritbitTree<TickLevel>,
        next_bid_order_id: u64,
        next_ask_order_id: u64,
        deep_config: DeepPrice,
        users: Table<address, User>,
        base_type: TypeName,
        quote_type: TypeName,

        // Where funds will be held while order is live
        base_balances: Balance<BaseAsset>,
        quote_balances: Balance<QuoteAsset>,
        deepbook_balance: Balance<DEEP>,

        // treasury and burn address
        treasury_address: address, // Input tokens
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

    public(package) fun create_pool<BaseAsset, QuoteAsset>(
        taker_fee: u64,
        maker_fee: u64,
        tick_size: u64,
        lot_size: u64,
        creation_fee: Balance<SUI>,
        ctx: &mut TxContext,
    ): String {
        assert!(creation_fee.value() == FEE_AMOUNT_FOR_CREATE_POOL, EInvalidFee);

        let base_type_name = type_name::get<BaseAsset>();
        let quote_type_name = type_name::get<QuoteAsset>();

        assert!(clob_math::unsafe_mul(lot_size, tick_size) > 0, EInvalidTickSizeLotSize);
        assert!(base_type_name != quote_type_name, ESameBaseAndQuote);
        
        // TODO: Assertion for tick_size and lot_size

        let pool_uid = object::new(ctx);
        let pool_id = *object::uid_as_inner(&pool_uid);

        // Creates the capability to mark a pool owner.

        event::emit(PoolCreated {
            pool_id,
            base_asset: base_type_name,
            quote_asset: quote_type_name,
            taker_fee,
            maker_fee,
            tick_size,
            lot_size,
        });

        let deepprice = deep_price::initialize();

        let pooldata = PoolData{
            pool_id,
            epoch: ctx.epoch(),
            total_maker_volume: 0,
            total_staked_maker_volume: 0,
            total_fees_collected: 0,
            stake_required: 0,
            taker_fee,
            maker_fee,
        };

        let pool = (Pool<BaseAsset, QuoteAsset> {
            id: pool_uid,
            bids: critbit::new(ctx),
            asks: critbit::new(ctx),
            next_bid_order_id: 0,
            next_ask_order_id: 0,
            users: table::new(ctx),
            deep_config: deepprice,
            tick_size,
            lot_size,
            base_balances: balance::zero(),
            quote_balances: balance::zero(),
            deepbook_balance: balance::zero(),
            burn_address: @0x0, // TODO
            treasury_address: @0x0, // TODO
            historical_pool_data: vector::empty(),
            pool_data: pooldata,
            next_pool_data: pooldata,
            base_type: base_type_name,
            quote_type: quote_type_name,
        });

        transfer::public_transfer(coin::from_balance(creation_fee, ctx), @0x0); //TODO: update to treasury address
        let pool_key = pool.pool_key();
        transfer::share_object(pool);

        pool_key
    }

    // USER

    public(package) fun increase_user_stake<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        amount: u64,
        ctx: &TxContext
    ): u64 {
        let user = get_user_mut(pool, user, ctx);
        
        user.increase_stake(amount)
    }

    public(package) fun remove_user_stake<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        ctx: &TxContext
    ): (u64, u64) {
        let user = get_user_mut(pool, user, ctx);
        
        user.remove_stake()
    }

    fun get_user_mut<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        ctx: &TxContext
    ): &mut User {
        assert!(pool.users.contains(user), EUserNotFound);

        let user = pool.users.borrow_mut(user);
        user.refresh(ctx);

        user
    }

    // <<<<<<<<<<<<<<<<<<<<<<<< Accessor Functions <<<<<<<<<<<<<<<<<<<<<<<<
    
    /// Get the base and quote asset of pool, return as ascii strings
    public fun get_base_quote_types<BaseAsset, QuoteAsset>(pool: &Pool<BaseAsset, QuoteAsset>): (String, String) {
        (pool.base_type.into_string(), pool.quote_type.into_string())
    }

    /// Get the pool key string base+quote (if base<= quote) otherwise quote+base
    public fun pool_key<BaseAsset, QuoteAsset>(pool: &Pool<BaseAsset, QuoteAsset>): String {
       let (base, quote) = get_base_quote_types(pool);
       if (string_helper::compare_ascii_strings(&base, &quote)) {
           return string_helper::append_strings(&base, &quote)
       };
       string_helper::append_strings(&quote, &base)
    }

    // This will be automatically called if not enough assets in settled_funds
    // User cannot manually deposit
    // Deposit BaseAsset Tokens
    fun deposit<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        amount: u64,
        coin_type: u64, // 0 for base, 1 for quote, 2 for deep
        ctx: &mut TxContext,
    ) {
        // a) Withdraw from user account
        if (coin_type == 0) {
            let coin: Coin<BaseAsset> = deepbookv3::account::withdraw(user_account, amount, ctx);
            let balance: Balance<BaseAsset> = coin.into_balance();
            // b) merge into pool balances
            pool.base_balances.join(balance);
        } else if (coin_type == 1) {
            let coin: Coin<QuoteAsset> = deepbookv3::account::withdraw(user_account, amount, ctx);
            let balance: Balance<QuoteAsset> = coin.into_balance();
            // b) merge into pool balances
            pool.quote_balances.join(balance);
        } else if (coin_type == 2){
            let coin: Coin<DEEP> = deepbookv3::account::withdraw(user_account, amount, ctx);
            let balance: Balance<DEEP> = coin.into_balance();
            // b) merge into pool balances
            pool.deepbook_balance.join(balance);
        }
        // TODO: Update UserData
    }

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

    fun burn<BaseAsset, QuoteAsset>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        fee: Coin<DEEP>,
    ){
        transfer::public_transfer(fee, pool.burn_address)
    }

    fun send_treasury<BaseAsset, QuoteAsset, T>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        fee: Coin<T>,
    ){
        transfer::public_transfer(fee, pool.treasury_address)
    }

    // //for pool we need:
    // set_next_pool_data(Option<PoolData>)

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