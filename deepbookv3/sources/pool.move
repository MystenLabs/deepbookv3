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
    const EIncorrectAccountOwner: u64 = 5;

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

    /// Emitted when a maker order is canceled.
    public struct OrderCanceled<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        /// object ID of the pool the order was placed on
        pool_id: ID,
        /// ID of the order within the pool
        order_id: u64,
        is_bid: bool,
        /// owner ID of the `AccountCap` that canceled the order
        owner: address,
        original_quantity: u64,
        base_asset_quantity_canceled: u64,
        price: u64
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
        next_bid_order_id: u64, // increments for each bid order
        next_ask_order_id: u64, // increments for each ask order
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
	public struct PoolData has copy, store, drop {
        epoch: u64,
        total_maker_volume: u64,
        total_staked_maker_volume: u64,
        total_fees_collected: u64,
        stake_required: u64,
        taker_fee: u64,
        maker_fee: u64,
	}

    public(package) fun new_pool_data(
        ctx: &TxContext,
        total_maker_volume: u64,
        total_staked_maker_volume: u64,
        total_fees_collected: u64,
        stake_required: u64,
        taker_fee: u64,
        maker_fee: u64,
    ): PoolData {
        PoolData {
            epoch: ctx.epoch(),
            total_maker_volume,
            total_staked_maker_volume,
            total_fees_collected,
            stake_required,
            taker_fee,
            maker_fee,
        }
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

        let pooldata = new_pool_data(ctx, 0, 0, 0, 0, taker_fee, maker_fee);

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
        ctx: &mut TxContext
    ): u64 {
        let user = get_user_mut(pool, user, ctx);
        
        user.increase_stake(amount)
    }

    public(package) fun remove_user_stake<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        ctx: &mut TxContext
    ): (u64, u64) {
        let user = get_user_mut(pool, user, ctx);
        
        user.remove_stake()
    }

    public(package) fun get_user_stake<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        ctx: &mut TxContext
    ): (u64, u64) {
        if (!pool.users.contains(user)) {
            return (0, 0)
        };

        let user = get_user_mut(pool, user, ctx);

        user.get_user_stake()
    }

    public(package) fun claim_rebates<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        ctx: &mut TxContext
    ): Coin<DEEP> {
        let user = get_user_mut(pool, user, ctx);
        
        let amount = user.reset_rebates();
        let balance = pool.deepbook_balance.split(amount);
        
        balance.into_coin(ctx)
    }

    fun get_user_mut<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        ctx: &mut TxContext
    ): &mut User {
        assert!(pool.users.contains(user), EUserNotFound);

        let user = pool.users.borrow_mut(user);
        let burn_amount = user.refresh(ctx);
        if (burn_amount > 0) {
            let balance = pool.deepbook_balance.split(burn_amount);
            let coins = balance.into_coin(ctx);
            burn(pool.burn_address, coins);
        };

        user
    }

    // DEEP PRICE

    /// Add a new price point to the pool.
    public(package) fun add_deep_price_point<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        base_conversion_rate: u64,
        quote_conversion_rate: u64,
        timestamp: u64,
    ) {
        pool.deep_config.add_price_point(base_conversion_rate, quote_conversion_rate, timestamp)
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
            let coin: Coin<BaseAsset> = account::withdraw(user_account, amount, ctx);
            let balance: Balance<BaseAsset> = coin.into_balance();
            // b) merge into pool balances
            pool.base_balances.join(balance);
        } else if (coin_type == 1) {
            let coin: Coin<QuoteAsset> = account::withdraw(user_account, amount, ctx);
            let balance: Balance<QuoteAsset> = coin.into_balance();
            // b) merge into pool balances
            pool.quote_balances.join(balance);
        } else if (coin_type == 2){
            let coin: Coin<DEEP> = account::withdraw(user_account, amount, ctx);
            let balance: Balance<DEEP> = coin.into_balance();
            // b) merge into pool balances
            pool.deepbook_balance.join(balance);
        }
        // TODO: Update UserData during order cancel
    }

    // Withdraw settled funds. Tx address has to own the account being withdrawn to.
    public(package) fun withdraw_settled_funds<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        ctx: &mut TxContext,
    ) {
        // Get the valid user information
        let user_data = &mut pool.users[account.get_owner()];
        let (base_amount, quote_amount) = user_data.get_settle_amounts();

        // Take the valid amounts from the pool balances, deposit into user account
        if (base_amount > 0) {
            let base_coin = coin::from_balance(pool.base_balances.split(base_amount), ctx);
            account::deposit(account, base_coin);
        };
        if (quote_amount > 0) {
            let quote_coin = coin::from_balance(pool.quote_balances.split(quote_amount), ctx);
            account::deposit(account, quote_coin);
        };

        // Reset the user's settled amounts
        user_data.reset_settle_amounts(ctx);
    }

    fun burn(
        burn_address: address,
        amount: Coin<DEEP>,
    ) {
        transfer::public_transfer(amount, burn_address)
    }

    fun send_treasury<BaseAsset, QuoteAsset, T>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        fee: Coin<T>,
    ) {
        transfer::public_transfer(fee, pool.treasury_address)
    }

    // First interaction of each epoch processes this state update
    public(package) fun refresh_state<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext,
    ) {
        let current_epoch = ctx.epoch();
        if (pool.pool_data.epoch == current_epoch) return;

        // Update pool data
        pool.historical_pool_data.push_back(pool.pool_data);
        pool.pool_data = pool.next_pool_data;
        pool.pool_data.epoch = current_epoch;
    }

    /// Update the pool's next pool data.
    /// During an epoch refresh, the current pool data is moved to historical pool data.
    /// The next pool data is moved to current pool data.
    public(package) fun set_next_pool_data<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        next_pool_data: Option<PoolData>,
    ) {
        if (next_pool_data.is_some()){
            pool.next_pool_data = *next_pool_data.borrow();
        } else {
            // We reset only the params being changed by proposals to current params
            pool.next_pool_data.taker_fee = pool.pool_data.taker_fee;
            pool.next_pool_data.maker_fee = pool.pool_data.maker_fee;
            pool.next_pool_data.stake_required = pool.pool_data.stake_required;
        };
    }

    public fun mul_place_order<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        is_bid: vector<bool>,
        price: vector<u64>,
        quantity: vector<u64>,
        ctx: &mut TxContext,
    ) {
        // TODO: to implement
    }

    public fun mul_cancel_order<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        ctx: &mut TxContext,
    ) {
        // TODO: to implement
    }

    // Order management
    public fun place_order<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>, 
        account: &mut Account,
        is_bid: bool, // true for bid, false for ask
        price: u64,
        quantity: u64,
        ctx: &mut TxContext,
    ) {
        // Refresh state as necessary if first order of epoch
        refresh_state(pool, ctx);

        let user_data = &mut pool.users[account.get_owner()];
        let (base_amount, quote_amount) = user_data.get_settle_amounts();

        if (is_bid) {
            // Bid

            // Deposit quote asset if there's not enough in custodian
            if (quote_amount < quantity){
                let difference = quantity - quote_amount;
                let coin: Coin<QuoteAsset> = account::withdraw(account, difference, ctx);
                let balance: Balance<QuoteAsset> = coin.into_balance();
                pool.quote_balances.join(balance);
                user_data.set_settle_amounts(false, 0, ctx);
            } else {
                user_data.set_settle_amounts(false, quote_amount - quantity, ctx);
            };
            
            // Create Order
            let order = Order {
                order_id: pool.next_bid_order_id,
                price,
                original_quantity: quantity,
                quantity,
                is_bid: true,
                owner: account.get_owner(),
                expire_timestamp: 0, // TODO
                self_matching_prevention: 0, // TODO
            };

            // TODO: Ignore for now, will insert order into critbit tree, this will change based on new data structure
            let tick_level = borrow_mut_leaf_by_index(&mut pool.bids, price);
            tick_level.open_orders.push_back(order.order_id, order);

            // Increment order id
            pool.next_bid_order_id =  pool.next_bid_order_id + 1;
        } else {
            // Ask

            // Deposit base asset if there's not enough in custodian
            if (base_amount < quantity){
                let difference = quantity - base_amount;
                let coin: Coin<BaseAsset> = account::withdraw(account, difference, ctx);
                let balance: Balance<BaseAsset> = coin.into_balance();
                pool.base_balances.join(balance);
                user_data.set_settle_amounts(true, 0, ctx);
            } else {
                user_data.set_settle_amounts(true, base_amount - quantity, ctx);
            };

            // Create Order
            let order = Order {
                order_id: pool.next_ask_order_id,
                price,
                original_quantity: quantity,
                quantity,
                is_bid: false,
                owner: account.get_owner(),
                expire_timestamp: 0, // TODO
                self_matching_prevention: 0, // TODO
            };

            // TODO: Ignore for now, will insert order into critbit tree, this will change based on new data structure
            let tick_level = borrow_mut_leaf_by_index(&mut pool.asks, price);
            tick_level.open_orders.push_back(order.order_id, order);

            // Increment order id
            pool.next_ask_order_id =  pool.next_ask_order_id + 1;
        }
    }

    public fun cancel_order<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>, 
        account: &mut Account,
        order_id: u64,
        ctx: &mut TxContext,
    ) {
        // TODO: find order in corresponding critbit tree using order_id

        let order_cancelled = Order {
            order_id: 0,
            price: 10,
            original_quantity: 8,
            quantity: 3,
            is_bid: false,
            owner: @0x0, // TODO
            expire_timestamp: 0, // TODO
            self_matching_prevention: 0, // TODO
        };

        if (order_cancelled.is_bid) {
            // deposit quote asset back into user account
            let coin: Coin<QuoteAsset> = coin::from_balance(pool.quote_balances.split(order_cancelled.quantity), ctx);
            account::deposit(account, coin);
        }
        else {
            // deposit base asset back into user account
            let coin: Coin<BaseAsset> = coin::from_balance(pool.base_balances.split(order_cancelled.quantity), ctx);
            account::deposit(account, coin);
        };

        // Emit order cancelled event
        event::emit(OrderCanceled<BaseAsset, QuoteAsset> {
            pool_id: *pool.id.uid_as_inner(), // Get inner id from UID
            order_id: order_cancelled.order_id,
            is_bid: order_cancelled.is_bid,
            owner: order_cancelled.owner,
            original_quantity: order_cancelled.original_quantity,
            base_asset_quantity_canceled: order_cancelled.quantity,
            price: order_cancelled.price
        })
    }

    // // This may include different types of taker/maker orders
    // public(package) fun modify_order() // Support modifying multiple orders
    // public(package) fun get_order()
    // public(package) fun get_all_orders()
    // public(package) fun get_book()
    // public(package) fun get_base_asset()
    // public(package) fun get_quote_asset()
}