
<a name="0x0_pool"></a>

# Module `0x0::pool`



-  [Struct `PoolCreated`](#0x0_pool_PoolCreated)
-  [Struct `DEEP`](#0x0_pool_DEEP)
-  [Resource `Pool`](#0x0_pool_Pool)
-  [Constants](#@Constants_0)
-  [Function `place_limit_order`](#0x0_pool_place_limit_order)
-  [Function `calculate_trade_balances`](#0x0_pool_calculate_trade_balances)
-  [Function `settle_user`](#0x0_pool_settle_user)
-  [Function `match_against_book`](#0x0_pool_match_against_book)
-  [Function `place_market_order`](#0x0_pool_place_market_order)
-  [Function `modify_order`](#0x0_pool_modify_order)
-  [Function `swap_exact_amount`](#0x0_pool_swap_exact_amount)
-  [Function `mid_price`](#0x0_pool_mid_price)
-  [Function `get_amount_out`](#0x0_pool_get_amount_out)
-  [Function `get_level2_range`](#0x0_pool_get_level2_range)
-  [Function `get_level2_ticks_from_mid`](#0x0_pool_get_level2_ticks_from_mid)
-  [Function `cancel_order`](#0x0_pool_cancel_order)
-  [Function `claim_rebates`](#0x0_pool_claim_rebates)
-  [Function `cancel_all`](#0x0_pool_cancel_all)
-  [Function `user_open_orders`](#0x0_pool_user_open_orders)
-  [Function `create_pool`](#0x0_pool_create_pool)
-  [Function `whitelist_pool`](#0x0_pool_whitelist_pool)
-  [Function `set_stable`](#0x0_pool_set_stable)
-  [Function `deep_whitelisted`](#0x0_pool_deep_whitelisted)
-  [Function `stake`](#0x0_pool_stake)
-  [Function `unstake`](#0x0_pool_unstake)
-  [Function `submit_proposal`](#0x0_pool_submit_proposal)
-  [Function `vote`](#0x0_pool_vote)
-  [Function `get_user_stake`](#0x0_pool_get_user_stake)
-  [Function `add_deep_price_point`](#0x0_pool_add_deep_price_point)
-  [Function `get_base_quote_types`](#0x0_pool_get_base_quote_types)
-  [Function `share`](#0x0_pool_share)
-  [Function `send_treasury`](#0x0_pool_send_treasury)
-  [Function `inject_limit_order`](#0x0_pool_inject_limit_order)
-  [Function `order_is_bid`](#0x0_pool_order_is_bid)
-  [Function `get_order_id`](#0x0_pool_get_order_id)
-  [Function `get_level2_range_and_ticks`](#0x0_pool_get_level2_range_and_ticks)
-  [Function `get_conversion_rates`](#0x0_pool_get_conversion_rates)
-  [Function `correct_supply`](#0x0_pool_correct_supply)


<pre><code><b>use</b> <a href="account.md#0x0_account">0x0::account</a>;
<b>use</b> <a href="big_vector.md#0x0_big_vector">0x0::big_vector</a>;
<b>use</b> <a href="deep_price.md#0x0_deep_price">0x0::deep_price</a>;
<b>use</b> <a href="governance.md#0x0_governance">0x0::governance</a>;
<b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="order.md#0x0_order">0x0::order</a>;
<b>use</b> <a href="registry.md#0x0_registry">0x0::registry</a>;
<b>use</b> <a href="state_manager.md#0x0_state_manager">0x0::state_manager</a>;
<b>use</b> <a href="utils.md#0x0_utils">0x0::utils</a>;
<b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
<b>use</b> <a href="dependencies/move-stdlib/type_name.md#0x1_type_name">0x1::type_name</a>;
<b>use</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">0x2::balance</a>;
<b>use</b> <a href="dependencies/sui-framework/clock.md#0x2_clock">0x2::clock</a>;
<b>use</b> <a href="dependencies/sui-framework/coin.md#0x2_coin">0x2::coin</a>;
<b>use</b> <a href="dependencies/sui-framework/event.md#0x2_event">0x2::event</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
<b>use</b> <a href="dependencies/sui-framework/sui.md#0x2_sui">0x2::sui</a>;
<b>use</b> <a href="dependencies/sui-framework/transfer.md#0x2_transfer">0x2::transfer</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
<b>use</b> <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set">0x2::vec_set</a>;
</code></pre>



<a name="0x0_pool_PoolCreated"></a>

## Struct `PoolCreated`

Emitted when a new pool is created


<pre><code><b>struct</b> <a href="pool.md#0x0_pool_PoolCreated">PoolCreated</a>&lt;BaseAsset, QuoteAsset&gt; <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>
 object ID of the newly created pool
</dd>
<dt>
<code>taker_fee: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>maker_fee: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>tick_size: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>lot_size: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>min_size: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_pool_DEEP"></a>

## Struct `DEEP`

Temporary to represent DEEP token, remove after we have the open-sourced the DEEP token contract


<pre><code><b>struct</b> <a href="pool.md#0x0_pool_DEEP">DEEP</a> <b>has</b> store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>dummy_field: bool</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_pool_Pool"></a>

## Resource `Pool`

Pool holds everything related to the pool. next_bid_order_id increments for each bid order,
next_ask_order_id decrements for each ask order. All funds for live orders and settled funds
are held in base_balance, quote_balance, and deep_balance.


<pre><code><b>struct</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt; <b>has</b> key
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>id: <a href="dependencies/sui-framework/object.md#0x2_object_UID">object::UID</a></code>
</dt>
<dd>

</dd>
<dt>
<code>tick_size: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>lot_size: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>min_size: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>bids: <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;<a href="order.md#0x0_order_Order">order::Order</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>asks: <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;<a href="order.md#0x0_order_Order">order::Order</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>next_bid_order_id: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>next_ask_order_id: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>deep_config: <a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a></code>
</dt>
<dd>

</dd>
<dt>
<code>deep_whitelisted: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>stable: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>base_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;BaseAsset&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>quote_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;QuoteAsset&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>deep_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;<a href="pool.md#0x0_pool_DEEP">pool::DEEP</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>vault: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;<a href="pool.md#0x0_pool_DEEP">pool::DEEP</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code><a href="state_manager.md#0x0_state_manager">state_manager</a>: <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a></code>
</dt>
<dd>

</dd>
<dt>
<code><a href="governance.md#0x0_governance">governance</a>: <a href="governance.md#0x0_governance_Governance">governance::Governance</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_pool_MAX_PRICE"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_MAX_PRICE">MAX_PRICE</a>: u64 = 4611686018427387904;
</code></pre>



<a name="0x0_pool_MIN_PRICE"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_MIN_PRICE">MIN_PRICE</a>: u64 = 1;
</code></pre>



<a name="0x0_pool_MAX_U64"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_MAX_U64">MAX_U64</a>: u64 = 9223372036854775808;
</code></pre>



<a name="0x0_pool_EEmptyOrderbook"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EEmptyOrderbook">EEmptyOrderbook</a>: u64 = 9;
</code></pre>



<a name="0x0_pool_EIneligibleReferencePool"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EIneligibleReferencePool">EIneligibleReferencePool</a>: u64 = 12;
</code></pre>



<a name="0x0_pool_EIneligibleTargetPool"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EIneligibleTargetPool">EIneligibleTargetPool</a>: u64 = 11;
</code></pre>



<a name="0x0_pool_EIneligibleWhitelist"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EIneligibleWhitelist">EIneligibleWhitelist</a>: u64 = 10;
</code></pre>



<a name="0x0_pool_EInvalidAmountIn"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidAmountIn">EInvalidAmountIn</a>: u64 = 8;
</code></pre>



<a name="0x0_pool_EInvalidFee"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidFee">EInvalidFee</a>: u64 = 1;
</code></pre>



<a name="0x0_pool_EInvalidLotSize"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidLotSize">EInvalidLotSize</a>: u64 = 4;
</code></pre>



<a name="0x0_pool_EInvalidMinSize"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidMinSize">EInvalidMinSize</a>: u64 = 5;
</code></pre>



<a name="0x0_pool_EInvalidPriceRange"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidPriceRange">EInvalidPriceRange</a>: u64 = 6;
</code></pre>



<a name="0x0_pool_EInvalidTickSize"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidTickSize">EInvalidTickSize</a>: u64 = 3;
</code></pre>



<a name="0x0_pool_EInvalidTicks"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidTicks">EInvalidTicks</a>: u64 = 7;
</code></pre>



<a name="0x0_pool_ENotEnoughStake"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_ENotEnoughStake">ENotEnoughStake</a>: u64 = 13;
</code></pre>



<a name="0x0_pool_ESameBaseAndQuote"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_ESameBaseAndQuote">ESameBaseAndQuote</a>: u64 = 2;
</code></pre>



<a name="0x0_pool_MIN_ASK_ORDER_ID"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_MIN_ASK_ORDER_ID">MIN_ASK_ORDER_ID</a>: u128 = 170141183460469231731687303715884105728;
</code></pre>



<a name="0x0_pool_POOL_CREATION_FEE"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_POOL_CREATION_FEE">POOL_CREATION_FEE</a>: u64 = 100000000000;
</code></pre>



<a name="0x0_pool_STAKE_REQUIRED_TO_PARTICIPATE"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_STAKE_REQUIRED_TO_PARTICIPATE">STAKE_REQUIRED_TO_PARTICIPATE</a>: u64 = 100;
</code></pre>



<a name="0x0_pool_START_ASK_ORDER_ID"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_START_ASK_ORDER_ID">START_ASK_ORDER_ID</a>: u64 = 1;
</code></pre>



<a name="0x0_pool_START_BID_ORDER_ID"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_START_BID_ORDER_ID">START_BID_ORDER_ID</a>: u64 = 9223372036854775808;
</code></pre>



<a name="0x0_pool_TREASURY_ADDRESS"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_TREASURY_ADDRESS">TREASURY_ADDRESS</a>: <b>address</b> = 0;
</code></pre>



<a name="0x0_pool_place_limit_order"></a>

## Function `place_limit_order`

Place a limit order to the order book.
1. Transfer any settled funds from the pool to the account.
2. Match the order against the order book if possible.
3. Transfer balances for the executed quantity as well as the remaining quantity.
4. Assert for any order restrictions.
5. If there is remaining quantity, inject the order into the order book.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_place_limit_order">place_limit_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, client_order_id: u64, order_type: u8, price: u64, quantity: u64, is_bid: bool, expire_timestamp: u64, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_place_limit_order">place_limit_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    client_order_id: u64,
    order_type: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    expire_timestamp: u64,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &TxContext,
): OrderInfo {
    <b>let</b> order_id = <a href="utils.md#0x0_utils_encode_order_id">utils::encode_order_id</a>(is_bid, price, self.<a href="pool.md#0x0_pool_get_order_id">get_order_id</a>(is_bid));
    <b>let</b> fee_is_deep = self.deep_config.verified();
    <b>let</b> owner = <a href="account.md#0x0_account">account</a>.owner();
    <b>let</b> pool_id = self.id.to_inner();
    <b>let</b> <b>mut</b> order_info =
        <a href="order.md#0x0_order_initial_order">order::initial_order</a>(pool_id, order_id, client_order_id, order_type, price, quantity, fee_is_deep, is_bid, owner, expire_timestamp);
    order_info.validate_inputs(self.tick_size, self.min_size, self.lot_size, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms());
    self.<a href="pool.md#0x0_pool_match_against_book">match_against_book</a>(&<b>mut</b> order_info, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>);

    self.<a href="pool.md#0x0_pool_calculate_trade_balances">calculate_trade_balances</a>(<a href="account.md#0x0_account">account</a>.owner(), &<b>mut</b> order_info);

    order_info.assert_post_only();
    order_info.assert_fill_or_kill();
    <b>if</b> (order_info.is_immediate_or_cancel() || order_info.original_quantity() == order_info.executed_quantity()) {
        <b>return</b> order_info
    };

    <b>if</b> (order_info.remaining_quantity() &gt; 0) {
        self.<a href="pool.md#0x0_pool_inject_limit_order">inject_limit_order</a>(&order_info);
    };

    self.<a href="pool.md#0x0_pool_settle_user">settle_user</a>(<a href="account.md#0x0_account">account</a>, proof, ctx);

    order_info
}
</code></pre>



</details>

<a name="0x0_pool_calculate_trade_balances"></a>

## Function `calculate_trade_balances`

Given an order, transfer the appropriate balances. Up until this point, any partial fills have been executed
and the remaining quantity is the only quantity left to be injected into the order book.
1. Transfer the taker balances while applying taker fees.
2. Transfer the maker balances while applying maker fees.
3. Update the total fees for the order.


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_calculate_trade_balances">calculate_trade_balances</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user: <b>address</b>, order_info: &<b>mut</b> <a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_calculate_trade_balances">calculate_trade_balances</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    user: <b>address</b>,
    order_info: &<b>mut</b> OrderInfo,
) {
    <b>let</b> (<b>mut</b> base_in, <b>mut</b> base_out) = (0, 0);
    <b>let</b> (<b>mut</b> quote_in, <b>mut</b> quote_out) = (0, 0);
    <b>let</b> <b>mut</b> deep_in = 0;
    <b>let</b> (taker_fee, maker_fee) = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.fees_for_user(user);
    <b>let</b> executed_quantity = order_info.executed_quantity();
    <b>let</b> remaining_quantity = order_info.remaining_quantity();
    <b>let</b> cumulative_quote_quantity = order_info.cumulative_quote_quantity();

    // Calculate the taker balances. These are derived from executed quantity.
    <b>let</b> (base_fee, quote_fee, deep_fee) = <b>if</b> (order_info.is_bid()) {
        self.deep_config.calculate_fees(taker_fee, 0, cumulative_quote_quantity)
    } <b>else</b> {
        self.deep_config.calculate_fees(taker_fee, executed_quantity, 0)
    };
    <b>let</b> <b>mut</b> total_fees = base_fee + quote_fee + deep_fee;
    deep_in = deep_in + deep_fee;
    <b>if</b> (order_info.is_bid()) {
        quote_in = quote_in + cumulative_quote_quantity + quote_fee;
        base_out = base_out + executed_quantity;
    } <b>else</b> {
        base_in = base_in + executed_quantity + base_fee;
        quote_out = quote_out + cumulative_quote_quantity;
    };

    // Calculate the maker balances. These are derived from the remaining quantity.
    <b>let</b> (base_fee, quote_fee, deep_fee) = <b>if</b> (order_info.is_bid()) {
        self.deep_config.calculate_fees(maker_fee, 0, <a href="math.md#0x0_math_mul">math::mul</a>(remaining_quantity, order_info.price()))
    } <b>else</b> {
        self.deep_config.calculate_fees(maker_fee, remaining_quantity, 0)
    };
    total_fees = total_fees + base_fee + quote_fee + deep_fee;
    deep_in = deep_in + deep_fee;
    <b>if</b> (order_info.is_bid()) {
        quote_in = quote_in + <a href="math.md#0x0_math_mul">math::mul</a>(remaining_quantity, order_info.price()) + quote_fee;
    } <b>else</b> {
        base_in = base_in + remaining_quantity + base_fee;
    };

    order_info.set_total_fees(total_fees);

    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.add_owed_amounts(user, base_in, quote_in, deep_in);
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.add_settled_amounts(user, base_out, quote_out, 0);
}
</code></pre>



</details>

<a name="0x0_pool_settle_user"></a>

## Function `settle_user`

Transfer any settled amounts for the user.


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_settle_user">settle_user</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_settle_user">settle_user</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    ctx: &TxContext,
) {
    <b>let</b> (base_out, quote_out, deep_out, base_in, quote_in, deep_in) = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.<a href="pool.md#0x0_pool_settle_user">settle_user</a>(<a href="account.md#0x0_account">account</a>.owner(), ctx.epoch());
    <b>if</b> (base_out &gt; base_in) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = self.base_balance.split(base_out - base_in);
        <a href="account.md#0x0_account">account</a>.deposit_with_proof(proof, <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (quote_out &gt; quote_in) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = self.quote_balance.split(quote_out - quote_in);
        <a href="account.md#0x0_account">account</a>.deposit_with_proof(proof, <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (deep_out &gt; deep_in) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = self.deep_balance.split(deep_out - deep_in);
        <a href="account.md#0x0_account">account</a>.deposit_with_proof(proof, <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (base_in &gt; base_out) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = <a href="account.md#0x0_account">account</a>.withdraw_with_proof(proof, base_in - base_out, <b>false</b>);
        self.base_balance.join(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (quote_in &gt; quote_out) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = <a href="account.md#0x0_account">account</a>.withdraw_with_proof(proof, quote_in - quote_out, <b>false</b>);
        self.quote_balance.join(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
    <b>if</b> (deep_in &gt; deep_out) {
        <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = <a href="account.md#0x0_account">account</a>.withdraw_with_proof(proof, deep_in - deep_out, <b>false</b>);
        self.deep_balance.join(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    };
}
</code></pre>



</details>

<a name="0x0_pool_match_against_book"></a>

## Function `match_against_book`

Matches the given order and quantity against the order book.
If is_bid, it will match against asks, otherwise against bids.
Mutates the order and the maker order as necessary.


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_match_against_book">match_against_book</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, order_info: &<b>mut</b> <a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_match_against_book">match_against_book</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    order_info: &<b>mut</b> OrderInfo,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
) {
    <b>let</b> is_bid = order_info.is_bid();
    <b>let</b> book_side = <b>if</b> (is_bid) &<b>mut</b> self.asks <b>else</b> &<b>mut</b> self.bids;
    <b>let</b> (<b>mut</b> ref, <b>mut</b> offset) = <b>if</b> (is_bid) book_side.min_slice() <b>else</b> book_side.max_slice();

    <b>let</b> <b>mut</b> fills = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[];

    <b>while</b> (!ref.is_null()) {
        <b>let</b> maker_order = &<b>mut</b> book_side.borrow_slice_mut(ref)[offset];
        <b>if</b> (!order_info.crosses_price(maker_order)) <b>break</b>;
        fills.push_back(order_info.match_maker(maker_order, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms()));

        // Traverse <b>to</b> valid next <a href="order.md#0x0_order">order</a> <b>if</b> exists, otherwise <b>break</b> from <b>loop</b>.
        (ref, offset) = <b>if</b> (is_bid) book_side.next_slice(ref, offset) <b>else</b> book_side.prev_slice(ref, offset);
    };

    // Iterate over fills and process them.
    <b>let</b> <b>mut</b> i = 0;
    <b>while</b> (i &lt; fills.length()) {
        <b>let</b> (order_id, _, expired, complete) = fills[i].fill_status();
        <b>if</b> (expired || complete) {
            book_side.remove(order_id);
        };
        self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.process_fill(&fills[i]);
        i = i + 1;
    };
}
</code></pre>



</details>

<a name="0x0_pool_place_market_order"></a>

## Function `place_market_order`

Place a market order. Quantity is in base asset terms. Calls place_limit_order with
a price of MAX_PRICE for bids and MIN_PRICE for asks. Fills or kills the order.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_place_market_order">place_market_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, client_order_id: u64, quantity: u64, is_bid: bool, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_place_market_order">place_market_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    client_order_id: u64,
    quantity: u64,
    is_bid: bool,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &TxContext,
): OrderInfo {
    self.<a href="pool.md#0x0_pool_place_limit_order">place_limit_order</a>(
        <a href="account.md#0x0_account">account</a>,
        proof,
        client_order_id,
        <a href="order.md#0x0_order_fill_or_kill">order::fill_or_kill</a>(),
        <b>if</b> (is_bid) <a href="pool.md#0x0_pool_MAX_PRICE">MAX_PRICE</a> <b>else</b> <a href="pool.md#0x0_pool_MIN_PRICE">MIN_PRICE</a>,
        quantity,
        is_bid,
        <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms(),
        <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>,
        ctx,
    )
}
</code></pre>



</details>

<a name="0x0_pool_modify_order"></a>

## Function `modify_order`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_modify_order">modify_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, order_id: u128, new_quantity: u64, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_modify_order">modify_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    order_id: u128,
    new_quantity: u64,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &TxContext,
) {
    <b>let</b> (is_bid, _, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(order_id);
    <b>let</b> <a href="order.md#0x0_order">order</a> = <b>if</b> (is_bid) {
        self.bids.borrow_mut(order_id)
    } <b>else</b> {
        self.asks.borrow_mut(order_id)
    };
    <b>let</b> book_quantity = <a href="order.md#0x0_order">order</a>.book_quantity();

    <a href="order.md#0x0_order">order</a>.validate_modification(
        book_quantity,
        new_quantity,
        self.min_size,
        self.lot_size,
        <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms(),
    );

    // Pass in quantity cancelled <b>to</b> calculate refund amounts and modify the <a href="order.md#0x0_order">order</a>
    <b>let</b> (base_quantity, quote_quantity, deep_quantity) = <a href="order.md#0x0_order">order</a>.cancel_amounts(book_quantity - new_quantity, <b>true</b>);
    <a href="order.md#0x0_order">order</a>.emit_order_modified&lt;BaseAsset, QuoteAsset&gt;(self.id.to_inner(), <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms());

    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.add_settled_amounts(<a href="account.md#0x0_account">account</a>.owner(), base_quantity, quote_quantity, deep_quantity);
    self.<a href="pool.md#0x0_pool_settle_user">settle_user</a>(<a href="account.md#0x0_account">account</a>, proof, ctx);
}
</code></pre>



</details>

<a name="0x0_pool_swap_exact_amount"></a>

## Function `swap_exact_amount`

Swap exact amount without needing an account.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_swap_exact_amount">swap_exact_amount</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, base_in: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;BaseAsset&gt;, quote_in: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;QuoteAsset&gt;, deep_in: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;<a href="pool.md#0x0_pool_DEEP">pool::DEEP</a>&gt;, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (<a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;BaseAsset&gt;, <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;QuoteAsset&gt;, <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;<a href="pool.md#0x0_pool_DEEP">pool::DEEP</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_swap_exact_amount">swap_exact_amount</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    base_in: Coin&lt;BaseAsset&gt;,
    quote_in: Coin&lt;QuoteAsset&gt;,
    deep_in: Coin&lt;<a href="pool.md#0x0_pool_DEEP">DEEP</a>&gt;,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &<b>mut</b> TxContext,
): (Coin&lt;BaseAsset&gt;, Coin&lt;QuoteAsset&gt;, Coin&lt;<a href="pool.md#0x0_pool_DEEP">DEEP</a>&gt;) {
    <b>let</b> <b>mut</b> base_quantity = base_in.value();
    <b>let</b> <b>mut</b> quote_quantity = quote_in.value();
    <b>assert</b>!(base_quantity &gt; 0 || quote_quantity &gt; 0, <a href="pool.md#0x0_pool_EInvalidAmountIn">EInvalidAmountIn</a>);
    <b>assert</b>!(base_quantity &gt; 0 && quote_quantity &gt; 0, <a href="pool.md#0x0_pool_EInvalidAmountIn">EInvalidAmountIn</a>);

    <b>let</b> <b>mut</b> temp_account = <a href="account.md#0x0_account_new">account::new</a>(ctx);
    temp_account.deposit(base_in, ctx);
    temp_account.deposit(quote_in, ctx);
    temp_account.deposit(deep_in, ctx);
    <b>let</b> proof = temp_account.generate_proof_as_owner(ctx);

    <b>let</b> is_bid = quote_quantity &gt; 0;
    <b>let</b> (taker_fee, _) = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.fees_for_user(temp_account.owner());
    <b>let</b> (base_fee, quote_fee, _) = self.deep_config.calculate_fees(taker_fee, base_quantity, quote_quantity);
    base_quantity = base_quantity - base_fee;
    quote_quantity = quote_quantity - quote_fee;
    <b>if</b> (is_bid) {
        (base_quantity, _) = self.<a href="pool.md#0x0_pool_get_amount_out">get_amount_out</a>(0, quote_quantity);
    };
    base_quantity = base_quantity - base_quantity % self.lot_size;

    self.<a href="pool.md#0x0_pool_place_market_order">place_market_order</a>(&<b>mut</b> temp_account, &proof, 0, base_quantity, is_bid, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>, ctx);
    <b>let</b> base_out = temp_account.withdraw_with_proof(&proof, 0, <b>true</b>).into_coin(ctx);
    <b>let</b> quote_out = temp_account.withdraw_with_proof(&proof, 0, <b>true</b>).into_coin(ctx);
    <b>let</b> deep_out = temp_account.withdraw_with_proof(&proof, 0, <b>true</b>).into_coin(ctx);

    temp_account.delete();

    (base_out, quote_out, deep_out)
}
</code></pre>



</details>

<a name="0x0_pool_mid_price"></a>

## Function `mid_price`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_mid_price">mid_price</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_mid_price">mid_price</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;
): u64 {
    <b>let</b> (ask_ref, ask_offset) = self.asks.min_slice();
    <b>let</b> (bid_ref, bid_offset) = self.bids.max_slice();
    <b>assert</b>!(!ask_ref.is_null() && !bid_ref.is_null(), <a href="pool.md#0x0_pool_EEmptyOrderbook">EEmptyOrderbook</a>);
    <b>let</b> ask_order = &self.asks.borrow_slice(ask_ref)[ask_offset];
    <b>let</b> (_, ask_price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(ask_order.book_order_id());
    <b>let</b> bid_order = &self.bids.borrow_slice(bid_ref)[bid_offset];
    <b>let</b> (_, bid_price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(bid_order.book_order_id());

    <a href="math.md#0x0_math_div">math::div</a>(ask_price + bid_price, 2)
}
</code></pre>



</details>

<a name="0x0_pool_get_amount_out"></a>

## Function `get_amount_out`

Given base_amount and quote_amount, calculate the base_amount_out and quote_amount_out.
Will return (base_amount_out, quote_amount_out) if base_amount > 0 or quote_amount > 0.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_get_amount_out">get_amount_out</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, base_amount: u64, quote_amount: u64): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_get_amount_out">get_amount_out</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    base_amount: u64,
    quote_amount: u64,
): (u64, u64) {
    <b>assert</b>!((base_amount &gt; 0 || quote_amount &gt; 0) && !(base_amount &gt; 0 && quote_amount &gt; 0), <a href="pool.md#0x0_pool_EInvalidAmountIn">EInvalidAmountIn</a>);
    <b>let</b> is_bid = quote_amount &gt; 0;
    <b>let</b> <b>mut</b> amount_out = 0;
    <b>let</b> <b>mut</b> amount_in_left = <b>if</b> (is_bid) quote_amount <b>else</b> base_amount;

    <b>let</b> book_side = <b>if</b> (is_bid) &self.asks <b>else</b> &self.bids;
    <b>let</b> (<b>mut</b> ref, <b>mut</b> offset) = <b>if</b> (is_bid) book_side.min_slice() <b>else</b> book_side.max_slice();

    <b>while</b> (!ref.is_null() && amount_in_left &gt; 0) {
        <b>let</b> <a href="order.md#0x0_order">order</a> = &book_side.borrow_slice(ref)[offset];
        <b>let</b> (_, cur_price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(<a href="order.md#0x0_order">order</a>.book_order_id());
        <b>let</b> cur_quantity = <a href="order.md#0x0_order">order</a>.book_quantity();

        <b>if</b> (is_bid) {
            <b>let</b> matched_amount = <a href="math.md#0x0_math_min">math::min</a>(amount_in_left, <a href="math.md#0x0_math_mul">math::mul</a>(cur_quantity, cur_price));
            amount_out = amount_out + <a href="math.md#0x0_math_div">math::div</a>(matched_amount, cur_price);
            amount_in_left = amount_in_left - matched_amount;
        } <b>else</b> {
            <b>let</b> matched_amount = <a href="math.md#0x0_math_min">math::min</a>(amount_in_left, cur_quantity);
            amount_out = amount_out + <a href="math.md#0x0_math_mul">math::mul</a>(matched_amount, cur_price);
            amount_in_left = amount_in_left - matched_amount;
        };

        (ref, offset) = <b>if</b> (is_bid) book_side.next_slice(ref, offset) <b>else</b> book_side.prev_slice(ref, offset);
    };

    <b>if</b> (is_bid) {
        (amount_out, amount_in_left)
    } <b>else</b> {
        (amount_in_left, amount_out)
    }
}
</code></pre>



</details>

<a name="0x0_pool_get_level2_range"></a>

## Function `get_level2_range`

Get the level2 bids or asks between price_low and price_high.
Returns two vectors of u64
The previous is a list of all valid prices
The latter is the corresponding quantity at each level


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_get_level2_range">get_level2_range</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, price_low: u64, price_high: u64, is_bid: bool): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_get_level2_range">get_level2_range</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    price_low: u64,
    price_high: u64,
    is_bid: bool,
): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;) {
    <a href="pool.md#0x0_pool_get_level2_range_and_ticks">get_level2_range_and_ticks</a>(self, price_low, price_high, <a href="pool.md#0x0_pool_MAX_U64">MAX_U64</a>, is_bid)
}
</code></pre>



</details>

<a name="0x0_pool_get_level2_ticks_from_mid"></a>

## Function `get_level2_ticks_from_mid`

Get the n ticks from the mid price
Returns four vectors of u64.
The first two are the bid prices and quantities.
The latter two are the ask prices and quantities.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_get_level2_ticks_from_mid">get_level2_ticks_from_mid</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, ticks: u64): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_get_level2_ticks_from_mid">get_level2_ticks_from_mid</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    ticks: u64,
): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;) {
    <b>let</b> (bid_price, bid_quantity) = self.<a href="pool.md#0x0_pool_get_level2_range_and_ticks">get_level2_range_and_ticks</a>(<a href="pool.md#0x0_pool_MIN_PRICE">MIN_PRICE</a>, <a href="pool.md#0x0_pool_MAX_PRICE">MAX_PRICE</a>, ticks, <b>true</b>);
    <b>let</b> (ask_price, ask_quantity) = self.<a href="pool.md#0x0_pool_get_level2_range_and_ticks">get_level2_range_and_ticks</a>(<a href="pool.md#0x0_pool_MIN_PRICE">MIN_PRICE</a>, <a href="pool.md#0x0_pool_MAX_PRICE">MAX_PRICE</a>, ticks, <b>false</b>);

    (bid_price, bid_quantity, ask_price, ask_quantity)
}
</code></pre>



</details>

<a name="0x0_pool_cancel_order"></a>

## Function `cancel_order`

1. Remove the order from the order book and from the user's open orders.
2. Refund the user for the remaining quantity and fees.
2a. If the order is a bid, refund the quote asset + non deep fee.
2b. If the order is an ask, refund the base asset + non deep fee.
3. If the order was placed with deep fees, refund the deep fees.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_cancel_order">cancel_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, order_id: u128, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_cancel_order">cancel_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    order_id: u128,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &TxContext,
) {
    <b>let</b> <b>mut</b> <a href="order.md#0x0_order">order</a> = <b>if</b> (<a href="pool.md#0x0_pool_order_is_bid">order_is_bid</a>(order_id)) {
        self.bids.remove(order_id)
    } <b>else</b> {
        self.asks.remove(order_id)
    };

    <a href="order.md#0x0_order">order</a>.set_canceled();
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.remove_user_open_order(<a href="account.md#0x0_account">account</a>.owner(), order_id);

    <b>let</b> cancel_quantity = <a href="order.md#0x0_order">order</a>.book_quantity();
    <b>let</b> (base_quantity, quote_quantity, deep_quantity) = <a href="order.md#0x0_order">order</a>.cancel_amounts(
        cancel_quantity,
        <b>false</b>,
    );

    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.add_settled_amounts(<a href="account.md#0x0_account">account</a>.owner(), base_quantity, quote_quantity, deep_quantity);
    self.<a href="pool.md#0x0_pool_settle_user">settle_user</a>(<a href="account.md#0x0_account">account</a>, proof, ctx);

    <a href="order.md#0x0_order">order</a>.emit_order_canceled&lt;BaseAsset, QuoteAsset&gt;(self.id.to_inner(), <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms());
}
</code></pre>



</details>

<a name="0x0_pool_claim_rebates"></a>

## Function `claim_rebates`

Claim the rebates for the user


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_claim_rebates">claim_rebates</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_claim_rebates">claim_rebates</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    ctx: &TxContext
) {
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.reset_user_rebates(<a href="account.md#0x0_account">account</a>.owner(), ctx.epoch());
    self.<a href="pool.md#0x0_pool_settle_user">settle_user</a>(<a href="account.md#0x0_account">account</a>, proof, ctx);
}
</code></pre>



</details>

<a name="0x0_pool_cancel_all"></a>

## Function `cancel_all`

Cancel all orders for an account. Withdraw settled funds back into user account.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_cancel_all">cancel_all</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_cancel_all">cancel_all</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &TxContext,
) {
    <b>let</b> user_open_orders = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.<a href="pool.md#0x0_pool_user_open_orders">user_open_orders</a>(<a href="account.md#0x0_account">account</a>.owner());

    <b>let</b> orders_vector = user_open_orders.into_keys();
    <b>let</b> len = orders_vector.length();
    <b>let</b> <b>mut</b> i = 0;
    <b>while</b> (i &lt; len) {
        <b>let</b> key = orders_vector[i];
        <a href="pool.md#0x0_pool_cancel_order">cancel_order</a>(self, <a href="account.md#0x0_account">account</a>, proof, key, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>, ctx);
        i = i + 1;
    };
}
</code></pre>



</details>

<a name="0x0_pool_user_open_orders"></a>

## Function `user_open_orders`

Get all open orders for a user.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_user_open_orders">user_open_orders</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user: <b>address</b>): <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set_VecSet">vec_set::VecSet</a>&lt;u128&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_user_open_orders">user_open_orders</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    user: <b>address</b>,
): VecSet&lt;u128&gt; {
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.<a href="pool.md#0x0_pool_user_open_orders">user_open_orders</a>(user)
}
</code></pre>



</details>

<a name="0x0_pool_create_pool"></a>

## Function `create_pool`

Creates a new pool


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_create_pool">create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="registry.md#0x0_registry">registry</a>: &<b>mut</b> <a href="registry.md#0x0_registry_Registry">registry::Registry</a>, tick_size: u64, lot_size: u64, min_size: u64, creation_fee: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;<a href="dependencies/sui-framework/sui.md#0x2_sui_SUI">sui::SUI</a>&gt;, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_create_pool">create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="registry.md#0x0_registry">registry</a>: &<b>mut</b> Registry,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    creation_fee: Balance&lt;SUI&gt;,
    ctx: &<b>mut</b> TxContext,
) {
    <b>assert</b>!(creation_fee.value() == <a href="pool.md#0x0_pool_POOL_CREATION_FEE">POOL_CREATION_FEE</a>, <a href="pool.md#0x0_pool_EInvalidFee">EInvalidFee</a>);
    <b>assert</b>!(tick_size &gt; 0, <a href="pool.md#0x0_pool_EInvalidTickSize">EInvalidTickSize</a>);
    <b>assert</b>!(lot_size &gt; 0, <a href="pool.md#0x0_pool_EInvalidLotSize">EInvalidLotSize</a>);
    <b>assert</b>!(min_size &gt; 0, <a href="pool.md#0x0_pool_EInvalidMinSize">EInvalidMinSize</a>);

    <b>assert</b>!(<a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;BaseAsset&gt;() != <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;QuoteAsset&gt;(), <a href="pool.md#0x0_pool_ESameBaseAndQuote">ESameBaseAndQuote</a>);
    <a href="registry.md#0x0_registry">registry</a>.register_pool&lt;BaseAsset, QuoteAsset&gt;();
    <a href="registry.md#0x0_registry">registry</a>.register_pool&lt;QuoteAsset, BaseAsset&gt;();

    <b>let</b> pool_uid = <a href="dependencies/sui-framework/object.md#0x2_object_new">object::new</a>(ctx);
    <b>let</b> (taker_fee, maker_fee) = <a href="governance.md#0x0_governance_default_fees">governance::default_fees</a>(<b>false</b>);

    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="pool.md#0x0_pool_PoolCreated">PoolCreated</a>&lt;BaseAsset, QuoteAsset&gt; {
        pool_id: pool_uid.to_inner(),
        taker_fee,
        maker_fee,
        tick_size,
        lot_size,
        min_size,
    });

    <b>let</b> <a href="pool.md#0x0_pool">pool</a> = (<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt; {
        id: pool_uid,
        bids: <a href="big_vector.md#0x0_big_vector_empty">big_vector::empty</a>(10000, 1000, ctx), // TODO: <b>update</b> base on benchmark
        asks: <a href="big_vector.md#0x0_big_vector_empty">big_vector::empty</a>(10000, 1000, ctx), // TODO: <b>update</b> base on benchmark
        next_bid_order_id: <a href="pool.md#0x0_pool_START_BID_ORDER_ID">START_BID_ORDER_ID</a>,
        next_ask_order_id: <a href="pool.md#0x0_pool_START_ASK_ORDER_ID">START_ASK_ORDER_ID</a>,
        deep_config: <a href="deep_price.md#0x0_deep_price_new">deep_price::new</a>(),
        deep_whitelisted: <b>false</b>,
        stable: <b>false</b>,
        tick_size,
        lot_size,
        min_size,
        base_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_zero">balance::zero</a>(),
        quote_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_zero">balance::zero</a>(),
        deep_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_zero">balance::zero</a>(),
        vault: <a href="dependencies/sui-framework/balance.md#0x2_balance_zero">balance::zero</a>(),
        <a href="state_manager.md#0x0_state_manager">state_manager</a>: <a href="state_manager.md#0x0_state_manager_new">state_manager::new</a>(taker_fee, maker_fee, 0, ctx),
        <a href="governance.md#0x0_governance">governance</a>: <a href="governance.md#0x0_governance_empty">governance::empty</a>(ctx.epoch()),
    });

    // TODO: reconsider sending the Coin here. User pays gas;
    // TODO: depending on the frequency of the <a href="dependencies/sui-framework/event.md#0x2_event">event</a>;
    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_public_transfer">transfer::public_transfer</a>(creation_fee.into_coin(ctx), <a href="pool.md#0x0_pool_TREASURY_ADDRESS">TREASURY_ADDRESS</a>);

    <a href="pool.md#0x0_pool">pool</a>.<a href="pool.md#0x0_pool_share">share</a>();
}
</code></pre>



</details>

<a name="0x0_pool_whitelist_pool"></a>

## Function `whitelist_pool`

Whitelist this pool as a DEEP price source.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_whitelist_pool">whitelist_pool</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, deep_whitelisted: bool)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_whitelist_pool">whitelist_pool</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    deep_whitelisted: bool,
) {
    <b>let</b> (base, quote) = self.<a href="pool.md#0x0_pool_get_base_quote_types">get_base_quote_types</a>();
    <b>let</b> deep_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;<a href="pool.md#0x0_pool_DEEP">DEEP</a>&gt;();
    <b>assert</b>!(deep_whitelisted || base == deep_type || quote == deep_type, <a href="pool.md#0x0_pool_EIneligibleWhitelist">EIneligibleWhitelist</a>);

    self.deep_whitelisted = deep_whitelisted;
}
</code></pre>



</details>

<a name="0x0_pool_set_stable"></a>

## Function `set_stable`

Set the <code><a href="pool.md#0x0_pool_Pool">Pool</a></code> as stable or volatile. This changes the fee structure of the pool.
New proposals will be asserted against the new fee structure.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_set_stable">set_stable</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, stable: bool, epoch: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_set_stable">set_stable</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    stable: bool,
    epoch: u64,
) {
    self.stable = stable;
    <b>let</b> (taker, maker) = <a href="governance.md#0x0_governance_default_fees">governance::default_fees</a>(stable);
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.set_fees(taker, maker, epoch);
}
</code></pre>



</details>

<a name="0x0_pool_deep_whitelisted"></a>

## Function `deep_whitelisted`

Whether this pool is a DEEP price source.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_deep_whitelisted">deep_whitelisted</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_deep_whitelisted">deep_whitelisted</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;
): bool {
    self.deep_whitelisted
}
</code></pre>



</details>

<a name="0x0_pool_stake"></a>

## Function `stake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_stake">stake</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, amount: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_stake">stake</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    amount: u64,
    ctx: &TxContext,
) {
    <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = <a href="account.md#0x0_account">account</a>.withdraw_with_proof&lt;<a href="pool.md#0x0_pool_DEEP">DEEP</a>&gt;(proof, amount, <b>false</b>);
    self.vault.join(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
    <b>let</b> total_stake = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.increase_user_stake(<a href="account.md#0x0_account">account</a>.owner(), amount, ctx.epoch());
    self.<a href="governance.md#0x0_governance">governance</a>.adjust_voting_power(total_stake - amount, total_stake);
}
</code></pre>



</details>

<a name="0x0_pool_unstake"></a>

## Function `unstake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_unstake">unstake</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_unstake">unstake</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    ctx: &TxContext,
) {
    <b>let</b> total_stake = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.remove_user_stake(<a href="account.md#0x0_account">account</a>.owner(), ctx.epoch());
    <b>let</b> from_proposal_id = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.set_user_voted_proposal(<a href="account.md#0x0_account">account</a>.owner(), <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(), ctx.epoch());
    <b>if</b> (from_proposal_id.is_some()) {
        self.<a href="governance.md#0x0_governance">governance</a>.adjust_voting_power(total_stake, 0);
        <b>let</b> winning_proposal = self.<a href="governance.md#0x0_governance">governance</a>.adjust_vote(from_proposal_id, <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(), total_stake);
        self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.set_next_trade_params(winning_proposal);
    };

    <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = self.vault.split(total_stake);
    <a href="account.md#0x0_account">account</a>.deposit_with_proof&lt;<a href="pool.md#0x0_pool_DEEP">DEEP</a>&gt;(proof, <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
}
</code></pre>



</details>

<a name="0x0_pool_submit_proposal"></a>

## Function `submit_proposal`

Submit a proposal to change the fee structure of a pool.
The user submitting this proposal must have vested stake in the pool.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_submit_proposal">submit_proposal</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user: <b>address</b>, taker_fee: u64, maker_fee: u64, stake_required: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_submit_proposal">submit_proposal</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    user: <b>address</b>,
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
    ctx: &TxContext,
) {
    <b>let</b> (stake, _) = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.user_stake(user, ctx.epoch());
    <b>assert</b>!(stake &gt;= <a href="pool.md#0x0_pool_STAKE_REQUIRED_TO_PARTICIPATE">STAKE_REQUIRED_TO_PARTICIPATE</a>, <a href="pool.md#0x0_pool_ENotEnoughStake">ENotEnoughStake</a>);

    <b>let</b> from_proposal_id = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.set_user_voted_proposal(user, <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(), ctx.epoch());
    self.<a href="governance.md#0x0_governance">governance</a>.adjust_vote(from_proposal_id, <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(), stake);
    self.<a href="governance.md#0x0_governance">governance</a>.add_proposal(self.stable, taker_fee, maker_fee, stake_required, stake, user);
    self.<a href="pool.md#0x0_pool_vote">vote</a>(user, user, ctx);
}
</code></pre>



</details>

<a name="0x0_pool_vote"></a>

## Function `vote`

Vote on a proposal using the user's full voting power.
If the vote pushes proposal over quorum, update the Pool's
next_trade_params.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_vote">vote</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user: <b>address</b>, proposal_id: <b>address</b>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_vote">vote</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    user: <b>address</b>,
    proposal_id: <b>address</b>,
    ctx: &TxContext,
) {
    <b>let</b> (stake, _) = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.user_stake(user, ctx.epoch());
    <b>assert</b>!(stake &gt;= <a href="pool.md#0x0_pool_STAKE_REQUIRED_TO_PARTICIPATE">STAKE_REQUIRED_TO_PARTICIPATE</a>, <a href="pool.md#0x0_pool_ENotEnoughStake">ENotEnoughStake</a>);

    <b>let</b> from_proposal_id = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.set_user_voted_proposal(user, <a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(proposal_id), ctx.epoch());
    <b>let</b> winning_proposal = self.<a href="governance.md#0x0_governance">governance</a>.adjust_vote(from_proposal_id, <a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(proposal_id), stake);
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.set_next_trade_params(winning_proposal);
}
</code></pre>



</details>

<a name="0x0_pool_get_user_stake"></a>

## Function `get_user_stake`

Get the user's (current, next) stake amounts


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_get_user_stake">get_user_stake</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user: <b>address</b>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_get_user_stake">get_user_stake</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    user: <b>address</b>,
    ctx: &TxContext,
): (u64, u64) {
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.user_stake(user, ctx.epoch())
}
</code></pre>



</details>

<a name="0x0_pool_add_deep_price_point"></a>

## Function `add_deep_price_point`

Add a new price point to the pool.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_add_deep_price_point">add_deep_price_point</a>&lt;BaseAsset, QuoteAsset, DEEPBaseAsset, DEEPQuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, reference_pool: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;DEEPBaseAsset, DEEPQuoteAsset&gt;, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_add_deep_price_point">add_deep_price_point</a>&lt;BaseAsset, QuoteAsset, DEEPBaseAsset, DEEPQuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    reference_pool: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;DEEPBaseAsset, DEEPQuoteAsset&gt;,
    timestamp: u64,
) {
    <b>let</b> (base_conversion_rate, quote_conversion_rate) = self.<a href="pool.md#0x0_pool_get_conversion_rates">get_conversion_rates</a>(reference_pool);
    self.deep_config.add_price_point(base_conversion_rate, quote_conversion_rate, timestamp);
}
</code></pre>



</details>

<a name="0x0_pool_get_base_quote_types"></a>

## Function `get_base_quote_types`

Get the base and quote asset TypeName of pool


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_get_base_quote_types">get_base_quote_types</a>&lt;BaseAsset, QuoteAsset&gt;(_self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;): (<a href="dependencies/move-stdlib/type_name.md#0x1_type_name_TypeName">type_name::TypeName</a>, <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_TypeName">type_name::TypeName</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_get_base_quote_types">get_base_quote_types</a>&lt;BaseAsset, QuoteAsset&gt;(
    _self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;
): (TypeName, TypeName) {
    (
        <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;BaseAsset&gt;(),
        <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;QuoteAsset&gt;()
    )
}
</code></pre>



</details>

<a name="0x0_pool_share"></a>

## Function `share`

Share the Pool.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_share">share</a>&lt;BaseAsset, QuoteAsset&gt;(self: <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_share">share</a>&lt;BaseAsset, QuoteAsset&gt;(self: <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;) {
    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_share_object">transfer::share_object</a>(self)
}
</code></pre>



</details>

<a name="0x0_pool_send_treasury"></a>

## Function `send_treasury`

Send fees collected in input tokens to treasury


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_send_treasury">send_treasury</a>&lt;T&gt;(fee: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;T&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_send_treasury">send_treasury</a>&lt;T&gt;(fee: Coin&lt;T&gt;) {
    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_public_transfer">transfer::public_transfer</a>(fee, <a href="pool.md#0x0_pool_TREASURY_ADDRESS">TREASURY_ADDRESS</a>)
}
</code></pre>



</details>

<a name="0x0_pool_inject_limit_order"></a>

## Function `inject_limit_order`

Balance accounting happens before this function is called


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_inject_limit_order">inject_limit_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, order_info: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_inject_limit_order">inject_limit_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    order_info: &OrderInfo,
) {
    <b>let</b> <a href="order.md#0x0_order">order</a> = order_info.to_order();
    <b>if</b> (order_info.is_bid()) {
        self.bids.insert(order_info.order_id(), <a href="order.md#0x0_order">order</a>);
    } <b>else</b> {
        self.asks.insert(order_info.order_id(), <a href="order.md#0x0_order">order</a>);
    };

    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.add_user_open_order(order_info.owner(), order_info.order_id());
    order_info.emit_order_placed&lt;BaseAsset, QuoteAsset&gt;();
}
</code></pre>



</details>

<a name="0x0_pool_order_is_bid"></a>

## Function `order_is_bid`

Returns 0 if the order is a bid order, 1 if the order is an ask order


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_order_is_bid">order_is_bid</a>(order_id: u128): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_order_is_bid">order_is_bid</a>(order_id: u128): bool {
    (order_id &lt; <a href="pool.md#0x0_pool_MIN_ASK_ORDER_ID">MIN_ASK_ORDER_ID</a>)
}
</code></pre>



</details>

<a name="0x0_pool_get_order_id"></a>

## Function `get_order_id`



<pre><code><b>fun</b> <a href="pool.md#0x0_pool_get_order_id">get_order_id</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, is_bid: bool): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_get_order_id">get_order_id</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    is_bid: bool
): u64 {
    <b>if</b> (is_bid) {
        self.next_bid_order_id = self.next_bid_order_id - 1;
        self.next_bid_order_id
    } <b>else</b> {
        self.next_ask_order_id = self.next_ask_order_id + 1;
        self.next_ask_order_id
    }
}
</code></pre>



</details>

<a name="0x0_pool_get_level2_range_and_ticks"></a>

## Function `get_level2_range_and_ticks`

Get the n ticks from the best bid or ask, must be within price range
Returns two vectors of u64.
The first is a list of all valid prices.
The latter is the corresponding quantity list.
Price_vec is in descending order for bids and ascending order for asks.


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_get_level2_range_and_ticks">get_level2_range_and_ticks</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, price_low: u64, price_high: u64, ticks: u64, is_bid: bool): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_get_level2_range_and_ticks">get_level2_range_and_ticks</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    price_low: u64,
    price_high: u64,
    ticks: u64,
    is_bid: bool,
): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;) {
    <b>assert</b>!(price_low &lt;= price_high, <a href="pool.md#0x0_pool_EInvalidPriceRange">EInvalidPriceRange</a>);
    <b>assert</b>!(ticks &gt; 0, <a href="pool.md#0x0_pool_EInvalidTicks">EInvalidTicks</a>);

    <b>let</b> <b>mut</b> price_vec = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[];
    <b>let</b> <b>mut</b> quantity_vec = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[];

    // convert price_low and price_high <b>to</b> keys for searching
    <b>let</b> key_low = (price_low <b>as</b> u128) &lt;&lt; 64;
    <b>let</b> key_high = ((price_high <b>as</b> u128) &lt;&lt; 64) + ((1u128 &lt;&lt; 64 - 1) <b>as</b> u128);
    <b>let</b> book_side = <b>if</b> (is_bid) &self.bids <b>else</b> &self.asks;
    <b>let</b> (<b>mut</b> ref, <b>mut</b> offset) = <b>if</b> (is_bid) book_side.slice_before(key_high) <b>else</b> book_side.slice_following(key_low);
    <b>let</b> <b>mut</b> ticks_left = ticks;
    <b>let</b> <b>mut</b> cur_price = 0;
    <b>let</b> <b>mut</b> cur_quantity = 0;

    <b>while</b> (!ref.is_null() && ticks_left &gt; 0) {
        <b>let</b> <a href="order.md#0x0_order">order</a> = &book_side.borrow_slice(ref)[offset];
        <b>let</b> (_, order_price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(<a href="order.md#0x0_order">order</a>.book_order_id());
        <b>if</b> ((is_bid && order_price &gt;= price_low) || (!is_bid && order_price &lt;= price_high)) <b>break</b>;
        <b>if</b> (cur_price == 0) cur_price = order_price;

        <b>let</b> order_quantity = <a href="order.md#0x0_order">order</a>.book_quantity();
        <b>if</b> (order_price != cur_price) {
            price_vec.push_back(cur_price);
            quantity_vec.push_back(cur_quantity);
            cur_price = order_price;
            cur_quantity = 0;
        };

        cur_quantity = cur_quantity + order_quantity;
        ticks_left = ticks_left - 1;
        (ref, offset) = <b>if</b> (is_bid) book_side.prev_slice(ref, offset) <b>else</b> book_side.next_slice(ref, offset);
    };

    price_vec.push_back(cur_price);
    quantity_vec.push_back(cur_quantity);

    (price_vec, quantity_vec)
}
</code></pre>



</details>

<a name="0x0_pool_get_conversion_rates"></a>

## Function `get_conversion_rates`

Calculate the conversion rate between the DEEP token and the base and quote assets of a pool.
Case 1: base or quote in pool is already DEEP
Case 2: base and quote in pool is not DEEP


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_get_conversion_rates">get_conversion_rates</a>&lt;BaseAsset, QuoteAsset, DEEPBaseAsset, DEEPQuoteAsset&gt;(target_pool: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, reference_pool: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;DEEPBaseAsset, DEEPQuoteAsset&gt;): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_get_conversion_rates">get_conversion_rates</a>&lt;BaseAsset, QuoteAsset, DEEPBaseAsset, DEEPQuoteAsset&gt;(
    target_pool: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    reference_pool: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;DEEPBaseAsset, DEEPQuoteAsset&gt;,
): (u64, u64) {
    <b>let</b> (base_type, quote_type) = target_pool.<a href="pool.md#0x0_pool_get_base_quote_types">get_base_quote_types</a>();
    <b>let</b> deep_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;<a href="pool.md#0x0_pool_DEEP">DEEP</a>&gt;();
    <b>let</b> pool_price = target_pool.<a href="pool.md#0x0_pool_mid_price">mid_price</a>();
    <b>if</b> (base_type == deep_type) {
        <b>return</b> (1, pool_price)
    };
    <b>if</b> (quote_type == deep_type) {
        <b>return</b> (pool_price, 1)
    };

    <b>let</b> (deep_base_type, deep_quote_type) = reference_pool.<a href="pool.md#0x0_pool_get_base_quote_types">get_base_quote_types</a>();
    <b>assert</b>!(reference_pool.<a href="pool.md#0x0_pool_deep_whitelisted">deep_whitelisted</a>(), <a href="pool.md#0x0_pool_EIneligibleReferencePool">EIneligibleReferencePool</a>);
    <b>assert</b>!((base_type == deep_base_type || base_type == deep_quote_type) ||
            (quote_type == deep_base_type || quote_type == deep_quote_type), <a href="pool.md#0x0_pool_EIneligibleTargetPool">EIneligibleTargetPool</a>);
    <b>assert</b>!(!(base_type == deep_base_type && quote_type == deep_quote_type), <a href="pool.md#0x0_pool_EIneligibleTargetPool">EIneligibleTargetPool</a>);

    <b>let</b> <a href="deep_price.md#0x0_deep_price">deep_price</a> = reference_pool.<a href="pool.md#0x0_pool_mid_price">mid_price</a>();

    <b>let</b> deep_per_base = <b>if</b> (base_type == deep_base_type) {
        <a href="deep_price.md#0x0_deep_price">deep_price</a>
    } <b>else</b> <b>if</b> (base_type == deep_quote_type) {
        <a href="math.md#0x0_math_div">math::div</a>(1, <a href="deep_price.md#0x0_deep_price">deep_price</a>)
    } <b>else</b> <b>if</b> (quote_type == deep_base_type) {
        <a href="math.md#0x0_math_mul">math::mul</a>(<a href="deep_price.md#0x0_deep_price">deep_price</a>, pool_price)
    } <b>else</b> {
        <a href="math.md#0x0_math_div">math::div</a>(<a href="deep_price.md#0x0_deep_price">deep_price</a>, pool_price)
    };
    <b>let</b> deep_per_quote = <a href="math.md#0x0_math_div">math::div</a>(deep_per_base, pool_price);

    (deep_per_base, deep_per_quote)
}
</code></pre>



</details>

<a name="0x0_pool_correct_supply"></a>

## Function `correct_supply`



<pre><code><b>fun</b> <a href="pool.md#0x0_pool_correct_supply">correct_supply</a>&lt;B, Q&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;B, Q&gt;, tcap: &<b>mut</b> <a href="dependencies/sui-framework/coin.md#0x2_coin_TreasuryCap">coin::TreasuryCap</a>&lt;<a href="pool.md#0x0_pool_DEEP">pool::DEEP</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_correct_supply">correct_supply</a>&lt;B, Q&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;B, Q&gt;, tcap: &<b>mut</b> TreasuryCap&lt;<a href="pool.md#0x0_pool_DEEP">DEEP</a>&gt;) {
    <b>let</b> amount = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.reset_burn_balance();
    <b>let</b> burnt = self.deep_balance.split(amount);
    tcap.supply_mut().decrease_supply(burnt);
}
</code></pre>



</details>
