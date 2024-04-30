
<a name="0x0_pool"></a>

# Module `0x0::pool`



-  [Struct `PoolCreated`](#0x0_pool_PoolCreated)
-  [Struct `OrderPlaced`](#0x0_pool_OrderPlaced)
-  [Struct `OrderCanceled`](#0x0_pool_OrderCanceled)
-  [Struct `OrderFilled`](#0x0_pool_OrderFilled)
-  [Struct `DEEP`](#0x0_pool_DEEP)
-  [Struct `Order`](#0x0_pool_Order)
-  [Resource `Pool`](#0x0_pool_Pool)
-  [Constants](#@Constants_0)
-  [Function `place_limit_order`](#0x0_pool_place_limit_order)
-  [Function `transfer_taker`](#0x0_pool_transfer_taker)
-  [Function `transfer_maker`](#0x0_pool_transfer_maker)
-  [Function `match_bid`](#0x0_pool_match_bid)
-  [Function `match_ask`](#0x0_pool_match_ask)
-  [Function `place_market_order`](#0x0_pool_place_market_order)
-  [Function `get_amount_out`](#0x0_pool_get_amount_out)
-  [Function `get_level2_bids`](#0x0_pool_get_level2_bids)
-  [Function `get_level2_asks`](#0x0_pool_get_level2_asks)
-  [Function `get_level2_ticks_from_mid`](#0x0_pool_get_level2_ticks_from_mid)
-  [Function `cancel_order`](#0x0_pool_cancel_order)
-  [Function `claim_rebates`](#0x0_pool_claim_rebates)
-  [Function `cancel_all`](#0x0_pool_cancel_all)
-  [Function `user_open_orders`](#0x0_pool_user_open_orders)
-  [Function `create_pool`](#0x0_pool_create_pool)
-  [Function `increase_user_stake`](#0x0_pool_increase_user_stake)
-  [Function `remove_user_stake`](#0x0_pool_remove_user_stake)
-  [Function `get_user_stake`](#0x0_pool_get_user_stake)
-  [Function `add_deep_price_point`](#0x0_pool_add_deep_price_point)
-  [Function `set_next_trade_params`](#0x0_pool_set_next_trade_params)
-  [Function `get_base_quote_types`](#0x0_pool_get_base_quote_types)
-  [Function `key`](#0x0_pool_key)
-  [Function `share`](#0x0_pool_share)
-  [Function `deposit_base`](#0x0_pool_deposit_base)
-  [Function `deposit_quote`](#0x0_pool_deposit_quote)
-  [Function `deposit_deep`](#0x0_pool_deposit_deep)
-  [Function `withdraw_base`](#0x0_pool_withdraw_base)
-  [Function `withdraw_quote`](#0x0_pool_withdraw_quote)
-  [Function `withdraw_deep`](#0x0_pool_withdraw_deep)
-  [Function `send_treasury`](#0x0_pool_send_treasury)
-  [Function `internal_inject_limit_order`](#0x0_pool_internal_inject_limit_order)
-  [Function `internal_cancel_order`](#0x0_pool_internal_cancel_order)
-  [Function `order_is_bid`](#0x0_pool_order_is_bid)
-  [Function `get_order_id`](#0x0_pool_get_order_id)
-  [Function `fee_is_deep`](#0x0_pool_fee_is_deep)
-  [Function `correct_supply`](#0x0_pool_correct_supply)


<pre><code><b>use</b> <a href="account.md#0x0_account">0x0::account</a>;
<b>use</b> <a href="big_vector.md#0x0_big_vector">0x0::big_vector</a>;
<b>use</b> <a href="deep_price.md#0x0_deep_price">0x0::deep_price</a>;
<b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="state_manager.md#0x0_state_manager">0x0::state_manager</a>;
<b>use</b> <a href="utils.md#0x0_utils">0x0::utils</a>;
<b>use</b> <a href="dependencies/move-stdlib/ascii.md#0x1_ascii">0x1::ascii</a>;
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

<a name="0x0_pool_OrderPlaced"></a>

## Struct `OrderPlaced`

Emitted when a maker order is injected into the order book.


<pre><code><b>struct</b> <a href="pool.md#0x0_pool_OrderPlaced">OrderPlaced</a>&lt;BaseAsset, QuoteAsset&gt; <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>
 object ID of the pool the order was placed on
</dd>
<dt>
<code>order_id: u128</code>
</dt>
<dd>
 ID of the order within the pool
</dd>
<dt>
<code>client_order_id: u64</code>
</dt>
<dd>
 ID of the order defined by client
</dd>
<dt>
<code>is_bid: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>owner: <b>address</b></code>
</dt>
<dd>
 owner ID of the <code>AccountCap</code> that placed the order
</dd>
<dt>
<code>original_quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>price: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>expire_timestamp: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_pool_OrderCanceled"></a>

## Struct `OrderCanceled`

Emitted when a maker order is canceled.


<pre><code><b>struct</b> <a href="pool.md#0x0_pool_OrderCanceled">OrderCanceled</a>&lt;BaseAsset, QuoteAsset&gt; <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>
 object ID of the pool the order was placed on
</dd>
<dt>
<code>order_id: u128</code>
</dt>
<dd>
 ID of the order within the pool
</dd>
<dt>
<code>client_order_id: u64</code>
</dt>
<dd>
 ID of the order defined by client
</dd>
<dt>
<code>is_bid: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>owner: <b>address</b></code>
</dt>
<dd>
 owner ID of the <code>AccountCap</code> that canceled the order
</dd>
<dt>
<code>original_quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>base_asset_quantity_canceled: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>timestamp: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>price: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_pool_OrderFilled"></a>

## Struct `OrderFilled`

Emitted when a maker order is filled.


<pre><code><b>struct</b> <a href="pool.md#0x0_pool_OrderFilled">OrderFilled</a>&lt;BaseAsset, QuoteAsset&gt; <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>
 object ID of the pool the order was placed on
</dd>
<dt>
<code>maker_order_id: u128</code>
</dt>
<dd>
 ID of the order within the pool
</dd>
<dt>
<code>taker_order_id: u128</code>
</dt>
<dd>
 ID of the taker order
</dd>
<dt>
<code>maker_client_order_id: u64</code>
</dt>
<dd>
 ID of the order defined by maker client
</dd>
<dt>
<code>taker_client_order_id: u64</code>
</dt>
<dd>
 ID of the order defined by taker client
</dd>
<dt>
<code>base_quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>quote_quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>price: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>maker_address: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>taker_address: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>is_bid: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>timestamp: u64</code>
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

<a name="0x0_pool_Order"></a>

## Struct `Order`

For each pool, order id is incremental and unique for each opening order.
Orders that are submitted earlier has lower order ids.


<pre><code><b>struct</b> <a href="pool.md#0x0_pool_Order">Order</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>order_id: u128</code>
</dt>
<dd>

</dd>
<dt>
<code>client_order_id: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>order_type: u8</code>
</dt>
<dd>

</dd>
<dt>
<code>price: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>original_quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>original_fee_quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>fee_quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>fee_is_deep: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>is_bid: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>owner: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>expire_timestamp: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>self_matching_prevention: u8</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_pool_Pool"></a>

## Resource `Pool`



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
<code>bids: <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;<a href="pool.md#0x0_pool_Order">pool::Order</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>asks: <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;<a href="pool.md#0x0_pool_Order">pool::Order</a>&gt;</code>
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
<code>deep_config: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>base_balances: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;BaseAsset&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>quote_balances: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;QuoteAsset&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>deepbook_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;<a href="pool.md#0x0_pool_DEEP">pool::DEEP</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code><a href="state_manager.md#0x0_state_manager">state_manager</a>: <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_pool_EFOKOrderCannotBeFullyFilled"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EFOKOrderCannotBeFullyFilled">EFOKOrderCannotBeFullyFilled</a>: u64 = 11;
</code></pre>



<a name="0x0_pool_EInvalidExpireTimestamp"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidExpireTimestamp">EInvalidExpireTimestamp</a>: u64 = 9;
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



<a name="0x0_pool_EInvalidOrderType"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidOrderType">EInvalidOrderType</a>: u64 = 12;
</code></pre>



<a name="0x0_pool_EInvalidTickSize"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidTickSize">EInvalidTickSize</a>: u64 = 3;
</code></pre>



<a name="0x0_pool_EOrderBelowMinimumSize"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EOrderBelowMinimumSize">EOrderBelowMinimumSize</a>: u64 = 7;
</code></pre>



<a name="0x0_pool_EOrderInvalidLotSize"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EOrderInvalidLotSize">EOrderInvalidLotSize</a>: u64 = 8;
</code></pre>



<a name="0x0_pool_EOrderInvalidPrice"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EOrderInvalidPrice">EOrderInvalidPrice</a>: u64 = 6;
</code></pre>



<a name="0x0_pool_EPOSTOrderCrossesOrderbook"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EPOSTOrderCrossesOrderbook">EPOSTOrderCrossesOrderbook</a>: u64 = 10;
</code></pre>



<a name="0x0_pool_ESameBaseAndQuote"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_ESameBaseAndQuote">ESameBaseAndQuote</a>: u64 = 2;
</code></pre>



<a name="0x0_pool_FILL_OR_KILL"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_FILL_OR_KILL">FILL_OR_KILL</a>: u8 = 2;
</code></pre>



<a name="0x0_pool_IMMEDIATE_OR_CANCEL"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_IMMEDIATE_OR_CANCEL">IMMEDIATE_OR_CANCEL</a>: u8 = 1;
</code></pre>



<a name="0x0_pool_MAX_ORDER_ID"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_MAX_ORDER_ID">MAX_ORDER_ID</a>: u128 = 170141183460469231731687303715884105728;
</code></pre>



<a name="0x0_pool_MAX_PRICE"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_MAX_PRICE">MAX_PRICE</a>: u64 = 4611686018427387904;
</code></pre>



<a name="0x0_pool_MAX_RESTRICTION"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_MAX_RESTRICTION">MAX_RESTRICTION</a>: u8 = 3;
</code></pre>



<a name="0x0_pool_MIN_ASK_ORDER_ID"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_MIN_ASK_ORDER_ID">MIN_ASK_ORDER_ID</a>: u128 = 170141183460469231731687303715884105728;
</code></pre>



<a name="0x0_pool_MIN_ORDER_ID"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_MIN_ORDER_ID">MIN_ORDER_ID</a>: u128 = 0;
</code></pre>



<a name="0x0_pool_MIN_PRICE"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_MIN_PRICE">MIN_PRICE</a>: u64 = 1;
</code></pre>



<a name="0x0_pool_NO_RESTRICTION"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_NO_RESTRICTION">NO_RESTRICTION</a>: u8 = 0;
</code></pre>



<a name="0x0_pool_POOL_CREATION_FEE"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_POOL_CREATION_FEE">POOL_CREATION_FEE</a>: u64 = 100000000000;
</code></pre>



<a name="0x0_pool_POST_ONLY"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_POST_ONLY">POST_ONLY</a>: u8 = 3;
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
Will return (settled_base_quantity, settled_quote_quantity, order_id
if limit order placed and 0 otherwise)


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_place_limit_order">place_limit_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, client_order_id: u64, order_type: u8, price: u64, quantity: u64, is_bid: bool, expire_timestamp: u64, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (u64, u64, u128)
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
    quantity: u64, // in base asset
    is_bid: bool, // <b>true</b> for bid, <b>false</b> for ask
    expire_timestamp: u64, // Expiration timestamp in ms
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &<b>mut</b> TxContext,
): (u64, u64, u128) {
    // Refresh <a href="state.md#0x0_state">state</a> <b>as</b> necessary <b>if</b> first order of epoch
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.refresh(ctx.epoch());

    <b>assert</b>!(price &gt;= <a href="pool.md#0x0_pool_MIN_PRICE">MIN_PRICE</a> && price &lt;= <a href="pool.md#0x0_pool_MAX_PRICE">MAX_PRICE</a>, <a href="pool.md#0x0_pool_EOrderInvalidPrice">EOrderInvalidPrice</a>);
    <b>assert</b>!(price % self.tick_size == 0, <a href="pool.md#0x0_pool_EOrderInvalidPrice">EOrderInvalidPrice</a>);
    <b>assert</b>!(quantity &gt;= self.min_size, <a href="pool.md#0x0_pool_EOrderBelowMinimumSize">EOrderBelowMinimumSize</a>);
    <b>assert</b>!(quantity % self.lot_size == 0, <a href="pool.md#0x0_pool_EOrderInvalidLotSize">EOrderInvalidLotSize</a>);
    <b>assert</b>!(expire_timestamp &gt; <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms(), <a href="pool.md#0x0_pool_EInvalidExpireTimestamp">EInvalidExpireTimestamp</a>);
    <b>assert</b>!(order_type &gt;= <a href="pool.md#0x0_pool_NO_RESTRICTION">NO_RESTRICTION</a> && order_type &lt;= <a href="pool.md#0x0_pool_MAX_RESTRICTION">MAX_RESTRICTION</a>, <a href="pool.md#0x0_pool_EInvalidOrderType">EInvalidOrderType</a>);

    <b>let</b> order_id = encode_order_id(is_bid, price, self.<a href="pool.md#0x0_pool_get_order_id">get_order_id</a>(is_bid));
    <b>let</b> (net_base_quantity, net_quote_quantity) =
        <b>if</b> (is_bid) {
            self.<a href="pool.md#0x0_pool_match_bid">match_bid</a>(<a href="account.md#0x0_account">account</a>.owner(), order_id, client_order_id, quantity, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>)
        } <b>else</b> {
            self.<a href="pool.md#0x0_pool_match_ask">match_ask</a>(<a href="account.md#0x0_account">account</a>.owner(), order_id, client_order_id, quantity, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>)
        };

    <b>if</b> (order_type == <a href="pool.md#0x0_pool_POST_ONLY">POST_ONLY</a>) {
        <b>assert</b>!(net_base_quantity == 0, <a href="pool.md#0x0_pool_EPOSTOrderCrossesOrderbook">EPOSTOrderCrossesOrderbook</a>);
    };

    <b>if</b> (order_type == <a href="pool.md#0x0_pool_FILL_OR_KILL">FILL_OR_KILL</a>) {
        <b>assert</b>!(net_base_quantity == quantity, <a href="pool.md#0x0_pool_EFOKOrderCannotBeFullyFilled">EFOKOrderCannotBeFullyFilled</a>);
    };

    <b>let</b> (settled_base_quantity, settled_quote_quantity) = <b>if</b> (is_bid) {
        (net_base_quantity, 0)
    } <b>else</b> {
        (0, net_quote_quantity)
    };

    self.<a href="pool.md#0x0_pool_transfer_taker">transfer_taker</a>(<a href="account.md#0x0_account">account</a>, proof, net_base_quantity, net_quote_quantity, is_bid, ctx);
    <b>let</b> remaining_quantity = quantity - net_base_quantity;
    <b>if</b> (remaining_quantity == 0 || order_type == <a href="pool.md#0x0_pool_IMMEDIATE_OR_CANCEL">IMMEDIATE_OR_CANCEL</a>) {
        (settled_base_quantity, settled_quote_quantity, 0)
    } <b>else</b> {
        <b>let</b> fee_quantity = self.<a href="pool.md#0x0_pool_transfer_maker">transfer_maker</a>(<a href="account.md#0x0_account">account</a>, proof, remaining_quantity, price, is_bid, ctx);

        self.<a href="pool.md#0x0_pool_internal_inject_limit_order">internal_inject_limit_order</a>(
            order_id,
            client_order_id,
            order_type,
            price,
            remaining_quantity,
            fee_quantity,
            is_bid,
            expire_timestamp,
            <a href="account.md#0x0_account">account</a>.owner(),
        );

        <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="pool.md#0x0_pool_OrderPlaced">OrderPlaced</a>&lt;BaseAsset, QuoteAsset&gt; {
            pool_id: self.id.to_inner(),
            order_id,
            client_order_id,
            is_bid,
            owner: <a href="account.md#0x0_account">account</a>.owner(),
            original_quantity: remaining_quantity,
            price,
            expire_timestamp,
        });

        (settled_base_quantity, settled_quote_quantity, order_id)
    }
}
</code></pre>



</details>

<a name="0x0_pool_transfer_taker"></a>

## Function `transfer_taker`

Given output from order matching, deposits assets from account into pool and withdraws from pool to account


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_transfer_taker">transfer_taker</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, net_base_quantity: u64, net_quote_quantity: u64, is_bid: bool, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_transfer_taker">transfer_taker</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    net_base_quantity: u64,
    net_quote_quantity: u64,
    is_bid: bool,
    ctx: &<b>mut</b> TxContext,
) {
    // Discounted taker fees <b>if</b> above minimum stake
    <b>let</b> taker_fee = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.taker_fee_for_user(<a href="account.md#0x0_account">account</a>.owner());

    <b>if</b> (is_bid) {
        // <a href="dependencies/sui-framework/transfer.md#0x2_transfer">transfer</a> quote out from <a href="account.md#0x0_account">account</a> <b>to</b> <a href="pool.md#0x0_pool">pool</a>, <a href="dependencies/sui-framework/transfer.md#0x2_transfer">transfer</a> base from <a href="pool.md#0x0_pool">pool</a> <b>to</b> <a href="account.md#0x0_account">account</a>
        <b>if</b> (self.<a href="pool.md#0x0_pool_fee_is_deep">fee_is_deep</a>()) {
            <b>let</b> deep_quantity = math::mul(taker_fee, math::mul(net_quote_quantity, self.deep_config.borrow().deep_per_quote()));
            self.<a href="pool.md#0x0_pool_deposit_deep">deposit_deep</a>(<a href="account.md#0x0_account">account</a>, proof, deep_quantity, ctx);
            self.<a href="pool.md#0x0_pool_deposit_quote">deposit_quote</a>(<a href="account.md#0x0_account">account</a>, proof, net_quote_quantity, ctx);
        } <b>else</b> {
            <b>let</b> quote_fee = math::mul(taker_fee, net_quote_quantity);
            self.<a href="pool.md#0x0_pool_deposit_quote">deposit_quote</a>(<a href="account.md#0x0_account">account</a>, proof, net_quote_quantity + quote_fee, ctx);
        };
        self.<a href="pool.md#0x0_pool_withdraw_base">withdraw_base</a>(<a href="account.md#0x0_account">account</a>, proof, net_base_quantity, ctx);
    } <b>else</b> {
        // <a href="dependencies/sui-framework/transfer.md#0x2_transfer">transfer</a> base out from <a href="account.md#0x0_account">account</a> <b>to</b> <a href="pool.md#0x0_pool">pool</a>, <a href="dependencies/sui-framework/transfer.md#0x2_transfer">transfer</a> quote from <a href="pool.md#0x0_pool">pool</a> <b>to</b> <a href="account.md#0x0_account">account</a>
        <b>if</b> (self.<a href="pool.md#0x0_pool_fee_is_deep">fee_is_deep</a>()) {
            <b>let</b> deep_quantity = math::mul(taker_fee, math::mul(net_base_quantity, self.deep_config.borrow().deep_per_base()));
            self.<a href="pool.md#0x0_pool_deposit_deep">deposit_deep</a>(<a href="account.md#0x0_account">account</a>, proof, deep_quantity, ctx);
            self.<a href="pool.md#0x0_pool_deposit_base">deposit_base</a>(<a href="account.md#0x0_account">account</a>, proof, net_base_quantity, ctx);
        } <b>else</b> {
            <b>let</b> base_fee = math::mul(taker_fee, net_base_quantity);
            self.<a href="pool.md#0x0_pool_deposit_quote">deposit_quote</a>(<a href="account.md#0x0_account">account</a>, proof, net_base_quantity + base_fee, ctx);
        };
        self.<a href="pool.md#0x0_pool_withdraw_base">withdraw_base</a>(<a href="account.md#0x0_account">account</a>, proof,net_quote_quantity, ctx);
    };
}
</code></pre>



</details>

<a name="0x0_pool_transfer_maker"></a>

## Function `transfer_maker`

Given output from order matching, deposits assets from account into pool to prepare order placement. Returns fee quantity


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_transfer_maker">transfer_maker</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, remaining_quantity: u64, price: u64, is_bid: bool, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_transfer_maker">transfer_maker</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    remaining_quantity: u64,
    price: u64,
    is_bid: bool,
    ctx: &<b>mut</b> TxContext,
): u64 {
    <b>let</b> maker_fee = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.maker_fee(ctx.epoch());
    <b>let</b> quote_quantity = math::mul(remaining_quantity, price);

    <b>if</b> (is_bid) {
        // <a href="dependencies/sui-framework/transfer.md#0x2_transfer">transfer</a> quote out from <a href="account.md#0x0_account">account</a> <b>to</b> <a href="pool.md#0x0_pool">pool</a>, <a href="dependencies/sui-framework/transfer.md#0x2_transfer">transfer</a> base from <a href="pool.md#0x0_pool">pool</a> <b>to</b> <a href="account.md#0x0_account">account</a>
        <b>if</b> (self.<a href="pool.md#0x0_pool_fee_is_deep">fee_is_deep</a>()) {
            <b>let</b> deep_quantity = math::mul(maker_fee, math::mul(quote_quantity, self.deep_config.borrow().deep_per_quote()));
            self.<a href="pool.md#0x0_pool_deposit_deep">deposit_deep</a>(<a href="account.md#0x0_account">account</a>, proof, deep_quantity, ctx);
            self.<a href="pool.md#0x0_pool_deposit_quote">deposit_quote</a>(<a href="account.md#0x0_account">account</a>, proof, quote_quantity, ctx);
            deep_quantity
        } <b>else</b> {
            <b>let</b> quote_fee = math::mul(maker_fee, quote_quantity);
            self.<a href="pool.md#0x0_pool_deposit_quote">deposit_quote</a>(<a href="account.md#0x0_account">account</a>, proof, quote_quantity + quote_fee, ctx);
            quote_fee
        }
    } <b>else</b> {
        // <a href="dependencies/sui-framework/transfer.md#0x2_transfer">transfer</a> base out from <a href="account.md#0x0_account">account</a> <b>to</b> <a href="pool.md#0x0_pool">pool</a>, <a href="dependencies/sui-framework/transfer.md#0x2_transfer">transfer</a> quote from <a href="pool.md#0x0_pool">pool</a> <b>to</b> <a href="account.md#0x0_account">account</a>
        <b>if</b> (self.<a href="pool.md#0x0_pool_fee_is_deep">fee_is_deep</a>()) {
            <b>let</b> deep_quantity = math::mul(maker_fee, math::mul(remaining_quantity, self.deep_config.borrow().deep_per_base()));
            self.<a href="pool.md#0x0_pool_deposit_deep">deposit_deep</a>(<a href="account.md#0x0_account">account</a>, proof, deep_quantity, ctx);
            self.<a href="pool.md#0x0_pool_deposit_base">deposit_base</a>(<a href="account.md#0x0_account">account</a>, proof, remaining_quantity, ctx);
            deep_quantity
        } <b>else</b> {
            <b>let</b> base_fee = math::mul(maker_fee, remaining_quantity);
            self.<a href="pool.md#0x0_pool_deposit_quote">deposit_quote</a>(<a href="account.md#0x0_account">account</a>, proof, remaining_quantity + base_fee, ctx);
            base_fee
        }
    }
}
</code></pre>



</details>

<a name="0x0_pool_match_bid"></a>

## Function `match_bid`

Matches bid, returns (base_quantity_matched, quote_quantity_matched)


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_match_bid">match_bid</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, taker: <b>address</b>, order_id: u128, client_order_id: u64, quantity: u64, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_match_bid">match_bid</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    taker: <b>address</b>,
    order_id: u128,
    client_order_id: u64,
    quantity: u64, // in base asset
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
): (u64, u64) {
    <b>let</b> (<b>mut</b> ref, <b>mut</b> offset) = self.asks.slice_following(<a href="pool.md#0x0_pool_MIN_ORDER_ID">MIN_ORDER_ID</a>);
    // This means there are no asks in the book
    <b>if</b> (ref.is_null()) {
        <b>return</b> (0, 0)
    };

    <b>let</b> <b>mut</b> remaining_quantity = quantity;
    <b>let</b> <b>mut</b> net_base_quantity = 0;
    <b>let</b> <b>mut</b> net_quote_quantity = 0;
    <b>let</b> <b>mut</b> orders_to_remove = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[];

    // Fetches initial order
    <b>let</b> <b>mut</b> ask = self.asks.borrow_mut_ref_offset(ref, offset);
    <b>while</b> (remaining_quantity &gt; 0 && order_id &gt; ask.order_id) {
        <b>let</b> <b>mut</b> expired_order = <b>false</b>;
        <b>if</b> (ask.expire_timestamp &lt; <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms()) {
            expired_order = <b>true</b>;
        } <b>else</b> {
            // Match <b>with</b> existing asks
            // We want <b>to</b> buy 1 BTC, <b>if</b> there's 0.5BTC at $50k, we want <b>to</b> buy 0.5BTC at $50k
            <b>let</b> base_matched_quantity = <a href="dependencies/sui-framework/math.md#0x2_math_min">math::min</a>(ask.quantity, remaining_quantity);
            ask.quantity = ask.quantity - base_matched_quantity;
            remaining_quantity = remaining_quantity - base_matched_quantity;
            // fee_subtracted is rounded down (in case of very small fills, this can be 0)
            <b>let</b> fee_subtracted = math::div(math::mul(base_matched_quantity, ask.original_fee_quantity), ask.original_quantity);
            ask.fee_quantity = ask.fee_quantity - fee_subtracted;

            // Rounded up, because maker gets rounding advantage
            <b>let</b> quote_quantity = math::mul_round_up(base_matched_quantity, ask.price);

            // Update maker quote balances
            self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.add_user_settled_amount(ask.owner, quote_quantity, <b>false</b>);
            // Update volumes
            self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.increase_maker_volume(ask.owner, base_matched_quantity);

            <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="pool.md#0x0_pool_OrderFilled">OrderFilled</a>&lt;BaseAsset, QuoteAsset&gt;{
                pool_id: self.id.to_inner(),
                maker_order_id: ask.order_id,
                taker_order_id: order_id,
                maker_client_order_id: ask.client_order_id,
                taker_client_order_id: client_order_id,
                base_quantity: base_matched_quantity,
                quote_quantity,
                price: ask.price,
                maker_address: ask.owner,
                taker_address: taker,
                is_bid: <b>true</b>, // is a bid
                timestamp: <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms(),
            });

            net_base_quantity = net_base_quantity + base_matched_quantity;
            net_quote_quantity = net_quote_quantity + quote_quantity;
        };

        // If ask quantity is 0, remove the order
        <b>if</b> (ask.quantity == 0 || expired_order) {
            // Remove order from user's open orders
            self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.remove_user_open_order(ask.owner, ask.order_id);
            // Add order id <b>to</b> be removed
            orders_to_remove.push_back(ask.order_id);
        };

        // Traverse <b>to</b> valid next order <b>if</b> exists, otherwise <b>break</b> from <b>loop</b>
        <b>if</b> (self.asks.valid_next(ref, offset)){
            (ref, offset, ask) = self.asks.borrow_mut_next(ref, offset);
        } <b>else</b> {
            <b>break</b>
        }
    };

    // Iterate over matched_orders and remove from asks
    <b>let</b> <b>mut</b> i = 0;
    <b>while</b> (i &lt; orders_to_remove.length()) {
        self.asks.remove(orders_to_remove[i]);
        i = i + 1;
    };

    (net_base_quantity, net_quote_quantity)
}
</code></pre>



</details>

<a name="0x0_pool_match_ask"></a>

## Function `match_ask`

Matches ask, returns (base_quantity_matched, quote_quantity_matched)


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_match_ask">match_ask</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, taker: <b>address</b>, order_id: u128, client_order_id: u64, quantity: u64, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_match_ask">match_ask</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    taker: <b>address</b>,
    order_id: u128,
    client_order_id: u64,
    quantity: u64, // in base asset
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
): (u64, u64) {
    <b>let</b> (<b>mut</b> ref, <b>mut</b> offset) = self.bids.slice_before(<a href="pool.md#0x0_pool_MAX_ORDER_ID">MAX_ORDER_ID</a>);
    // This means there are no bids in the book
    <b>if</b> (ref.is_null()) {
        <b>return</b> (0, 0)
    };

    <b>let</b> <b>mut</b> remaining_quantity = quantity;
    <b>let</b> <b>mut</b> net_base_quantity = 0;
    <b>let</b> <b>mut</b> net_quote_quantity = 0;
    <b>let</b> <b>mut</b> orders_to_remove = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[];

    <b>let</b> <b>mut</b> bid = self.bids.borrow_mut_ref_offset(ref, offset);
    <b>while</b> (remaining_quantity &gt; 0 && order_id &lt; bid.order_id ) {
        <b>let</b> <b>mut</b> expired_order = <b>false</b>;
        <b>if</b> (bid.expire_timestamp &lt; <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms()) {
            expired_order = <b>true</b>;
        } <b>else</b> {
            // Match <b>with</b> existing bids
            // We want <b>to</b> sell 1 BTC, <b>if</b> there's bid 0.5BTC at $50k, we want <b>to</b> sell 0.5BTC at $50k
            <b>let</b> base_matched_quantity = <a href="dependencies/sui-framework/math.md#0x2_math_min">math::min</a>(bid.quantity, remaining_quantity);
            bid.quantity = bid.quantity - base_matched_quantity;
            remaining_quantity = remaining_quantity - base_matched_quantity;
            // fee_subtracted is rounded down (in case of very small fills, this can be 0)
            <b>let</b> fee_subtracted = math::div(math::mul(base_matched_quantity, bid.original_fee_quantity), bid.original_quantity);
            bid.fee_quantity = bid.fee_quantity - fee_subtracted;

            // Rounded up, because maker gets rounding advantage
            <b>let</b> quote_quantity = math::mul_round_up(base_matched_quantity, bid.price);

            // Update maker base balances
            self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.add_user_settled_amount(bid.owner, base_matched_quantity, <b>true</b>);
            // Update volumes
            self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.increase_maker_volume(bid.owner, base_matched_quantity);

            <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="pool.md#0x0_pool_OrderFilled">OrderFilled</a>&lt;BaseAsset, QuoteAsset&gt;{
                pool_id: self.id.to_inner(),
                maker_order_id: bid.order_id,
                taker_order_id: order_id,
                maker_client_order_id: bid.client_order_id,
                taker_client_order_id: client_order_id,
                base_quantity: base_matched_quantity,
                quote_quantity,
                price: bid.price,
                maker_address: bid.owner,
                taker_address: taker,
                is_bid: <b>false</b>, // is an ask
                timestamp: <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms(),
            });

            net_base_quantity = net_base_quantity + base_matched_quantity;
            net_quote_quantity = net_quote_quantity + math::mul(base_matched_quantity, bid.price);
        };

        // If bid quantity is 0, remove the order
        <b>if</b> (bid.quantity == 0 || expired_order) {
            // Remove order from user's open orders
            self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.remove_user_open_order(bid.owner, bid.order_id);
            // Add order id <b>to</b> be removed
            orders_to_remove.push_back(bid.order_id);
        };

        // Traverse <b>to</b> valid next order <b>if</b> exists, otherwise <b>break</b> from <b>loop</b>
        <b>if</b> (self.bids.valid_prev(ref, offset)){
            (ref, offset, bid) = self.bids.borrow_prev_mut(ref, offset);
        } <b>else</b> {
            <b>break</b>
        }
    };

    // Iterate over matched_orders and remove from bids
    <b>let</b> <b>mut</b> i = 0;
    <b>while</b> (i &lt; orders_to_remove.length()) {
        self.bids.remove(orders_to_remove[i]);
        i = i + 1;
    };

    (net_base_quantity, net_quote_quantity)
}
</code></pre>



</details>

<a name="0x0_pool_place_market_order"></a>

## Function `place_market_order`

Place a market order to the order book.
Will return (settled_base_quantity, settled_quote_quantity)


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_place_market_order">place_market_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, client_order_id: u64, quantity: u64, is_bid: bool, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_place_market_order">place_market_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    client_order_id: u64,
    quantity: u64, // in base asset
    is_bid: bool, // <b>true</b> for bid, <b>false</b> for ask
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &<b>mut</b> TxContext,
): (u64, u64) {
    // Refresh <a href="state.md#0x0_state">state</a> <b>as</b> necessary <b>if</b> first order of epoch
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.refresh(ctx.epoch());

    <b>assert</b>!(quantity &gt;= self.min_size, <a href="pool.md#0x0_pool_EOrderBelowMinimumSize">EOrderBelowMinimumSize</a>);
    <b>assert</b>!(quantity % self.lot_size == 0, <a href="pool.md#0x0_pool_EOrderInvalidLotSize">EOrderInvalidLotSize</a>);

    <b>let</b> price = <b>if</b> (is_bid) {
        <a href="pool.md#0x0_pool_MAX_PRICE">MAX_PRICE</a>
    } <b>else</b> {
        <a href="pool.md#0x0_pool_MIN_PRICE">MIN_PRICE</a>
    };

    <b>let</b> order_id = encode_order_id(is_bid, price, self.<a href="pool.md#0x0_pool_get_order_id">get_order_id</a>(is_bid));
    <b>let</b> (net_base_quantity, net_quote_quantity) =
        <b>if</b> (is_bid) {
            self.<a href="pool.md#0x0_pool_match_bid">match_bid</a>(<a href="account.md#0x0_account">account</a>.owner(), order_id, client_order_id, quantity, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>)
        } <b>else</b> {
            self.<a href="pool.md#0x0_pool_match_ask">match_ask</a>(<a href="account.md#0x0_account">account</a>.owner(), order_id, client_order_id, quantity, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>)
        };

    self.<a href="pool.md#0x0_pool_transfer_taker">transfer_taker</a>(<a href="account.md#0x0_account">account</a>, proof, net_base_quantity, net_quote_quantity, is_bid, ctx);

    <b>if</b> (is_bid) {
        (net_base_quantity, 0)
    } <b>else</b> {
        (0, net_quote_quantity)
    }
}
</code></pre>



</details>

<a name="0x0_pool_get_amount_out"></a>

## Function `get_amount_out`

Given an amount in and direction, calculate amount out
Will return (amount_out, amount_in_used)


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_get_amount_out">get_amount_out</a>&lt;BaseAsset, QuoteAsset&gt;(_self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, _amount_in: u64, _is_bid: bool): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_get_amount_out">get_amount_out</a>&lt;BaseAsset, QuoteAsset&gt;(
    _self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    _amount_in: u64,
    _is_bid: bool,
): u64 {
    // TODO: implement
    0
}
</code></pre>



</details>

<a name="0x0_pool_get_level2_bids"></a>

## Function `get_level2_bids`

Get the level2 bids between price_low and price_high.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_get_level2_bids">get_level2_bids</a>&lt;BaseAsset, QuoteAsset&gt;(_self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, _price_low: u64, _price_high: u64): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_get_level2_bids">get_level2_bids</a>&lt;BaseAsset, QuoteAsset&gt;(
    _self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    _price_low: u64,
    _price_high: u64,
): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;) {
    // TODO: implement
    (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[], <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[])
}
</code></pre>



</details>

<a name="0x0_pool_get_level2_asks"></a>

## Function `get_level2_asks`

Get the level2 bids between price_low and price_high.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_get_level2_asks">get_level2_asks</a>&lt;BaseAsset, QuoteAsset&gt;(_self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, _price_low: u64, _price_high: u64): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_get_level2_asks">get_level2_asks</a>&lt;BaseAsset, QuoteAsset&gt;(
    _self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    _price_low: u64,
    _price_high: u64,
): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;) {
    // TODO: implement
    (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[], <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[])
}
</code></pre>



</details>

<a name="0x0_pool_get_level2_ticks_from_mid"></a>

## Function `get_level2_ticks_from_mid`

Get the n ticks from the mid price


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_get_level2_ticks_from_mid">get_level2_ticks_from_mid</a>&lt;BaseAsset, QuoteAsset&gt;(_self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, _ticks: u64): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_get_level2_ticks_from_mid">get_level2_ticks_from_mid</a>&lt;BaseAsset, QuoteAsset&gt;(
    _self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    _ticks: u64,
): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;) {
    // TODO: implement
    (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[], <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[])
}
</code></pre>



</details>

<a name="0x0_pool_cancel_order"></a>

## Function `cancel_order`

Cancel an order by order_id. Withdraw settled funds back into user account.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_cancel_order">cancel_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, order_id: u128, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="pool.md#0x0_pool_Order">pool::Order</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_cancel_order">cancel_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    order_id: u128,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &<b>mut</b> TxContext,
): <a href="pool.md#0x0_pool_Order">Order</a> {
    // <a href="pool.md#0x0_pool_Order">Order</a> cancelled and returned
    <b>let</b> cancelled_order = self.<a href="pool.md#0x0_pool_internal_cancel_order">internal_cancel_order</a>(order_id);

    // remove order from user's open orders
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.remove_user_open_order(<a href="account.md#0x0_account">account</a>.owner(), order_id);

    // withdraw main assets back into user <a href="account.md#0x0_account">account</a>
    <b>if</b> (cancelled_order.is_bid) {
        // deposit quote asset back into user <a href="account.md#0x0_account">account</a>
        <b>let</b> <b>mut</b> quote_quantity = math::mul(cancelled_order.quantity, cancelled_order.price);
        <b>if</b> (!cancelled_order.fee_is_deep) {
            quote_quantity = quote_quantity + cancelled_order.fee_quantity;
        };
        self.<a href="pool.md#0x0_pool_withdraw_quote">withdraw_quote</a>(<a href="account.md#0x0_account">account</a>, proof, quote_quantity, ctx)
    } <b>else</b> {
        // deposit base asset back into user <a href="account.md#0x0_account">account</a>
        <b>let</b> <b>mut</b> base_quantity = cancelled_order.quantity;
        <b>if</b> (!cancelled_order.fee_is_deep) {
            base_quantity = base_quantity + cancelled_order.fee_quantity;
        };
        self.<a href="pool.md#0x0_pool_withdraw_base">withdraw_base</a>(<a href="account.md#0x0_account">account</a>, proof, base_quantity, ctx)
    };

    // withdraw fees into user <a href="account.md#0x0_account">account</a>
    // <b>if</b> <a href="pool.md#0x0_pool">pool</a> is verified at the time of order placement, fees are in <a href="deepbook.md#0x0_deepbook">deepbook</a> tokens
    <b>if</b> (cancelled_order.fee_is_deep) {
        // withdraw <a href="deepbook.md#0x0_deepbook">deepbook</a> fees
        self.<a href="pool.md#0x0_pool_withdraw_deep">withdraw_deep</a>(<a href="account.md#0x0_account">account</a>, proof, cancelled_order.fee_quantity, ctx)
    };

    // Emit order cancelled <a href="dependencies/sui-framework/event.md#0x2_event">event</a>
    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="pool.md#0x0_pool_OrderCanceled">OrderCanceled</a>&lt;BaseAsset, QuoteAsset&gt; {
        pool_id: self.id.to_inner(), // Get inner id from UID
        order_id: cancelled_order.order_id,
        client_order_id: cancelled_order.client_order_id,
        is_bid: cancelled_order.is_bid,
        owner: cancelled_order.owner,
        original_quantity: cancelled_order.original_quantity,
        base_asset_quantity_canceled: cancelled_order.quantity,
        price: cancelled_order.price,
        timestamp: <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms(),
    });

    cancelled_order
}
</code></pre>



</details>

<a name="0x0_pool_claim_rebates"></a>

## Function `claim_rebates`

Claim the rebates for the user


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_claim_rebates">claim_rebates</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_claim_rebates">claim_rebates</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    ctx: &<b>mut</b> TxContext
) {
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.refresh(ctx.epoch());
    <b>let</b> amount = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.reset_user_rebates(<a href="account.md#0x0_account">account</a>.owner());
    <b>let</b> <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a> = self.deepbook_balance.split(amount).into_coin(ctx);
    <a href="account.md#0x0_account">account</a>.deposit_with_proof&lt;<a href="pool.md#0x0_pool_DEEP">DEEP</a>&gt;(proof, <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>);
}
</code></pre>



</details>

<a name="0x0_pool_cancel_all"></a>

## Function `cancel_all`

Cancel all orders for an account. Withdraw settled funds back into user account.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_cancel_all">cancel_all</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="pool.md#0x0_pool_Order">pool::Order</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_cancel_all">cancel_all</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &<b>mut</b> TxContext,
): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="pool.md#0x0_pool_Order">Order</a>&gt;{
    <b>let</b> <b>mut</b> cancelled_orders = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[];
    <b>let</b> user_open_orders = self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.<a href="pool.md#0x0_pool_user_open_orders">user_open_orders</a>(<a href="account.md#0x0_account">account</a>.owner());

    <b>let</b> orders_vector = user_open_orders.into_keys();
    <b>let</b> len = orders_vector.length();
    <b>let</b> <b>mut</b> i = 0;
    <b>while</b> (i &lt; len) {
        <b>let</b> key = orders_vector[i];
        <b>let</b> cancelled_order = <a href="pool.md#0x0_pool_cancel_order">cancel_order</a>(self, <a href="account.md#0x0_account">account</a>, proof, key, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>, ctx);
        cancelled_orders.push_back(cancelled_order);
        i = i + 1;
    };

    cancelled_orders
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

Creates a new pool for trading and returns pool_key, called by state module


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_create_pool">create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(taker_fee: u64, maker_fee: u64, tick_size: u64, lot_size: u64, min_size: u64, creation_fee: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;<a href="dependencies/sui-framework/sui.md#0x2_sui_SUI">sui::SUI</a>&gt;, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_create_pool">create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(
    taker_fee: u64,
    maker_fee: u64,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    creation_fee: Balance&lt;SUI&gt;,
    ctx: &<b>mut</b> TxContext,
): <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt; {
    <b>assert</b>!(creation_fee.value() == <a href="pool.md#0x0_pool_POOL_CREATION_FEE">POOL_CREATION_FEE</a>, <a href="pool.md#0x0_pool_EInvalidFee">EInvalidFee</a>);
    <b>assert</b>!(tick_size &gt; 0, <a href="pool.md#0x0_pool_EInvalidTickSize">EInvalidTickSize</a>);
    <b>assert</b>!(lot_size &gt; 0, <a href="pool.md#0x0_pool_EInvalidLotSize">EInvalidLotSize</a>);
    <b>assert</b>!(min_size &gt; 0, <a href="pool.md#0x0_pool_EInvalidMinSize">EInvalidMinSize</a>);

    <b>assert</b>!(<a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;BaseAsset&gt;() != <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;QuoteAsset&gt;(), <a href="pool.md#0x0_pool_ESameBaseAndQuote">ESameBaseAndQuote</a>);

    <b>let</b> pool_uid = <a href="dependencies/sui-framework/object.md#0x2_object_new">object::new</a>(ctx);

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
        bids: <a href="big_vector.md#0x0_big_vector_empty">big_vector::empty</a>(10000, 1000, ctx), // TODO: what are these numbers
        asks: <a href="big_vector.md#0x0_big_vector_empty">big_vector::empty</a>(10000, 1000, ctx), // TODO: ditto
        next_bid_order_id: <a href="pool.md#0x0_pool_START_BID_ORDER_ID">START_BID_ORDER_ID</a>,
        next_ask_order_id: <a href="pool.md#0x0_pool_START_ASK_ORDER_ID">START_ASK_ORDER_ID</a>,
        deep_config: <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(),
        tick_size,
        lot_size,
        min_size,
        base_balances: <a href="dependencies/sui-framework/balance.md#0x2_balance_zero">balance::zero</a>(),
        quote_balances: <a href="dependencies/sui-framework/balance.md#0x2_balance_zero">balance::zero</a>(),
        deepbook_balance: <a href="dependencies/sui-framework/balance.md#0x2_balance_zero">balance::zero</a>(),
        <a href="state_manager.md#0x0_state_manager">state_manager</a>: <a href="state_manager.md#0x0_state_manager_new">state_manager::new</a>(taker_fee, maker_fee, 0, ctx),
    });

    // TODO: reconsider sending the Coin here. User pays gas;
    // TODO: depending on the frequency of the <a href="dependencies/sui-framework/event.md#0x2_event">event</a>;
    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_public_transfer">transfer::public_transfer</a>(creation_fee.into_coin(ctx), <a href="pool.md#0x0_pool_TREASURY_ADDRESS">TREASURY_ADDRESS</a>);

    <a href="pool.md#0x0_pool">pool</a>
}
</code></pre>



</details>

<a name="0x0_pool_increase_user_stake"></a>

## Function `increase_user_stake`

Increase a user's stake


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_increase_user_stake">increase_user_stake</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user: <b>address</b>, amount: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_increase_user_stake">increase_user_stake</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    user: <b>address</b>,
    amount: u64,
    ctx: &TxContext,
): (u64, u64) {
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.refresh(ctx.epoch());

    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.<a href="pool.md#0x0_pool_increase_user_stake">increase_user_stake</a>(user, amount)
}
</code></pre>



</details>

<a name="0x0_pool_remove_user_stake"></a>

## Function `remove_user_stake`

Removes a user's stake.
Returns the total amount staked before this epoch and the total amount staked during this epoch.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_remove_user_stake">remove_user_stake</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user: <b>address</b>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_remove_user_stake">remove_user_stake</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    user: <b>address</b>,
    ctx: &TxContext
): (u64, u64) {
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.refresh(ctx.epoch());

    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.<a href="pool.md#0x0_pool_remove_user_stake">remove_user_stake</a>(user)
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


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_add_deep_price_point">add_deep_price_point</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, base_conversion_rate: u64, quote_conversion_rate: u64, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_add_deep_price_point">add_deep_price_point</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    base_conversion_rate: u64,
    quote_conversion_rate: u64,
    timestamp: u64,
) {
    <b>if</b> (self.deep_config.is_none()) {
        self.deep_config.fill(<a href="deep_price.md#0x0_deep_price_empty">deep_price::empty</a>());
    };
    self.deep_config
        .borrow_mut()
        .add_price_point(base_conversion_rate, quote_conversion_rate, timestamp);
}
</code></pre>



</details>

<a name="0x0_pool_set_next_trade_params"></a>

## Function `set_next_trade_params`

Update the pool's next pool state.
During an epoch refresh, the current pool state is moved to historical pool state.
The next pool state is moved to current pool state.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_set_next_trade_params">set_next_trade_params</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, fees: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="state_manager.md#0x0_state_manager_TradeParams">state_manager::TradeParams</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_set_next_trade_params">set_next_trade_params</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    fees: Option&lt;TradeParams&gt;,
) {
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.<a href="pool.md#0x0_pool_set_next_trade_params">set_next_trade_params</a>(fees);
}
</code></pre>



</details>

<a name="0x0_pool_get_base_quote_types"></a>

## Function `get_base_quote_types`

Get the base and quote asset of pool, return as ascii strings


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_get_base_quote_types">get_base_quote_types</a>&lt;BaseAsset, QuoteAsset&gt;(_self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;): (<a href="dependencies/move-stdlib/ascii.md#0x1_ascii_String">ascii::String</a>, <a href="dependencies/move-stdlib/ascii.md#0x1_ascii_String">ascii::String</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_get_base_quote_types">get_base_quote_types</a>&lt;BaseAsset, QuoteAsset&gt;(
    _self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;
): (String, String) {
    (
        <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;BaseAsset&gt;().into_string(),
        <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;QuoteAsset&gt;().into_string()
    )
}
</code></pre>



</details>

<a name="0x0_pool_key"></a>

## Function `key`

Get the pool key string base+quote (if base, quote in lexicographic order) otherwise return quote+base
TODO: Why is this needed as a key? Why don't we just use the ID of the pool as an ID?


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_key">key</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;): <a href="dependencies/move-stdlib/ascii.md#0x1_ascii_String">ascii::String</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool.md#0x0_pool_key">key</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;
): String {
    <b>let</b> (base, quote) = <a href="pool.md#0x0_pool_get_base_quote_types">get_base_quote_types</a>(self);
    <b>if</b> (<a href="utils.md#0x0_utils_compare">utils::compare</a>(&base, &quote)) {
        <a href="utils.md#0x0_utils_concat_ascii">utils::concat_ascii</a>(base, quote)
    } <b>else</b> {
        <a href="utils.md#0x0_utils_concat_ascii">utils::concat_ascii</a>(quote, base)
    }
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

<a name="0x0_pool_deposit_base"></a>

## Function `deposit_base`

This will be automatically called if not enough assets in settled_funds for a trade
User cannot manually deposit. Funds are withdrawn from user account and merged into pool balances.


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_deposit_base">deposit_base</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user_account: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, amount: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_deposit_base">deposit_base</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    user_account: &<b>mut</b> Account,
    proof: &TradeProof,
    amount: u64,
    ctx: &<b>mut</b> TxContext,
) {
    <b>let</b> base = user_account.withdraw_with_proof&lt;BaseAsset&gt;(proof, amount, ctx);
    self.base_balances.join(base.into_balance());
}
</code></pre>



</details>

<a name="0x0_pool_deposit_quote"></a>

## Function `deposit_quote`



<pre><code><b>fun</b> <a href="pool.md#0x0_pool_deposit_quote">deposit_quote</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user_account: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, amount: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_deposit_quote">deposit_quote</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    user_account: &<b>mut</b> Account,
    proof: &TradeProof,
    amount: u64,
    ctx: &<b>mut</b> TxContext,
) {
    <b>let</b> quote = user_account.withdraw_with_proof&lt;QuoteAsset&gt;(proof, amount, ctx);
    self.quote_balances.join(quote.into_balance());
}
</code></pre>



</details>

<a name="0x0_pool_deposit_deep"></a>

## Function `deposit_deep`



<pre><code><b>fun</b> <a href="pool.md#0x0_pool_deposit_deep">deposit_deep</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user_account: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, amount: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_deposit_deep">deposit_deep</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    user_account: &<b>mut</b> Account,
    proof: &TradeProof,
    amount: u64,
    ctx: &<b>mut</b> TxContext,
) {
    <b>let</b> <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a> = user_account.withdraw_with_proof&lt;<a href="pool.md#0x0_pool_DEEP">DEEP</a>&gt;(proof, amount, ctx);
    self.deepbook_balance.join(<a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>.into_balance());
}
</code></pre>



</details>

<a name="0x0_pool_withdraw_base"></a>

## Function `withdraw_base`



<pre><code><b>fun</b> <a href="pool.md#0x0_pool_withdraw_base">withdraw_base</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user_account: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, amount: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_withdraw_base">withdraw_base</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    user_account: &<b>mut</b> Account,
    proof: &TradeProof,
    amount: u64,
    ctx: &<b>mut</b> TxContext,
) {
    <b>let</b> <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a> = self.base_balances.split(amount).into_coin(ctx);
    user_account.deposit_with_proof&lt;BaseAsset&gt;(proof, <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>);
}
</code></pre>



</details>

<a name="0x0_pool_withdraw_quote"></a>

## Function `withdraw_quote`



<pre><code><b>fun</b> <a href="pool.md#0x0_pool_withdraw_quote">withdraw_quote</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user_account: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, amount: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_withdraw_quote">withdraw_quote</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    user_account: &<b>mut</b> Account,
    proof: &TradeProof,
    amount: u64,
    ctx: &<b>mut</b> TxContext,
) {
    <b>let</b> <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a> = self.quote_balances.split(amount).into_coin(ctx);
    user_account.deposit_with_proof&lt;QuoteAsset&gt;(proof, <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>);
}
</code></pre>



</details>

<a name="0x0_pool_withdraw_deep"></a>

## Function `withdraw_deep`



<pre><code><b>fun</b> <a href="pool.md#0x0_pool_withdraw_deep">withdraw_deep</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user_account: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, amount: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_withdraw_deep">withdraw_deep</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    user_account: &<b>mut</b> Account,
    proof: &TradeProof,
    amount: u64,
    ctx: &<b>mut</b> TxContext,
) {
    <b>let</b> <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a> = self.deepbook_balance.split(amount).into_coin(ctx);
    user_account.deposit_with_proof&lt;<a href="pool.md#0x0_pool_DEEP">DEEP</a>&gt;(proof, <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>);
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

<a name="0x0_pool_internal_inject_limit_order"></a>

## Function `internal_inject_limit_order`

Balance accounting happens before this function is called


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_internal_inject_limit_order">internal_inject_limit_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, order_id: u128, client_order_id: u64, order_type: u8, price: u64, quantity: u64, fee_quantity: u64, is_bid: bool, expire_timestamp: u64, owner: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_internal_inject_limit_order">internal_inject_limit_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    order_id: u128,
    client_order_id: u64,
    order_type: u8,
    price: u64,
    quantity: u64,
    fee_quantity: u64,
    is_bid: bool, // <b>true</b> for bid, <b>false</b> for ask
    expire_timestamp: u64, // Expiration timestamp in ms
    owner: <b>address</b>,
) {

    // Create <a href="pool.md#0x0_pool_Order">Order</a>
    <b>let</b> order = <a href="pool.md#0x0_pool_Order">Order</a> {
        order_id,
        client_order_id,
        order_type,
        price,
        original_quantity: quantity,
        quantity,
        original_fee_quantity: fee_quantity,
        fee_quantity,
        fee_is_deep: self.<a href="pool.md#0x0_pool_fee_is_deep">fee_is_deep</a>(),
        is_bid,
        owner,
        expire_timestamp,
        self_matching_prevention: 0, // TODO
    };

    // Insert order into order books
    <b>if</b> (is_bid){
        self.bids.insert(order_id, order);
    } <b>else</b> {
        self.asks.insert(order_id, order);
    };

    // Add order <b>to</b> user's open orders
    self.<a href="state_manager.md#0x0_state_manager">state_manager</a>.add_user_open_order(owner, order_id);
}
</code></pre>



</details>

<a name="0x0_pool_internal_cancel_order"></a>

## Function `internal_cancel_order`

Cancels an order and returns the order details


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_internal_cancel_order">internal_cancel_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, order_id: u128): <a href="pool.md#0x0_pool_Order">pool::Order</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_internal_cancel_order">internal_cancel_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    order_id: u128,
): <a href="pool.md#0x0_pool_Order">Order</a> {
    <b>if</b> (<a href="pool.md#0x0_pool_order_is_bid">order_is_bid</a>(order_id)) {
        self.bids.remove(order_id)
    } <b>else</b> {
        self.asks.remove(order_id)
    }
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

<a name="0x0_pool_fee_is_deep"></a>

## Function `fee_is_deep`

Returns if the order fee is paid in deep tokens


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_fee_is_deep">fee_is_deep</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_fee_is_deep">fee_is_deep</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;
): bool {
    self.deep_config.is_some()
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
    <b>let</b> burnt = self.deepbook_balance.split(amount);
    tcap.supply_mut().decrease_supply(burnt);
}
</code></pre>



</details>
