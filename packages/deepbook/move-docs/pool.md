
<a name="0x0_pool"></a>

# Module `0x0::pool`

Public-facing interface for the package.


-  [Resource `Pool`](#0x0_pool_Pool)
-  [Struct `PoolInner`](#0x0_pool_PoolInner)
-  [Struct `PoolCreated`](#0x0_pool_PoolCreated)
-  [Constants](#@Constants_0)
-  [Function `create_pool_admin`](#0x0_pool_create_pool_admin)
-  [Function `place_limit_order`](#0x0_pool_place_limit_order)
-  [Function `place_market_order`](#0x0_pool_place_market_order)
-  [Function `swap_exact_base_for_quote`](#0x0_pool_swap_exact_base_for_quote)
-  [Function `swap_exact_quote_for_base`](#0x0_pool_swap_exact_quote_for_base)
-  [Function `modify_order`](#0x0_pool_modify_order)
-  [Function `cancel_order`](#0x0_pool_cancel_order)
-  [Function `cancel_all_orders`](#0x0_pool_cancel_all_orders)
-  [Function `withdraw_settled_amounts`](#0x0_pool_withdraw_settled_amounts)
-  [Function `stake`](#0x0_pool_stake)
-  [Function `unstake`](#0x0_pool_unstake)
-  [Function `submit_proposal`](#0x0_pool_submit_proposal)
-  [Function `vote`](#0x0_pool_vote)
-  [Function `claim_rebates`](#0x0_pool_claim_rebates)
-  [Function `add_deep_price_point`](#0x0_pool_add_deep_price_point)
-  [Function `burn_deep`](#0x0_pool_burn_deep)
-  [Function `whitelisted`](#0x0_pool_whitelisted)
-  [Function `get_amount_out`](#0x0_pool_get_amount_out)
-  [Function `mid_price`](#0x0_pool_mid_price)
-  [Function `account_open_orders`](#0x0_pool_account_open_orders)
-  [Function `get_level2_range`](#0x0_pool_get_level2_range)
-  [Function `get_level2_ticks_from_mid`](#0x0_pool_get_level2_ticks_from_mid)
-  [Function `vault_balances`](#0x0_pool_vault_balances)
-  [Function `get_pool_id_by_asset`](#0x0_pool_get_pool_id_by_asset)
-  [Function `set_stable`](#0x0_pool_set_stable)
-  [Function `unregister_pool_admin`](#0x0_pool_unregister_pool_admin)
-  [Function `create_pool`](#0x0_pool_create_pool)
-  [Function `bids`](#0x0_pool_bids)
-  [Function `asks`](#0x0_pool_asks)
-  [Function `load_inner`](#0x0_pool_load_inner)
-  [Function `load_inner_mut`](#0x0_pool_load_inner_mut)
-  [Function `set_whitelist`](#0x0_pool_set_whitelist)
-  [Function `swap_exact_amount`](#0x0_pool_swap_exact_amount)
-  [Function `place_order_int`](#0x0_pool_place_order_int)


<pre><code><b>use</b> <a href="account.md#0x0_account">0x0::account</a>;
<b>use</b> <a href="balance_manager.md#0x0_balance_manager">0x0::balance_manager</a>;
<b>use</b> <a href="balances.md#0x0_balances">0x0::balances</a>;
<b>use</b> <a href="big_vector.md#0x0_big_vector">0x0::big_vector</a>;
<b>use</b> <a href="book.md#0x0_book">0x0::book</a>;
<b>use</b> <a href="constants.md#0x0_constants">0x0::constants</a>;
<b>use</b> <a href="deep_price.md#0x0_deep_price">0x0::deep_price</a>;
<b>use</b> <a href="governance.md#0x0_governance">0x0::governance</a>;
<b>use</b> <a href="history.md#0x0_history">0x0::history</a>;
<b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="order.md#0x0_order">0x0::order</a>;
<b>use</b> <a href="order_info.md#0x0_order_info">0x0::order_info</a>;
<b>use</b> <a href="registry.md#0x0_registry">0x0::registry</a>;
<b>use</b> <a href="state.md#0x0_state">0x0::state</a>;
<b>use</b> <a href="trade_params.md#0x0_trade_params">0x0::trade_params</a>;
<b>use</b> <a href="vault.md#0x0_vault">0x0::vault</a>;
<b>use</b> <a href="dependencies/move-stdlib/type_name.md#0x1_type_name">0x1::type_name</a>;
<b>use</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">0x1::vector</a>;
<b>use</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">0x2::balance</a>;
<b>use</b> <a href="dependencies/sui-framework/clock.md#0x2_clock">0x2::clock</a>;
<b>use</b> <a href="dependencies/sui-framework/coin.md#0x2_coin">0x2::coin</a>;
<b>use</b> <a href="dependencies/sui-framework/event.md#0x2_event">0x2::event</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
<b>use</b> <a href="dependencies/sui-framework/transfer.md#0x2_transfer">0x2::transfer</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
<b>use</b> <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set">0x2::vec_set</a>;
<b>use</b> <a href="dependencies/sui-framework/versioned.md#0x2_versioned">0x2::versioned</a>;
<b>use</b> <a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep">0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep</a>;
</code></pre>



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
<code>inner: <a href="dependencies/sui-framework/versioned.md#0x2_versioned_Versioned">versioned::Versioned</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_pool_PoolInner"></a>

## Struct `PoolInner`



<pre><code><b>struct</b> <a href="pool.md#0x0_pool_PoolInner">PoolInner</a>&lt;BaseAsset, QuoteAsset&gt; <b>has</b> store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>disabled_versions: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>

</dd>
<dt>
<code><a href="book.md#0x0_book">book</a>: <a href="book.md#0x0_book_Book">book::Book</a></code>
</dt>
<dd>

</dd>
<dt>
<code><a href="state.md#0x0_state">state</a>: <a href="state.md#0x0_state_State">state::State</a></code>
</dt>
<dd>

</dd>
<dt>
<code><a href="vault.md#0x0_vault">vault</a>: <a href="vault.md#0x0_vault_Vault">vault::Vault</a>&lt;BaseAsset, QuoteAsset&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code><a href="deep_price.md#0x0_deep_price">deep_price</a>: <a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_pool_PoolCreated"></a>

## Struct `PoolCreated`



<pre><code><b>struct</b> <a href="pool.md#0x0_pool_PoolCreated">PoolCreated</a>&lt;BaseAsset, QuoteAsset&gt; <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>

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
<dt>
<code>whitelisted_pool: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>treasury_address: <b>address</b></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_pool_EInvalidAmountIn"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidAmountIn">EInvalidAmountIn</a>: u64 = 6;
</code></pre>



<a name="0x0_pool_CURRENT_VERSION"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_CURRENT_VERSION">CURRENT_VERSION</a>: u64 = 1;
</code></pre>



<a name="0x0_pool_EFeeTypeNotSupported"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EFeeTypeNotSupported">EFeeTypeNotSupported</a>: u64 = 9;
</code></pre>



<a name="0x0_pool_EIneligibleReferencePool"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EIneligibleReferencePool">EIneligibleReferencePool</a>: u64 = 8;
</code></pre>



<a name="0x0_pool_EIneligibleTargetPool"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EIneligibleTargetPool">EIneligibleTargetPool</a>: u64 = 11;
</code></pre>



<a name="0x0_pool_EIneligibleWhitelist"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EIneligibleWhitelist">EIneligibleWhitelist</a>: u64 = 7;
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



<a name="0x0_pool_EInvalidOrderBalanceManager"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidOrderBalanceManager">EInvalidOrderBalanceManager</a>: u64 = 10;
</code></pre>



<a name="0x0_pool_EInvalidTickSize"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidTickSize">EInvalidTickSize</a>: u64 = 3;
</code></pre>



<a name="0x0_pool_ENoAmountToBurn"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_ENoAmountToBurn">ENoAmountToBurn</a>: u64 = 12;
</code></pre>



<a name="0x0_pool_EPackageVersionDisabled"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EPackageVersionDisabled">EPackageVersionDisabled</a>: u64 = 13;
</code></pre>



<a name="0x0_pool_ESameBaseAndQuote"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_ESameBaseAndQuote">ESameBaseAndQuote</a>: u64 = 2;
</code></pre>



<a name="0x0_pool_create_pool_admin"></a>

## Function `create_pool_admin`

Create a new pool. The pool is registered in the registry.
Checks are performed to ensure the tick size, lot size, and min size are valid.
The creation fee is transferred to the treasury address.
Returns the id of the pool created


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_create_pool_admin">create_pool_admin</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="registry.md#0x0_registry">registry</a>: &<b>mut</b> <a href="registry.md#0x0_registry_Registry">registry::Registry</a>, tick_size: u64, lot_size: u64, min_size: u64, creation_fee: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>&gt;, whitelisted_pool: bool, _cap: &<a href="registry.md#0x0_registry_DeepbookAdminCap">registry::DeepbookAdminCap</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_create_pool_admin">create_pool_admin</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="registry.md#0x0_registry">registry</a>: &<b>mut</b> Registry,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    creation_fee: Coin&lt;DEEP&gt;,
    whitelisted_pool: bool,
    _cap: &DeepbookAdminCap,
    ctx: &<b>mut</b> TxContext,
): ID {
    <a href="pool.md#0x0_pool_create_pool">create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(
        <a href="registry.md#0x0_registry">registry</a>,
        tick_size,
        lot_size,
        min_size,
        creation_fee,
        whitelisted_pool,
        ctx,
    )
}
</code></pre>



</details>

<a name="0x0_pool_place_limit_order"></a>

## Function `place_limit_order`

Place a limit order. Quantity is in base asset terms.
For current version pay_with_deep must be true, so the fee will be paid with DEEP tokens.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_place_limit_order">place_limit_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, client_order_id: u64, order_type: u8, self_matching_option: u8, price: u64, quantity: u64, is_bid: bool, pay_with_deep: bool, expire_timestamp: u64, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_place_limit_order">place_limit_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> BalanceManager,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &TxContext,
): OrderInfo {
    self.<a href="pool.md#0x0_pool_place_order_int">place_order_int</a>(
        <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>,
        client_order_id,
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>,
        <b>false</b>,
        ctx,
    )
}
</code></pre>



</details>

<a name="0x0_pool_place_market_order"></a>

## Function `place_market_order`

Place a market order. Quantity is in base asset terms. Calls place_limit_order with
a price of MAX_PRICE for bids and MIN_PRICE for asks. Any quantity not filled is cancelled.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_place_market_order">place_market_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, client_order_id: u64, self_matching_option: u8, quantity: u64, is_bid: bool, pay_with_deep: bool, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_place_market_order">place_market_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> BalanceManager,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &TxContext,
): OrderInfo {
    self.<a href="pool.md#0x0_pool_place_order_int">place_order_int</a>(
        <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>,
        client_order_id,
        <a href="constants.md#0x0_constants_immediate_or_cancel">constants::immediate_or_cancel</a>(),
        self_matching_option,
        <b>if</b> (is_bid) <a href="constants.md#0x0_constants_max_price">constants::max_price</a>() <b>else</b> <a href="constants.md#0x0_constants_min_price">constants::min_price</a>(),
        quantity,
        is_bid,
        pay_with_deep,
        <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms(),
        <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>,
        <b>true</b>,
        ctx,
    )
}
</code></pre>



</details>

<a name="0x0_pool_swap_exact_base_for_quote"></a>

## Function `swap_exact_base_for_quote`

Swap exact base amount without needing a <code><a href="balance_manager.md#0x0_balance_manager">balance_manager</a></code>.
DEEP quantity can be overestimated. Returns three <code>Coin</code> objects:
base, quote, and deep. Some base amount may be left over, if the
input quantity is not divisible by lot size.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_swap_exact_base_for_quote">swap_exact_base_for_quote</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, base_in: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;BaseAsset&gt;, deep_in: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>&gt;, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (<a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;BaseAsset&gt;, <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;QuoteAsset&gt;, <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_swap_exact_base_for_quote">swap_exact_base_for_quote</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    base_in: Coin&lt;BaseAsset&gt;,
    deep_in: Coin&lt;DEEP&gt;,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &<b>mut</b> TxContext,
): (Coin&lt;BaseAsset&gt;, Coin&lt;QuoteAsset&gt;, Coin&lt;DEEP&gt;) {
    <b>let</b> quote_in = <a href="dependencies/sui-framework/coin.md#0x2_coin_zero">coin::zero</a>(ctx);
    <a href="pool.md#0x0_pool_swap_exact_amount">swap_exact_amount</a>(
        self,
        base_in,
        quote_in,
        deep_in,
        <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>,
        ctx,
    )
}
</code></pre>



</details>

<a name="0x0_pool_swap_exact_quote_for_base"></a>

## Function `swap_exact_quote_for_base`

Swap exact quote amount without needing a <code><a href="balance_manager.md#0x0_balance_manager">balance_manager</a></code>.
DEEP quantity can be overestimated. Returns three <code>Coin</code> objects:
base, quote, and deep. Some quote amount may be left over if the
input quantity is not divisible by lot size.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_swap_exact_quote_for_base">swap_exact_quote_for_base</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, quote_in: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;QuoteAsset&gt;, deep_in: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>&gt;, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (<a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;BaseAsset&gt;, <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;QuoteAsset&gt;, <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_swap_exact_quote_for_base">swap_exact_quote_for_base</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    quote_in: Coin&lt;QuoteAsset&gt;,
    deep_in: Coin&lt;DEEP&gt;,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &<b>mut</b> TxContext,
): (Coin&lt;BaseAsset&gt;, Coin&lt;QuoteAsset&gt;, Coin&lt;DEEP&gt;) {
    <b>let</b> base_in = <a href="dependencies/sui-framework/coin.md#0x2_coin_zero">coin::zero</a>(ctx);
    <a href="pool.md#0x0_pool_swap_exact_amount">swap_exact_amount</a>(
        self,
        base_in,
        quote_in,
        deep_in,
        <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>,
        ctx,
    )
}
</code></pre>



</details>

<a name="0x0_pool_modify_order"></a>

## Function `modify_order`

Modifies an order given order_id and new_quantity.
New quantity must be less than the original quantity and more
than the filled quantity. Order must not have already expired.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_modify_order">modify_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, order_id: u128, new_quantity: u64, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_modify_order">modify_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> BalanceManager,
    order_id: u128,
    new_quantity: u64,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &TxContext,
) {
    <b>let</b> self = self.<a href="pool.md#0x0_pool_load_inner_mut">load_inner_mut</a>();
    <b>let</b> (cancel_quantity, <a href="order.md#0x0_order">order</a>) = self.<a href="book.md#0x0_book">book</a>.<a href="pool.md#0x0_pool_modify_order">modify_order</a>(order_id, new_quantity, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms());
    <b>assert</b>!(<a href="order.md#0x0_order">order</a>.balance_manager_id() == <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.id(), <a href="pool.md#0x0_pool_EInvalidOrderBalanceManager">EInvalidOrderBalanceManager</a>);
    <b>let</b> (settled, owed) = self.<a href="state.md#0x0_state">state</a>.process_modify(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.id(), cancel_quantity, <a href="order.md#0x0_order">order</a>, ctx);
    self.<a href="vault.md#0x0_vault">vault</a>.settle_balance_manager(settled, owed, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>, ctx);

    <a href="order.md#0x0_order">order</a>.emit_order_modified&lt;BaseAsset, QuoteAsset&gt;(self.pool_id, ctx.sender(), <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms());
}
</code></pre>



</details>

<a name="0x0_pool_cancel_order"></a>

## Function `cancel_order`

Cancel an order. The order must be owned by the balance_manager.
The order is removed from the book and the balance_manager's open orders.
The balance_manager's balance is updated with the order's remaining quantity.
Order canceled event is emitted.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_cancel_order">cancel_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, order_id: u128, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_cancel_order">cancel_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> BalanceManager,
    order_id: u128,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &TxContext,
) {
    <b>let</b> self = self.<a href="pool.md#0x0_pool_load_inner_mut">load_inner_mut</a>();
    <b>let</b> <b>mut</b> <a href="order.md#0x0_order">order</a> = self.<a href="book.md#0x0_book">book</a>.<a href="pool.md#0x0_pool_cancel_order">cancel_order</a>(order_id);
    <b>assert</b>!(<a href="order.md#0x0_order">order</a>.balance_manager_id() == <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.id(), <a href="pool.md#0x0_pool_EInvalidOrderBalanceManager">EInvalidOrderBalanceManager</a>);
    <b>let</b> (settled, owed) = self.<a href="state.md#0x0_state">state</a>.process_cancel(&<b>mut</b> <a href="order.md#0x0_order">order</a>, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.id(), ctx);
    self.<a href="vault.md#0x0_vault">vault</a>.settle_balance_manager(settled, owed, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>, ctx);

    <a href="order.md#0x0_order">order</a>.emit_order_canceled&lt;BaseAsset, QuoteAsset&gt;(self.pool_id, ctx.sender(), <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms());
}
</code></pre>



</details>

<a name="0x0_pool_cancel_all_orders"></a>

## Function `cancel_all_orders`

Cancel all open orders placed by the balance manager in the pool.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_cancel_all_orders">cancel_all_orders</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_cancel_all_orders">cancel_all_orders</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> BalanceManager,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &TxContext,
) {
    <b>let</b> inner = self.<a href="pool.md#0x0_pool_load_inner">load_inner</a>();
    <b>let</b> open_orders = inner.<a href="state.md#0x0_state">state</a>.<a href="account.md#0x0_account">account</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.id()).open_orders().into_keys();
    <b>let</b> <b>mut</b> i = 0;
    <b>while</b> (i &lt; open_orders.length()) {
        <b>let</b> order_id = open_orders[i];
        self.<a href="pool.md#0x0_pool_cancel_order">cancel_order</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>, order_id, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>, ctx);
        i = i + 1;
    }
}
</code></pre>



</details>

<a name="0x0_pool_withdraw_settled_amounts"></a>

## Function `withdraw_settled_amounts`

Withdraw settled amounts to the <code><a href="balance_manager.md#0x0_balance_manager">balance_manager</a></code>.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_withdraw_settled_amounts">withdraw_settled_amounts</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_withdraw_settled_amounts">withdraw_settled_amounts</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> BalanceManager,
    ctx: &TxContext,
) {
    <b>let</b> self = self.<a href="pool.md#0x0_pool_load_inner_mut">load_inner_mut</a>();
    <b>let</b> (settled, owed) = self.<a href="state.md#0x0_state">state</a>.<a href="pool.md#0x0_pool_withdraw_settled_amounts">withdraw_settled_amounts</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.id());
    self.<a href="vault.md#0x0_vault">vault</a>.settle_balance_manager(settled, owed, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>, ctx);
}
</code></pre>



</details>

<a name="0x0_pool_stake"></a>

## Function `stake`

Stake DEEP tokens to the pool. The balance_manager must have enough DEEP tokens.
The balance_manager's data is updated with the staked amount.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_stake">stake</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, amount: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_stake">stake</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> BalanceManager,
    amount: u64,
    ctx: &TxContext,
) {
    <b>let</b> self = self.<a href="pool.md#0x0_pool_load_inner_mut">load_inner_mut</a>();
    <b>let</b> (settled, owed) = self.<a href="state.md#0x0_state">state</a>.process_stake(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.id(), amount, ctx);
    self.<a href="vault.md#0x0_vault">vault</a>.settle_balance_manager(settled, owed, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>, ctx);
}
</code></pre>



</details>

<a name="0x0_pool_unstake"></a>

## Function `unstake`

Unstake DEEP tokens from the pool. The balance_manager must have enough staked DEEP tokens.
The balance_manager's data is updated with the unstaked amount.
Balance is transferred to the balance_manager immediately.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_unstake">unstake</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_unstake">unstake</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> BalanceManager,
    ctx: &TxContext,
) {
    <b>let</b> self = self.<a href="pool.md#0x0_pool_load_inner_mut">load_inner_mut</a>();
    <b>let</b> (settled, owed) = self.<a href="state.md#0x0_state">state</a>.process_unstake(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.id(), ctx);
    self.<a href="vault.md#0x0_vault">vault</a>.settle_balance_manager(settled, owed, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>, ctx);
}
</code></pre>



</details>

<a name="0x0_pool_submit_proposal"></a>

## Function `submit_proposal`

Submit a proposal to change the taker fee, maker fee, and stake required.
The balance_manager must have enough staked DEEP tokens to participate.
Each balance_manager can only submit one proposal per epoch.
If the maximum proposal is reached, the proposal with the lowest vote is removed.
If the balance_manager has less voting power than the lowest voted proposal, the proposal is not added.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_submit_proposal">submit_proposal</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, taker_fee: u64, maker_fee: u64, stake_required: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_submit_proposal">submit_proposal</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> BalanceManager,
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
    ctx: &TxContext,
) {
    <b>let</b> self = self.<a href="pool.md#0x0_pool_load_inner_mut">load_inner_mut</a>();
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.validate_trader(ctx);
    self.<a href="state.md#0x0_state">state</a>.process_proposal(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.id(), taker_fee, maker_fee, stake_required, ctx);
}
</code></pre>



</details>

<a name="0x0_pool_vote"></a>

## Function `vote`

Vote on a proposal. The balance_manager must have enough staked DEEP tokens to participate.
Full voting power of the balance_manager is used.
Voting for a new proposal will remove the vote from the previous proposal.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_vote">vote</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, proposal_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_vote">vote</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> BalanceManager,
    proposal_id: ID,
    ctx: &TxContext,
) {
    <b>let</b> self = self.<a href="pool.md#0x0_pool_load_inner_mut">load_inner_mut</a>();
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.validate_trader(ctx);
    self.<a href="state.md#0x0_state">state</a>.process_vote(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.id(), proposal_id, ctx);
}
</code></pre>



</details>

<a name="0x0_pool_claim_rebates"></a>

## Function `claim_rebates`

Claim the rewards for the balance_manager. The balance_manager must have rewards to claim.
The balance_manager's data is updated with the claimed rewards.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_claim_rebates">claim_rebates</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_claim_rebates">claim_rebates</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> BalanceManager,
    ctx: &TxContext,
) {
    <b>let</b> self = self.<a href="pool.md#0x0_pool_load_inner_mut">load_inner_mut</a>();
    <b>let</b> (settled, owed) = self.<a href="state.md#0x0_state">state</a>.process_claim_rebates(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.id(), ctx);
    self.<a href="vault.md#0x0_vault">vault</a>.settle_balance_manager(settled, owed, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>, ctx);
}
</code></pre>



</details>

<a name="0x0_pool_add_deep_price_point"></a>

## Function `add_deep_price_point`

Adds a price point along with a timestamp to the deep price.
Allows for the calculation of deep price per base asset.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_add_deep_price_point">add_deep_price_point</a>&lt;BaseAsset, QuoteAsset, ReferenceBaseAsset, ReferenceQuoteAsset&gt;(target_pool: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, reference_pool: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;ReferenceBaseAsset, ReferenceQuoteAsset&gt;, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_add_deep_price_point">add_deep_price_point</a>&lt;BaseAsset, QuoteAsset, ReferenceBaseAsset, ReferenceQuoteAsset&gt;(
    target_pool: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    reference_pool: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;ReferenceBaseAsset, ReferenceQuoteAsset&gt;,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
) {
    <b>assert</b>!(reference_pool.<a href="pool.md#0x0_pool_whitelisted">whitelisted</a>(), <a href="pool.md#0x0_pool_EIneligibleReferencePool">EIneligibleReferencePool</a>);
    <b>let</b> reference_pool_price = reference_pool.<a href="pool.md#0x0_pool_mid_price">mid_price</a>(<a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>);

    <b>let</b> target_pool = target_pool.<a href="pool.md#0x0_pool_load_inner_mut">load_inner_mut</a>();
    <b>let</b> reference_base_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;ReferenceBaseAsset&gt;();
    <b>let</b> reference_quote_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;ReferenceQuoteAsset&gt;();
    <b>let</b> target_base_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;BaseAsset&gt;();
    <b>let</b> target_quote_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;QuoteAsset&gt;();
    <b>let</b> deep_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;DEEP&gt;();
    <b>let</b> timestamp = <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms();

    <b>assert</b>!(reference_base_type == deep_type || reference_quote_type == deep_type, <a href="pool.md#0x0_pool_EIneligibleTargetPool">EIneligibleTargetPool</a>);

    <b>let</b> reference_deep_is_base = reference_base_type == deep_type;
    <b>let</b> reference_other_type = <b>if</b> (reference_deep_is_base) {
        reference_quote_type
    } <b>else</b> {
        reference_base_type
    };
    <b>let</b> reference_other_is_target_base = reference_other_type == target_base_type;
    <b>let</b> reference_other_is_target_quote = reference_other_type == target_quote_type;
    <b>assert</b>!(reference_other_is_target_base || reference_other_is_target_quote, <a href="pool.md#0x0_pool_EIneligibleTargetPool">EIneligibleTargetPool</a>);

    // For DEEP/USDC <a href="pool.md#0x0_pool">pool</a>, reference_deep_is_base is <b>true</b>, DEEP per USDC is reference_pool_price
    // For USDC/DEEP <a href="pool.md#0x0_pool">pool</a>, reference_deep_is_base is <b>false</b>, USDC per DEEP is reference_pool_price
    <b>let</b> deep_per_reference_other_price = <b>if</b> (reference_deep_is_base) {
        math::div(1_000_000_000, reference_pool_price)
    } <b>else</b> {
        reference_pool_price
    };

    // For USDC/SUI <a href="pool.md#0x0_pool">pool</a>, reference_other_is_target_base is <b>true</b>, add price point <b>to</b> <a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep">deep</a> per base
    // For SUI/USDC <a href="pool.md#0x0_pool">pool</a>, reference_other_is_target_base is <b>false</b>, add price point <b>to</b> <a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep">deep</a> per quote
    <b>if</b> (reference_other_is_target_base){
        target_pool.<a href="deep_price.md#0x0_deep_price">deep_price</a>.add_price_point(deep_per_reference_other_price, timestamp, <b>true</b>);
    } <b>else</b> {
        target_pool.<a href="deep_price.md#0x0_deep_price">deep_price</a>.add_price_point(deep_per_reference_other_price, timestamp, <b>false</b>);
    }
}
</code></pre>



</details>

<a name="0x0_pool_burn_deep"></a>

## Function `burn_deep`

Burns DEEP tokens from the pool. Amount to burn is within history


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_burn_deep">burn_deep</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, treasury_cap: &<b>mut</b> <a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury">deep::ProtectedTreasury</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_burn_deep">burn_deep</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    treasury_cap: &<b>mut</b> ProtectedTreasury,
    ctx: &<b>mut</b> TxContext,
): u64 {
    <b>let</b> self = self.<a href="pool.md#0x0_pool_load_inner_mut">load_inner_mut</a>();
    <b>let</b> balance_to_burn = self.<a href="state.md#0x0_state">state</a>.history_mut().reset_balance_to_burn();
    <b>assert</b>!(balance_to_burn &gt; 0, <a href="pool.md#0x0_pool_ENoAmountToBurn">ENoAmountToBurn</a>);
    <b>let</b> deep_to_burn = self.<a href="vault.md#0x0_vault">vault</a>.withdraw_deep_to_burn(balance_to_burn).into_coin(ctx);
    <b>let</b> amount_burned = deep_to_burn.value();
    token::deep::burn(treasury_cap, deep_to_burn);

    amount_burned
}
</code></pre>



</details>

<a name="0x0_pool_whitelisted"></a>

## Function `whitelisted`

Accessor to check if the pool is whitelisted.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_whitelisted">whitelisted</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_whitelisted">whitelisted</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
): bool {
    self.<a href="pool.md#0x0_pool_load_inner">load_inner</a>().<a href="state.md#0x0_state">state</a>.<a href="governance.md#0x0_governance">governance</a>().<a href="pool.md#0x0_pool_whitelisted">whitelisted</a>()
}
</code></pre>



</details>

<a name="0x0_pool_get_amount_out"></a>

## Function `get_amount_out`

Dry run to determine the amount out for a given base or quote amount.
Only one out of base or quote amount should be non-zero.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_get_amount_out">get_amount_out</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, base_amount: u64, quote_amount: u64, current_timestamp: u64): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_get_amount_out">get_amount_out</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    base_amount: u64,
    quote_amount: u64,
    current_timestamp: u64,
): (u64, u64) {
    self.<a href="pool.md#0x0_pool_load_inner">load_inner</a>().<a href="book.md#0x0_book">book</a>.<a href="pool.md#0x0_pool_get_amount_out">get_amount_out</a>(
        base_amount,
        quote_amount,
        current_timestamp,
    )
}
</code></pre>



</details>

<a name="0x0_pool_mid_price"></a>

## Function `mid_price`

Returns the mid price of the pool.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_mid_price">mid_price</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_mid_price">mid_price</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
): u64 {
    self.<a href="pool.md#0x0_pool_load_inner">load_inner</a>().<a href="book.md#0x0_book">book</a>.<a href="pool.md#0x0_pool_mid_price">mid_price</a>(<a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms())
}
</code></pre>



</details>

<a name="0x0_pool_account_open_orders"></a>

## Function `account_open_orders`

Returns the order_id for all open order for the balance_manager in the pool.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_account_open_orders">account_open_orders</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>): <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set_VecSet">vec_set::VecSet</a>&lt;u128&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_account_open_orders">account_open_orders</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: ID,
): VecSet&lt;u128&gt; {
    self.<a href="pool.md#0x0_pool_load_inner">load_inner</a>().<a href="state.md#0x0_state">state</a>.<a href="account.md#0x0_account">account</a>(<a href="balance_manager.md#0x0_balance_manager">balance_manager</a>).open_orders()
}
</code></pre>



</details>

<a name="0x0_pool_get_level2_range"></a>

## Function `get_level2_range`

Returns the (price_vec, quantity_vec) for the level2 order book.
The price_low and price_high are inclusive, all orders within the range are returned.
is_bid is true for bids and false for asks.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_get_level2_range">get_level2_range</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, price_low: u64, price_high: u64, is_bid: bool): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_get_level2_range">get_level2_range</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    price_low: u64,
    price_high: u64,
    is_bid: bool,
): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;) {
    self.<a href="pool.md#0x0_pool_load_inner">load_inner</a>().<a href="book.md#0x0_book">book</a>.get_level2_range_and_ticks(price_low, price_high, <a href="constants.md#0x0_constants_max_u64">constants::max_u64</a>(), is_bid)
}
</code></pre>



</details>

<a name="0x0_pool_get_level2_ticks_from_mid"></a>

## Function `get_level2_ticks_from_mid`

Returns the (price_vec, quantity_vec) for the level2 order book.
Ticks are the maximum number of ticks to return starting from best bid and best ask.
(bid_price, bid_quantity, ask_price, ask_quantity) are returned as 4 vectors.
The price vectors are sorted in descending order for bids and ascending order for asks.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_get_level2_ticks_from_mid">get_level2_ticks_from_mid</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, ticks: u64): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_get_level2_ticks_from_mid">get_level2_ticks_from_mid</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    ticks: u64,
): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;) {
    <b>let</b> self = self.<a href="pool.md#0x0_pool_load_inner">load_inner</a>();
    <b>let</b> (bid_price, bid_quantity) = self.<a href="book.md#0x0_book">book</a>.get_level2_range_and_ticks(<a href="constants.md#0x0_constants_min_price">constants::min_price</a>(), <a href="constants.md#0x0_constants_max_price">constants::max_price</a>(), ticks, <b>true</b>);
    <b>let</b> (ask_price, ask_quantity) = self.<a href="book.md#0x0_book">book</a>.get_level2_range_and_ticks(<a href="constants.md#0x0_constants_min_price">constants::min_price</a>(), <a href="constants.md#0x0_constants_max_price">constants::max_price</a>(), ticks, <b>false</b>);

    (bid_price, bid_quantity, ask_price, ask_quantity)
}
</code></pre>



</details>

<a name="0x0_pool_vault_balances"></a>

## Function `vault_balances`

Get all balances held in this pool.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_vault_balances">vault_balances</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_vault_balances">vault_balances</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
): (u64, u64, u64) {
    self.<a href="pool.md#0x0_pool_load_inner">load_inner</a>().<a href="vault.md#0x0_vault">vault</a>.<a href="balances.md#0x0_balances">balances</a>()
}
</code></pre>



</details>

<a name="0x0_pool_get_pool_id_by_asset"></a>

## Function `get_pool_id_by_asset`

Get the ID of the pool given the asset types.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_get_pool_id_by_asset">get_pool_id_by_asset</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="registry.md#0x0_registry">registry</a>: &<a href="registry.md#0x0_registry_Registry">registry::Registry</a>): <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_get_pool_id_by_asset">get_pool_id_by_asset</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="registry.md#0x0_registry">registry</a>: &Registry,
): ID {
    <a href="registry.md#0x0_registry">registry</a>.get_pool_id&lt;BaseAsset, QuoteAsset&gt;()
}
</code></pre>



</details>

<a name="0x0_pool_set_stable"></a>

## Function `set_stable`

Set a pool as a stable pool. Stable pools have a lower fee.
Only Admin can set a pool as stable.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_set_stable">set_stable</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, _cap: &<a href="registry.md#0x0_registry_DeepbookAdminCap">registry::DeepbookAdminCap</a>, stable: bool, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_set_stable">set_stable</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    _cap: &DeepbookAdminCap,
    stable: bool,
    ctx: &TxContext,
) {
    self.<a href="pool.md#0x0_pool_load_inner_mut">load_inner_mut</a>().<a href="state.md#0x0_state">state</a>.governance_mut(ctx).<a href="pool.md#0x0_pool_set_stable">set_stable</a>(stable);
}
</code></pre>



</details>

<a name="0x0_pool_unregister_pool_admin"></a>

## Function `unregister_pool_admin`

Unregister a pool in case it needs to be manually redeployed.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_unregister_pool_admin">unregister_pool_admin</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="registry.md#0x0_registry">registry</a>: &<b>mut</b> <a href="registry.md#0x0_registry_Registry">registry::Registry</a>, _cap: &<a href="registry.md#0x0_registry_DeepbookAdminCap">registry::DeepbookAdminCap</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_unregister_pool_admin">unregister_pool_admin</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="registry.md#0x0_registry">registry</a>: &<b>mut</b> Registry,
    _cap: &DeepbookAdminCap,
) {
    <a href="registry.md#0x0_registry">registry</a>.unregister_pool&lt;BaseAsset, QuoteAsset&gt;();
}
</code></pre>



</details>

<a name="0x0_pool_create_pool"></a>

## Function `create_pool`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_create_pool">create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="registry.md#0x0_registry">registry</a>: &<b>mut</b> <a href="registry.md#0x0_registry_Registry">registry::Registry</a>, tick_size: u64, lot_size: u64, min_size: u64, creation_fee: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>&gt;, whitelisted_pool: bool, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="pool.md#0x0_pool_create_pool">create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="registry.md#0x0_registry">registry</a>: &<b>mut</b> Registry,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    creation_fee: Coin&lt;DEEP&gt;,
    whitelisted_pool: bool,
    ctx: &<b>mut</b> TxContext,
): ID {
    <b>assert</b>!(creation_fee.value() == <a href="constants.md#0x0_constants_pool_creation_fee">constants::pool_creation_fee</a>(), <a href="pool.md#0x0_pool_EInvalidFee">EInvalidFee</a>);
    <b>assert</b>!(tick_size &gt; 0, <a href="pool.md#0x0_pool_EInvalidTickSize">EInvalidTickSize</a>);
    <b>assert</b>!(lot_size &gt; 0, <a href="pool.md#0x0_pool_EInvalidLotSize">EInvalidLotSize</a>);
    <b>assert</b>!(min_size &gt; 0, <a href="pool.md#0x0_pool_EInvalidMinSize">EInvalidMinSize</a>);
    <b>assert</b>!(<a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;BaseAsset&gt;() != <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;QuoteAsset&gt;(), <a href="pool.md#0x0_pool_ESameBaseAndQuote">ESameBaseAndQuote</a>);

    <b>let</b> pool_id = <a href="dependencies/sui-framework/object.md#0x2_object_new">object::new</a>(ctx);
    <b>let</b> <b>mut</b> pool_inner = <a href="pool.md#0x0_pool_PoolInner">PoolInner</a>&lt;BaseAsset, QuoteAsset&gt; {
        disabled_versions: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
        pool_id: pool_id.to_inner(),
        <a href="book.md#0x0_book">book</a>: <a href="book.md#0x0_book_empty">book::empty</a>(tick_size, lot_size, min_size, ctx),
        <a href="state.md#0x0_state">state</a>: <a href="state.md#0x0_state_empty">state::empty</a>(ctx),
        <a href="vault.md#0x0_vault">vault</a>: <a href="vault.md#0x0_vault_empty">vault::empty</a>(),
        <a href="deep_price.md#0x0_deep_price">deep_price</a>: <a href="deep_price.md#0x0_deep_price_empty">deep_price::empty</a>(),
    };
    <b>if</b> (whitelisted_pool) {
        pool_inner.<a href="pool.md#0x0_pool_set_whitelist">set_whitelist</a>(ctx);
    };
    <b>let</b> params = pool_inner.<a href="state.md#0x0_state">state</a>.<a href="governance.md#0x0_governance">governance</a>().<a href="trade_params.md#0x0_trade_params">trade_params</a>();
    <b>let</b> taker_fee = params.taker_fee();
    <b>let</b> maker_fee = params.maker_fee();
    <b>let</b> treasury_address = <a href="registry.md#0x0_registry">registry</a>.treasury_address();
    <b>let</b> <a href="pool.md#0x0_pool">pool</a> = <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt; {
        id: pool_id,
        inner: <a href="dependencies/sui-framework/versioned.md#0x2_versioned_create">versioned::create</a>(<a href="pool.md#0x0_pool_CURRENT_VERSION">CURRENT_VERSION</a>, pool_inner, ctx),
    };
    <b>let</b> pool_id = <a href="dependencies/sui-framework/object.md#0x2_object_id">object::id</a>(&<a href="pool.md#0x0_pool">pool</a>);
    <a href="registry.md#0x0_registry">registry</a>.register_pool&lt;BaseAsset, QuoteAsset&gt;(pool_id);
    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="pool.md#0x0_pool_PoolCreated">PoolCreated</a>&lt;BaseAsset, QuoteAsset&gt; {
        pool_id,
        taker_fee,
        maker_fee,
        tick_size,
        lot_size,
        min_size,
        whitelisted_pool,
        treasury_address,
    });

    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_public_transfer">transfer::public_transfer</a>(creation_fee, treasury_address);
    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_share_object">transfer::share_object</a>(<a href="pool.md#0x0_pool">pool</a>);

    pool_id
}
</code></pre>



</details>

<a name="0x0_pool_bids"></a>

## Function `bids`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_bids">bids</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_PoolInner">pool::PoolInner</a>&lt;BaseAsset, QuoteAsset&gt;): &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;<a href="order.md#0x0_order_Order">order::Order</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="pool.md#0x0_pool_bids">bids</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_PoolInner">PoolInner</a>&lt;BaseAsset, QuoteAsset&gt;,
): &BigVector&lt;Order&gt; {
    self.<a href="book.md#0x0_book">book</a>.<a href="pool.md#0x0_pool_bids">bids</a>()
}
</code></pre>



</details>

<a name="0x0_pool_asks"></a>

## Function `asks`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_asks">asks</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_PoolInner">pool::PoolInner</a>&lt;BaseAsset, QuoteAsset&gt;): &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;<a href="order.md#0x0_order_Order">order::Order</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="pool.md#0x0_pool_asks">asks</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_PoolInner">PoolInner</a>&lt;BaseAsset, QuoteAsset&gt;,
): &BigVector&lt;Order&gt; {
    self.<a href="book.md#0x0_book">book</a>.<a href="pool.md#0x0_pool_asks">asks</a>()
}
</code></pre>



</details>

<a name="0x0_pool_load_inner"></a>

## Function `load_inner`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_load_inner">load_inner</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;): &<a href="pool.md#0x0_pool_PoolInner">pool::PoolInner</a>&lt;BaseAsset, QuoteAsset&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="pool.md#0x0_pool_load_inner">load_inner</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
): &<a href="pool.md#0x0_pool_PoolInner">PoolInner</a>&lt;BaseAsset, QuoteAsset&gt; {
    <b>let</b> inner: &<a href="pool.md#0x0_pool_PoolInner">PoolInner</a>&lt;BaseAsset, QuoteAsset&gt; = self.inner.load_value();
    <b>let</b> package_version = <a href="pool.md#0x0_pool_CURRENT_VERSION">CURRENT_VERSION</a>;
    <b>assert</b>!(!inner.disabled_versions.contains(&package_version), <a href="pool.md#0x0_pool_EPackageVersionDisabled">EPackageVersionDisabled</a>);

    inner
}
</code></pre>



</details>

<a name="0x0_pool_load_inner_mut"></a>

## Function `load_inner_mut`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool.md#0x0_pool_load_inner_mut">load_inner_mut</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;): &<b>mut</b> <a href="pool.md#0x0_pool_PoolInner">pool::PoolInner</a>&lt;BaseAsset, QuoteAsset&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="pool.md#0x0_pool_load_inner_mut">load_inner_mut</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
): &<b>mut</b> <a href="pool.md#0x0_pool_PoolInner">PoolInner</a>&lt;BaseAsset, QuoteAsset&gt; {
    <b>let</b> inner: &<b>mut</b> <a href="pool.md#0x0_pool_PoolInner">PoolInner</a>&lt;BaseAsset, QuoteAsset&gt; = self.inner.load_value_mut();
    <b>let</b> package_version = <a href="pool.md#0x0_pool_CURRENT_VERSION">CURRENT_VERSION</a>;
    <b>assert</b>!(!inner.disabled_versions.contains(&package_version), <a href="pool.md#0x0_pool_EPackageVersionDisabled">EPackageVersionDisabled</a>);

    inner
}
</code></pre>



</details>

<a name="0x0_pool_set_whitelist"></a>

## Function `set_whitelist`

Set a pool as a whitelist pool at pool creation. Whitelist pools have zero fees.
Only called by admin during pool creation


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_set_whitelist">set_whitelist</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_PoolInner">pool::PoolInner</a>&lt;BaseAsset, QuoteAsset&gt;, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_set_whitelist">set_whitelist</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_PoolInner">PoolInner</a>&lt;BaseAsset, QuoteAsset&gt;,
    ctx: &TxContext,
) {
    <b>let</b> base = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;BaseAsset&gt;();
    <b>let</b> quote = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;QuoteAsset&gt;();
    <b>let</b> deep_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;DEEP&gt;();
    <b>assert</b>!(base == deep_type || quote == deep_type, <a href="pool.md#0x0_pool_EIneligibleWhitelist">EIneligibleWhitelist</a>);

    self.<a href="state.md#0x0_state">state</a>.governance_mut(ctx).<a href="pool.md#0x0_pool_set_whitelist">set_whitelist</a>(<b>true</b>);
}
</code></pre>



</details>

<a name="0x0_pool_swap_exact_amount"></a>

## Function `swap_exact_amount`

Swap exact amount without needing an balance_manager.


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_swap_exact_amount">swap_exact_amount</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, base_in: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;BaseAsset&gt;, quote_in: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;QuoteAsset&gt;, deep_in: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>&gt;, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (<a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;BaseAsset&gt;, <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;QuoteAsset&gt;, <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_swap_exact_amount">swap_exact_amount</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    base_in: Coin&lt;BaseAsset&gt;,
    quote_in: Coin&lt;QuoteAsset&gt;,
    deep_in: Coin&lt;DEEP&gt;,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &<b>mut</b> TxContext,
): (Coin&lt;BaseAsset&gt;, Coin&lt;QuoteAsset&gt;, Coin&lt;DEEP&gt;) {
    <b>let</b> <b>mut</b> base_quantity = base_in.value();
    <b>let</b> quote_quantity = quote_in.value();
    <b>assert</b>!(base_quantity &gt; 0 || quote_quantity &gt; 0, <a href="pool.md#0x0_pool_EInvalidAmountIn">EInvalidAmountIn</a>);
    <b>assert</b>!(!(base_quantity &gt; 0 && quote_quantity &gt; 0), <a href="pool.md#0x0_pool_EInvalidAmountIn">EInvalidAmountIn</a>);

    <b>let</b> pay_with_deep = deep_in.value() &gt; 0;
    <b>let</b> is_bid = quote_quantity &gt; 0;
    <b>if</b> (is_bid) {
        (base_quantity, _) = self.<a href="pool.md#0x0_pool_get_amount_out">get_amount_out</a>(0, quote_quantity, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms());
    };
    base_quantity = base_quantity - base_quantity % self.<a href="pool.md#0x0_pool_load_inner">load_inner</a>().<a href="book.md#0x0_book">book</a>.lot_size();

    <b>let</b> <b>mut</b> temp_balance_manager = <a href="balance_manager.md#0x0_balance_manager_new">balance_manager::new</a>(ctx);
    temp_balance_manager.deposit(base_in, ctx);
    temp_balance_manager.deposit(quote_in, ctx);
    temp_balance_manager.deposit(deep_in, ctx);

    self.<a href="pool.md#0x0_pool_place_market_order">place_market_order</a>(
        &<b>mut</b> temp_balance_manager,
        0,
        <a href="constants.md#0x0_constants_self_matching_allowed">constants::self_matching_allowed</a>(),
        base_quantity,
        is_bid,
        pay_with_deep,
        <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>,
        ctx
    );

    <b>let</b> base_out = temp_balance_manager.withdraw_protected&lt;BaseAsset&gt;(0, <b>true</b>, ctx).into_coin(ctx);
    <b>let</b> quote_out = temp_balance_manager.withdraw_protected&lt;QuoteAsset&gt;(0, <b>true</b>, ctx).into_coin(ctx);
    <b>let</b> deep_out = temp_balance_manager.withdraw_protected&lt;DEEP&gt;(0, <b>true</b>, ctx).into_coin(ctx);

    temp_balance_manager.delete();

    (base_out, quote_out, deep_out)
}
</code></pre>



</details>

<a name="0x0_pool_place_order_int"></a>

## Function `place_order_int`



<pre><code><b>fun</b> <a href="pool.md#0x0_pool_place_order_int">place_order_int</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> <a href="balance_manager.md#0x0_balance_manager_BalanceManager">balance_manager::BalanceManager</a>, client_order_id: u64, order_type: u8, self_matching_option: u8, price: u64, quantity: u64, is_bid: bool, pay_with_deep: bool, expire_timestamp: u64, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, market_order: bool, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_place_order_int">place_order_int</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>: &<b>mut</b> BalanceManager,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    market_order: bool,
    ctx: &TxContext,
): OrderInfo {
    <b>let</b> whitelist = self.<a href="pool.md#0x0_pool_whitelisted">whitelisted</a>();
    <b>assert</b>!(pay_with_deep || whitelist, <a href="pool.md#0x0_pool_EFeeTypeNotSupported">EFeeTypeNotSupported</a>);

    <b>let</b> self = self.<a href="pool.md#0x0_pool_load_inner_mut">load_inner_mut</a>();
    <b>let</b> <b>mut</b> <a href="order_info.md#0x0_order_info">order_info</a> = <a href="order_info.md#0x0_order_info_new">order_info::new</a>(
        self.pool_id,
        <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>.id(),
        client_order_id,
        ctx.sender(),
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        pay_with_deep,
        ctx.epoch(),
        expire_timestamp,
        self.<a href="deep_price.md#0x0_deep_price">deep_price</a>.get_order_deep_price(whitelist),
        market_order,
    );
    self.<a href="book.md#0x0_book">book</a>.create_order(&<b>mut</b> <a href="order_info.md#0x0_order_info">order_info</a>, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms());
    <b>let</b> (settled, owed) = self.<a href="state.md#0x0_state">state</a>.process_create(
        &<b>mut</b> <a href="order_info.md#0x0_order_info">order_info</a>,
        whitelist,
        ctx
    );
    self.<a href="vault.md#0x0_vault">vault</a>.settle_balance_manager(settled, owed, <a href="balance_manager.md#0x0_balance_manager">balance_manager</a>, ctx);
    <b>if</b> (<a href="order_info.md#0x0_order_info">order_info</a>.remaining_quantity() &gt; 0) <a href="order_info.md#0x0_order_info">order_info</a>.emit_order_placed();

    <a href="order_info.md#0x0_order_info">order_info</a>
}
</code></pre>



</details>
