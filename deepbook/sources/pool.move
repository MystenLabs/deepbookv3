module deepbook::pool {
    use sui::{
        balance::{Self,Balance},
        table::{Self, Table},
        coin::{Self, Coin},
        sui::SUI,
        event,
    };

    use std::{
        ascii::String,
        type_name::{Self, TypeName},
    };

    use deepbook::{
        pool_state::{Self, PoolState, PoolEpochState},
        deep_price::{Self, DeepPrice},
        account::{Self, Account},
        big_vector::{Self, BigVector},
        string_helper::{Self},
        user::User,
        math::mul,
    };

    // <<<<<<<<<<<<<<<<<<<<<<<< Error Codes <<<<<<<<<<<<<<<<<<<<<<<<
    const EInvalidFee: u64 = 1;
    const ESameBaseAndQuote: u64 = 2;
    const EInvalidTickSize: u64 = 3;
    const EInvalidLotSize: u64 = 4;
    const EInvalidMinSize: u64 = 5;
    const EUserNotFound: u64 = 6;
    const EOrderInvalidTickSize: u64 = 7;
    const EOrderBelowMinimumSize: u64 = 8;
    const EOrderInvalidLotSize: u64 = 9;

    // <<<<<<<<<<<<<<<<<<<<<<<< Constants <<<<<<<<<<<<<<<<<<<<<<<<
    const POOL_CREATION_FEE: u64 = 100 * 1_000_000_000; // 100 SUI, can be updated

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
        min_size: u64,
    }

    /// Emitted when a maker order is injected into the order book.
    public struct OrderPlaced<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        /// object ID of the pool the order was placed on
        pool_id: ID,
        /// ID of the order within the pool
        order_id: u64,
        /// ID of the order defined by client
        client_order_id: u64,
        is_bid: bool,
        /// owner ID of the `AccountCap` that placed the order
        owner: address,
        original_quantity: u64,
        base_asset_quantity_placed: u64,
        price: u64,
        expire_timestamp: u64
    }

    /// Emitted when a maker order is canceled.
    public struct OrderCanceled<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        /// object ID of the pool the order was placed on
        pool_id: ID,
        /// ID of the order within the pool
        order_id: u64,
        /// ID of the order defined by client
        client_order_id: u64,
        is_bid: bool,
        /// owner ID of the `AccountCap` that canceled the order
        owner: address,
        original_quantity: u64,
        base_asset_quantity_canceled: u64,
        price: u64
    }

    // <<<<<<<<<<<<<<<<<<<<<<<< Structs <<<<<<<<<<<<<<<<<<<<<<<<

    // Temporary, remove after on-chain dependency possible
    public struct DEEP has store {}

    public struct Order has store, drop {
        // For each pool, order id is incremental and unique for each opening order.
        // Orders that are submitted earlier has lower order ids.
        // 64 bits are sufficient for order ids whereas 32 bits are not.
        // Assuming a maximum TPS of 100K/s of Sui chain, it would take (1<<63) / 100000 / 3600 / 24 / 365 = 2924712 years to reach the full capacity.
        // The highest bit of the order id is used to denote the order type, 0 for bid, 1 for ask.
        /// ID of the order within the pool
        order_id: u64,
        /// ID of the order defined by client
        client_order_id: u64,
        // Only used for limit orders.
        price: u64,
        // quantity when the order first placed in
        original_quantity: u64,
        // quantity of the order currently held
        quantity: u64,
        original_fee_quantity: u64,
        fee_quantity: u64,
        verified_pool: bool,
        is_bid: bool,
        /// Order can only be canceled by the `AccountCap` with this owner ID
        owner: address,
        // Expiration timestamp in ms.
        expire_timestamp: u64,
        // reserved field for prevent self_matching
        self_matching_prevention: u8
    }

    public struct Pool<phantom BaseAsset, phantom QuoteAsset> has key, store {
        id: UID,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        bids: BigVector<Order>,
        asks: BigVector<Order>,
        next_bid_order_id: u64, // increments for each bid order
        next_ask_order_id: u64, // increments for each ask order
        deep_config: Option<DeepPrice>,
        users: Table<address, User>,

        // Where funds will be held while order is live
        base_balances: Balance<BaseAsset>,
        quote_balances: Balance<QuoteAsset>,
        deepbook_balance: Balance<DEEP>,

        // treasury and burn address
        treasury_address: address, // Input tokens
        burn_address: address, // DEEP tokens

        // Historical, current, and next PoolData.
        pool_state: PoolState,
    }

    /// Creates a new pool for trading, called by state module
    public(package) fun create_pool<BaseAsset, QuoteAsset>(
        taker_fee: u64,
        maker_fee: u64,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        creation_fee: Balance<SUI>,
        ctx: &mut TxContext,
    ): String {
        assert!(creation_fee.value() == POOL_CREATION_FEE, EInvalidFee);

        let base_type_name = type_name::get<BaseAsset>();
        let quote_type_name = type_name::get<QuoteAsset>();

        assert!(tick_size > 0, EInvalidTickSize);
        assert!(lot_size > 0, EInvalidLotSize);
        assert!(min_size > 0, EInvalidMinSize);
        assert!(base_type_name != quote_type_name, ESameBaseAndQuote);
        
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
            min_size,
        });

        let pool = (Pool<BaseAsset, QuoteAsset> {
            id: pool_uid,
            bids: big_vector::empty(10000, 1000, ctx),
            asks: big_vector::empty(10000, 1000, ctx),
            next_bid_order_id: 0,
            next_ask_order_id: 0,
            users: table::new(ctx),
            deep_config: option::none(),
            tick_size,
            lot_size,
            min_size,
            base_balances: balance::zero(),
            quote_balances: balance::zero(),
            deepbook_balance: balance::zero(),
            burn_address: @0x0, // TODO
            treasury_address: @0x0, // TODO
            pool_state: pool_state::new_pool_state(ctx, 0, taker_fee, maker_fee),
        });

        transfer::public_transfer(coin::from_balance(creation_fee, ctx), @0x0); //TODO: update to treasury address
        let pool_key = pool.pool_key();
        transfer::share_object(pool);

        pool_key
    }

    // USER

    /// Increase a user's stake
    public(package) fun increase_user_stake<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        amount: u64,
        ctx: &mut TxContext
    ): u64 {
        let user = get_user_mut(pool, user, ctx);
        
        user.increase_stake(amount)
    }

    /// Removes a user's stake
    public(package) fun remove_user_stake<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        ctx: &mut TxContext
    ): (u64, u64) {
        let user = get_user_mut(pool, user, ctx);
        
        user.remove_stake()
    }

    /// Get the user's (current, next) stake amounts
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

    /// Claim the rebates for the user
    public fun claim_rebates<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        ctx: &mut TxContext
    ): Coin<DEEP> {
        let user = get_user_mut(pool, ctx.sender(), ctx);
        
        let amount = user.reset_rebates();
        let balance = pool.deepbook_balance.split(amount);
        
        balance.into_coin(ctx)
    }

    /// Get the user object, refresh the user, and burn the DEEP tokens if necessary
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

    /// Add a new price point to the pool.
    public(package) fun add_deep_price_point<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        base_conversion_rate: u64,
        quote_conversion_rate: u64,
        timestamp: u64,
    ) {
        if (pool.deep_config.is_none()) {
            pool.deep_config = option::some(deep_price::initialize());
        };
        let config = pool.deep_config.borrow_mut();
        config.add_price_point(base_conversion_rate, quote_conversion_rate, timestamp);
    }

    /// This will be automatically called if not enough assets in settled_funds for a trade
    /// User cannot manually deposit
    /// Deposit BaseAsset, QuoteAsset, Deepbook Tokens
    fun deposit<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        amount: u64,
        coin_type: u64, // 0 for base, 1 for quote, 2 for deep. TODO: use enum
        ctx: &mut TxContext,
    ) {
        // Withdraw from user account and merge into pool balances
        if (coin_type == 0) {
            let coin: Coin<BaseAsset> = account::withdraw(user_account, amount, ctx);
            pool.base_balances.join(coin.into_balance());
        } else if (coin_type == 1) {
            let coin: Coin<QuoteAsset> = account::withdraw(user_account, amount, ctx);
            pool.quote_balances.join(coin.into_balance());
        } else if (coin_type == 2){
            let coin: Coin<DEEP> = account::withdraw(user_account, amount, ctx);
            pool.deepbook_balance.join(coin.into_balance());
        }
    }

    /// This will be automatically called when order is cancelled
    /// User cannot manually withdraw
    /// Withdraw BaseAsset, QuoteAsset, Deepbook Tokens
    fun withdraw<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        amount: u64,
        coin_type: u64, // 0 for base, 1 for quote, 2 for deep. TODO: use enum
        ctx: &mut TxContext,
    ) {
        // Withdraw from pool balances and deposit into user account
        if (coin_type == 0) {
            let coin: Coin<BaseAsset> = coin::from_balance(pool.base_balances.split(amount), ctx);
            user_account.deposit(coin);
        } else if (coin_type == 1) {
            let coin: Coin<QuoteAsset> = coin::from_balance(pool.quote_balances.split(amount), ctx);
            user_account.deposit(coin);
        } else if (coin_type == 2){
            let coin: Coin<DEEP> = coin::from_balance(pool.deepbook_balance.split(amount), ctx);
            user_account.deposit(coin);
        };
    }

    /// Withdraw settled funds. Account is an owned object
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
            account.deposit(base_coin);
        };
        if (quote_amount > 0) {
            let quote_coin = coin::from_balance(pool.quote_balances.split(quote_amount), ctx);
            account.deposit(quote_coin);
        };

        // Reset the user's settled amounts
        user_data.reset_settle_amounts(ctx);
    }

    /// Burn DEEP tokens
    fun burn(
        burn_address: address,
        amount: Coin<DEEP>,
    ) {
        transfer::public_transfer(amount, burn_address)
    }

    #[allow(unused_function)]
    /// Send fees collected in input tokens to treasury
    fun send_treasury<BaseAsset, QuoteAsset, T>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        fee: Coin<T>,
    ) {
        transfer::public_transfer(fee, pool.treasury_address)
    }

    /// First interaction of each epoch processes this state update
    public(package) fun refresh_state<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext,
    ) {
        pool.pool_state.refresh_state(ctx);
    }

    /// Update the pool's next pool state.
    /// During an epoch refresh, the current pool state is moved to historical pool state.
    /// The next pool state is moved to current pool state.
    public(package) fun set_next_epoch_pool_state<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        next_epoch_pool_state: Option<PoolEpochState>,
    ) {
        pool.pool_state.set_next_epoch_pool_state(next_epoch_pool_state);
    }

    #[allow(unused_function, unused_variable)]
    /// Allow placing of multiple orders, input can be adjusted
    public fun mul_place_order<BaseAsset, QuoteAsset>(
        _pool: &mut Pool<BaseAsset, QuoteAsset>,
        _account: &mut Account,
        _is_bid: vector<bool>,
        _price: vector<u64>,
        _quantity: vector<u64>,
        _ctx: &mut TxContext,
    ) {
        // TODO: to implement
    }

    #[allow(unused_function, unused_variable)]
    /// Allow canceling of multiple orders
    public fun mul_cancel_order<BaseAsset, QuoteAsset>(
        _pool: &mut Pool<BaseAsset, QuoteAsset>,
        _account: &mut Account,
        _ctx: &mut TxContext,
    ) {
        // TODO: to implement
    }

    /// Place a maker order
    public fun place_maker_order<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>, 
        account: &mut Account,
        client_order_id: u64,
        price: u64,
        quantity: u64,
        is_bid: bool, // true for bid, false for ask
        ctx: &mut TxContext,
    ) {
        // Refresh state as necessary if first order of epoch
        refresh_state(pool, ctx);

        assert!(price % pool.tick_size == 0, EOrderInvalidTickSize);
        // Check quantity is above minimum quantity (in base asset)
        assert!(quantity >= pool.min_size, EOrderBelowMinimumSize);
        assert!(quantity % pool.lot_size == 0, EOrderInvalidLotSize);

        let maker_fee = pool.pool_state.get_maker_fee();
        let mut fee_quantity;
        let mut place_quantity = quantity;
        // If verified pool with source
        if (pool.is_verified()) {
            let config = pool.deep_config.borrow();
            // quantity is always in terms of base asset
            // TODO: option to use deep_per_quote if base not available
            // TODO: make sure there is mul_down and mul_up for rounding
            let deep_quantity = mul(config.deep_per_base(), quantity);
            fee_quantity = mul(deep_quantity, maker_fee);
            // Deposit the deepbook fees
            deposit(pool, account, fee_quantity, 2, ctx);
        }
        // If unverified pool
        else {
            fee_quantity = mul(quantity, maker_fee); // if q = 100, fee = 0.1, fee_q = 10 (in base assets)
            place_quantity = place_quantity - fee_quantity; // if q = 100, fee_q = 10, place_q = 90 (in base assets)
            if (is_bid) {
                fee_quantity = mul(fee_quantity, price); // if price = 5, fee_q = 50 (in quote assets)
                // deposit quote asset fees
                deposit(pool, account, fee_quantity, 1, ctx);
            } else {
                // deposit base asset fees
                deposit(pool, account, fee_quantity, 0, ctx);
            };
        };

        let user_data = &mut pool.users[account.get_owner()];
        let (available_base_amount, available_quote_amount) = user_data.get_settle_amounts();

        if (is_bid) {
            // Deposit quote asset if there's not enough in custodian
            let quote_quantity = mul(quantity, price);
            if (available_quote_amount < quantity){
                let difference = quote_quantity - available_quote_amount;
                let coin: Coin<QuoteAsset> = account::withdraw(account, difference, ctx);
                let balance: Balance<QuoteAsset> = coin.into_balance();
                pool.quote_balances.join(balance);
                user_data.set_settle_amounts(option::none(), option::some(0), ctx);
            } else {
                user_data.set_settle_amounts(option::none(), option::some(available_quote_amount - quote_quantity), ctx);
            };
        } else {
            // Deposit base asset if there's not enough in custodian
            if (available_base_amount < quantity){
                let difference = quantity - available_base_amount;
                let coin: Coin<BaseAsset> = account::withdraw(account, difference, ctx);
                let balance: Balance<BaseAsset> = coin.into_balance();
                pool.base_balances.join(balance);
                user_data.set_settle_amounts(option::some(0), option::none(), ctx);
            } else {
                user_data.set_settle_amounts(option::some(available_base_amount - quantity), option::none(), ctx);
            };
        };

        place_maker_order_int(pool, client_order_id, price, place_quantity, fee_quantity, is_bid, ctx);
        event::emit(OrderPlaced<BaseAsset, QuoteAsset> {
            pool_id: *object::uid_as_inner(&pool.id),
            order_id: 0,
            client_order_id,
            is_bid,
            owner: account.get_owner(),
            original_quantity: quantity,
            base_asset_quantity_placed: quantity,
            price,
            expire_timestamp: 0, // TODO
        });
    }

    /// Balance accounting happens before this function is called
    fun place_maker_order_int<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>, 
        client_order_id: u64,
        price: u64,
        quantity: u64,
        fee_quantity: u64,
        is_bid: bool, // true for bid, false for ask
        ctx: &TxContext,
    ) {
        // Create Order
        let _order = Order {
            order_id: pool.next_bid_order_id,
            client_order_id,
            price,
            original_quantity: quantity,
            quantity,
            original_fee_quantity: fee_quantity,
            fee_quantity,
            verified_pool: pool.is_verified(),
            is_bid,
            owner: ctx.sender(),
            expire_timestamp: 0, // TODO
            self_matching_prevention: 0, // TODO
        };

        if (is_bid){
            // TODO: Place ask order into BigVec

            // Increment order id
            pool.next_bid_order_id =  pool.next_bid_order_id + 1;
        } else {
            // TODO: Place ask order into BigVec

            // Increment order id
            pool.next_ask_order_id =  pool.next_ask_order_id + 1;
        }
    }

    #[allow(unused_function, unused_variable)]
    public fun swap_exact_base_for_quote<BaseAsset, QuoteAsset>(
        _pool: &mut Pool<BaseAsset, QuoteAsset>,
        _client_order_id: u64,
        _account: &mut Account,
        _quantity: u64,
        _clock: u64, // TODO, update to Clock
        _ctx: &mut TxContext,
    ) {
        // To implement
    }

    #[allow(unused_function, unused_variable)]
    /// cancels an order by id
    public fun cancel_order<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>, 
        account: &mut Account,
        order_id: u64, // use this to find order
        ctx: &mut TxContext,
    ) {
        // TODO: find order in corresponding BigVec using client_order_id
        // Sample order that is cancelled
        let order_cancelled = Order {
            order_id: 0,
            client_order_id: 0,
            price: 10000,
            original_quantity: 8000,
            quantity: 3000,
            original_fee_quantity: 80,
            fee_quantity: 30,
            verified_pool: true,
            is_bid: false,
            owner: @0x0, // TODO
            expire_timestamp: 0, // TODO
            self_matching_prevention: 0, // TODO
        };

        // withdraw main assets back into user account
        if (order_cancelled.is_bid) {
            // deposit quote asset back into user account
            let quote_asset_quantity = mul(order_cancelled.quantity, order_cancelled.price);
            withdraw(pool, account, quote_asset_quantity, 1, ctx)
        } else {
            // deposit base asset back into user account
            withdraw(pool, account, order_cancelled.quantity, 0, ctx)
        };

        // withdraw fees into user account
        // if pool is verified at the time of order placement, fees are in deepbook tokens
        if (order_cancelled.verified_pool) {
            // withdraw deepbook fees
            withdraw(pool, account, order_cancelled.fee_quantity, 2, ctx)
        } else if (order_cancelled.is_bid) {
            // withdraw quote asset fees
            // can be combined with withdrawal above, separate now for clarity
            withdraw(pool, account, order_cancelled.fee_quantity, 1, ctx)
        } else {
            // withdraw base asset fees
            // can be combined with withdrawal above, separate now for clarity
            withdraw(pool, account, order_cancelled.fee_quantity, 0, ctx)
        };

        // Emit order cancelled event
        event::emit(OrderCanceled<BaseAsset, QuoteAsset> {
            pool_id: *pool.id.uid_as_inner(), // Get inner id from UID
            order_id: order_cancelled.order_id,
            client_order_id: order_cancelled.client_order_id,
            is_bid: order_cancelled.is_bid,
            owner: order_cancelled.owner,
            original_quantity: order_cancelled.original_quantity,
            base_asset_quantity_canceled: order_cancelled.quantity,
            price: order_cancelled.price
        })
    }

    // <<<<<<<<<<<<<<<<<<<<<<<< Helper Functions <<<<<<<<<<<<<<<<<<<<<<<<

    public fun is_verified<BaseAsset, QuoteAsset>(pool: &Pool<BaseAsset, QuoteAsset>): bool {
        pool.deep_config.is_some()
    }

    // <<<<<<<<<<<<<<<<<<<<<<<< Accessor Functions <<<<<<<<<<<<<<<<<<<<<<<<
    
    /// Get the base and quote asset of pool, return as ascii strings
    public fun get_base_quote_types<BaseAsset, QuoteAsset>(_pool: &Pool<BaseAsset, QuoteAsset>): (String, String) {
        (type_name::get<BaseAsset>().into_string(), type_name::get<QuoteAsset>().into_string())
    }

    /// Get the pool key string base+quote (if base, quote in lexicographic order) otherwise return quote+base
    public fun pool_key<BaseAsset, QuoteAsset>(pool: &Pool<BaseAsset, QuoteAsset>): String {
       let (base, quote) = get_base_quote_types(pool);
       if (string_helper::compare_ascii_strings(&base, &quote)) {
           return string_helper::append_strings(&base, &quote)
       };
       string_helper::append_strings(&quote, &base)
    }

    // // Other helpful functions
    // TODO: taker order, send fees directly to treasury
    // public(package) fun modify_order()
    // public(package) fun get_order()
    // public(package) fun get_all_orders()
    // public(package) fun get_book()
}