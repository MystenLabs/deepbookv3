
<a name="0x0_pool"></a>

# Module `0x0::pool`

Public-facing interface for the package.
TODO: No authorization checks are implemented;


-  [Resource `DeepBookAdminCap`](#0x0_pool_DeepBookAdminCap)
-  [Resource `Pool`](#0x0_pool_Pool)
-  [Struct `PoolCreated`](#0x0_pool_PoolCreated)
-  [Constants](#@Constants_0)
-  [Function `create_pool`](#0x0_pool_create_pool)
-  [Function `whitelisted`](#0x0_pool_whitelisted)
-  [Function `place_limit_order`](#0x0_pool_place_limit_order)
-  [Function `place_market_order`](#0x0_pool_place_market_order)
-  [Function `swap_exact_amount`](#0x0_pool_swap_exact_amount)
-  [Function `modify_order`](#0x0_pool_modify_order)
-  [Function `cancel_order`](#0x0_pool_cancel_order)
-  [Function `stake`](#0x0_pool_stake)
-  [Function `unstake`](#0x0_pool_unstake)
-  [Function `submit_proposal`](#0x0_pool_submit_proposal)
-  [Function `vote`](#0x0_pool_vote)
-  [Function `claim_rebates`](#0x0_pool_claim_rebates)
-  [Function `get_amount_out`](#0x0_pool_get_amount_out)
-  [Function `mid_price`](#0x0_pool_mid_price)
-  [Function `user_open_orders`](#0x0_pool_user_open_orders)
-  [Function `get_level2_range`](#0x0_pool_get_level2_range)
-  [Function `get_level2_ticks_from_mid`](#0x0_pool_get_level2_ticks_from_mid)
-  [Function `add_deep_price_point`](#0x0_pool_add_deep_price_point)
-  [Function `set_stable`](#0x0_pool_set_stable)
-  [Function `set_whitelist`](#0x0_pool_set_whitelist)


<pre><code><b>use</b> <a href="account.md#0x0_account">0x0::account</a>;
<b>use</b> <a href="book.md#0x0_book">0x0::book</a>;
<b>use</b> <a href="deep_price.md#0x0_deep_price">0x0::deep_price</a>;
<b>use</b> <a href="governance.md#0x0_governance">0x0::governance</a>;
<b>use</b> <a href="order.md#0x0_order">0x0::order</a>;
<b>use</b> <a href="order_info.md#0x0_order_info">0x0::order_info</a>;
<b>use</b> <a href="registry.md#0x0_registry">0x0::registry</a>;
<b>use</b> <a href="state.md#0x0_state">0x0::state</a>;
<b>use</b> <a href="user.md#0x0_user">0x0::user</a>;
<b>use</b> <a href="vault.md#0x0_vault">0x0::vault</a>;
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



<a name="0x0_pool_DeepBookAdminCap"></a>

## Resource `DeepBookAdminCap`

DeepBookAdminCap is used to call admin functions.


<pre><code><b>struct</b> <a href="pool.md#0x0_pool_DeepBookAdminCap">DeepBookAdminCap</a> <b>has</b> store, key
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>id: <a href="dependencies/sui-framework/object.md#0x2_object_UID">object::UID</a></code>
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



<a name="0x0_pool_EInvalidAmountIn"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidAmountIn">EInvalidAmountIn</a>: u64 = 8;
</code></pre>



<a name="0x0_pool_MAX_U64"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_MAX_U64">MAX_U64</a>: u64 = 9223372036854775808;
</code></pre>



<a name="0x0_pool_EIneligibleReferencePool"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EIneligibleReferencePool">EIneligibleReferencePool</a>: u64 = 12;
</code></pre>



<a name="0x0_pool_EIneligibleWhitelist"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EIneligibleWhitelist">EIneligibleWhitelist</a>: u64 = 10;
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



<a name="0x0_pool_EInvalidTickSize"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_EInvalidTickSize">EInvalidTickSize</a>: u64 = 3;
</code></pre>



<a name="0x0_pool_ESameBaseAndQuote"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_ESameBaseAndQuote">ESameBaseAndQuote</a>: u64 = 2;
</code></pre>



<a name="0x0_pool_POOL_CREATION_FEE"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_POOL_CREATION_FEE">POOL_CREATION_FEE</a>: u64 = 100000000000;
</code></pre>



<a name="0x0_pool_TREASURY_ADDRESS"></a>



<pre><code><b>const</b> <a href="pool.md#0x0_pool_TREASURY_ADDRESS">TREASURY_ADDRESS</a>: <b>address</b> = 0;
</code></pre>



<a name="0x0_pool_create_pool"></a>

## Function `create_pool`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_create_pool">create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="registry.md#0x0_registry">registry</a>: &<b>mut</b> <a href="registry.md#0x0_registry_Registry">registry::Registry</a>, tick_size: u64, lot_size: u64, min_size: u64, creation_fee: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;<a href="dependencies/sui-framework/sui.md#0x2_sui_SUI">sui::SUI</a>&gt;, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_create_pool">create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(
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
    <b>let</b> pool_id = pool_uid.to_inner();

    <b>let</b> <a href="pool.md#0x0_pool">pool</a> = <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt; {
        id: pool_uid,
        <a href="book.md#0x0_book">book</a>: <a href="book.md#0x0_book_empty">book::empty</a>(tick_size, lot_size, min_size, ctx),
        <a href="state.md#0x0_state">state</a>: <a href="state.md#0x0_state_empty">state::empty</a>(ctx),
        <a href="vault.md#0x0_vault">vault</a>: <a href="vault.md#0x0_vault_empty">vault::empty</a>(),
    };

    <b>let</b> (taker_fee, maker_fee, _) = <a href="pool.md#0x0_pool">pool</a>.<a href="state.md#0x0_state">state</a>.<a href="governance.md#0x0_governance">governance</a>().trade_params();
    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="pool.md#0x0_pool_PoolCreated">PoolCreated</a>&lt;BaseAsset, QuoteAsset&gt; {
        pool_id,
        taker_fee,
        maker_fee,
        tick_size,
        lot_size,
        min_size,
    });

    // TODO: reconsider sending the Coin here. User pays gas;
    // TODO: depending on the frequency of the <a href="dependencies/sui-framework/event.md#0x2_event">event</a>;
    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_public_transfer">transfer::public_transfer</a>(creation_fee.into_coin(ctx), <a href="pool.md#0x0_pool_TREASURY_ADDRESS">TREASURY_ADDRESS</a>);

    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_share_object">transfer::share_object</a>(<a href="pool.md#0x0_pool">pool</a>);
}
</code></pre>



</details>

<a name="0x0_pool_whitelisted"></a>

## Function `whitelisted`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_whitelisted">whitelisted</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_whitelisted">whitelisted</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
): bool {
    self.<a href="state.md#0x0_state">state</a>.<a href="pool.md#0x0_pool_whitelisted">whitelisted</a>()
}
</code></pre>



</details>

<a name="0x0_pool_place_limit_order"></a>

## Function `place_limit_order`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_place_limit_order">place_limit_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, client_order_id: u64, order_type: u8, price: u64, quantity: u64, is_bid: bool, expire_timestamp: u64, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_place_limit_order">place_limit_order</a>&lt;BaseAsset, QuoteAsset&gt;(
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
) {
    <b>let</b> (taker_fee, maker_fee, stake_required) = self.<a href="state.md#0x0_state">state</a>.<a href="governance.md#0x0_governance">governance</a>().trade_params();
    <b>let</b> <b>mut</b> <a href="order_info.md#0x0_order_info">order_info</a> =
        <a href="order_info.md#0x0_order_info_initial_order">order_info::initial_order</a>(self.id.to_inner(), client_order_id, <a href="account.md#0x0_account">account</a>.owner(), order_type, price, quantity, is_bid, expire_timestamp, maker_fee);
    self.<a href="book.md#0x0_book">book</a>.create_order(&<b>mut</b> <a href="order_info.md#0x0_order_info">order_info</a>, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms());
    self.<a href="state.md#0x0_state">state</a>.process_create(&<a href="order_info.md#0x0_order_info">order_info</a>, ctx);
    self.<a href="vault.md#0x0_vault">vault</a>.settle_order(&<a href="order_info.md#0x0_order_info">order_info</a>, self.<a href="state.md#0x0_state">state</a>.user_mut(<a href="account.md#0x0_account">account</a>.owner(), ctx.epoch()), taker_fee, maker_fee, stake_required);
    self.<a href="vault.md#0x0_vault">vault</a>.settle_user(self.<a href="state.md#0x0_state">state</a>.user_mut(<a href="account.md#0x0_account">account</a>.owner(), ctx.epoch()), <a href="account.md#0x0_account">account</a>, proof);

    <b>if</b> (<a href="order_info.md#0x0_order_info">order_info</a>.remaining_quantity() &gt; 0) <a href="order_info.md#0x0_order_info">order_info</a>.emit_order_placed();
}
</code></pre>



</details>

<a name="0x0_pool_place_market_order"></a>

## Function `place_market_order`

Place a market order. Quantity is in base asset terms. Calls place_limit_order with
a price of MAX_PRICE for bids and MIN_PRICE for asks. Fills or kills the order.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_place_market_order">place_market_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, client_order_id: u64, quantity: u64, is_bid: bool, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_place_market_order">place_market_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    client_order_id: u64,
    quantity: u64,
    is_bid: bool,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &TxContext,
) {
    self.<a href="pool.md#0x0_pool_place_limit_order">place_limit_order</a>(
        <a href="account.md#0x0_account">account</a>,
        proof,
        client_order_id,
        <a href="order_info.md#0x0_order_info_fill_or_kill">order_info::fill_or_kill</a>(),
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

<a name="0x0_pool_swap_exact_amount"></a>

## Function `swap_exact_amount`

Swap exact amount without needing an account.


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_swap_exact_amount">swap_exact_amount</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, base_in: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;BaseAsset&gt;, quote_in: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;QuoteAsset&gt;, deep_in: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;<a href="vault.md#0x0_vault_DEEP">vault::DEEP</a>&gt;, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (<a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;BaseAsset&gt;, <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;QuoteAsset&gt;, <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;<a href="vault.md#0x0_vault_DEEP">vault::DEEP</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_swap_exact_amount">swap_exact_amount</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    base_in: Coin&lt;BaseAsset&gt;,
    quote_in: Coin&lt;QuoteAsset&gt;,
    deep_in: Coin&lt;DEEP&gt;,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &<b>mut</b> TxContext,
): (Coin&lt;BaseAsset&gt;, Coin&lt;QuoteAsset&gt;, Coin&lt;DEEP&gt;) {
    <b>let</b> <b>mut</b> base_quantity = base_in.value();
    <b>let</b> <b>mut</b> quote_quantity = quote_in.value();
    <b>assert</b>!(base_quantity &gt; 0 || quote_quantity &gt; 0, <a href="pool.md#0x0_pool_EInvalidAmountIn">EInvalidAmountIn</a>);
    <b>assert</b>!(!(base_quantity &gt; 0 && quote_quantity &gt; 0), <a href="pool.md#0x0_pool_EInvalidAmountIn">EInvalidAmountIn</a>);

    <b>let</b> <b>mut</b> temp_account = <a href="account.md#0x0_account_new">account::new</a>(ctx);
    temp_account.deposit(base_in, ctx);
    temp_account.deposit(quote_in, ctx);
    temp_account.deposit(deep_in, ctx);
    <b>let</b> proof = temp_account.generate_proof_as_owner(ctx);

    <b>let</b> is_bid = quote_quantity &gt; 0;
    <b>let</b> (taker_fee, _, _) = self.<a href="state.md#0x0_state">state</a>.<a href="governance.md#0x0_governance">governance</a>().trade_params();
    <b>let</b> (base_fee, quote_fee, _) = self.<a href="state.md#0x0_state">state</a>.<a href="deep_price.md#0x0_deep_price">deep_price</a>().calculate_fees(taker_fee, base_quantity, quote_quantity);
    base_quantity = base_quantity - base_fee;
    quote_quantity = quote_quantity - quote_fee;
    <b>if</b> (is_bid) {
        (base_quantity, _) = self.<a href="pool.md#0x0_pool_get_amount_out">get_amount_out</a>(0, quote_quantity);
    };
    base_quantity = base_quantity - base_quantity % self.<a href="book.md#0x0_book">book</a>.lot_size();

    self.<a href="pool.md#0x0_pool_place_market_order">place_market_order</a>(&<b>mut</b> temp_account, &proof, 0, base_quantity, is_bid, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>, ctx);
    <b>let</b> base_out = temp_account.withdraw_with_proof(&proof, 0, <b>true</b>).into_coin(ctx);
    <b>let</b> quote_out = temp_account.withdraw_with_proof(&proof, 0, <b>true</b>).into_coin(ctx);
    <b>let</b> deep_out = temp_account.withdraw_with_proof(&proof, 0, <b>true</b>).into_coin(ctx);

    temp_account.delete();

    (base_out, quote_out, deep_out)
}
</code></pre>



</details>

<a name="0x0_pool_modify_order"></a>

## Function `modify_order`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_modify_order">modify_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, order_id: u128, new_quantity: u64, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_modify_order">modify_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    order_id: u128,
    new_quantity: u64,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &TxContext,
) {
    <b>let</b> (base, quote, deep, <a href="order.md#0x0_order">order</a>) = self.<a href="book.md#0x0_book">book</a>.<a href="pool.md#0x0_pool_modify_order">modify_order</a>(order_id, new_quantity, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms());
    self.<a href="state.md#0x0_state">state</a>.process_modify(<a href="account.md#0x0_account">account</a>.owner(), base, quote, deep, ctx);
    self.<a href="vault.md#0x0_vault">vault</a>.settle_user(self.<a href="state.md#0x0_state">state</a>.user_mut(<a href="account.md#0x0_account">account</a>.owner(), ctx.epoch()), <a href="account.md#0x0_account">account</a>, proof);

    <a href="order.md#0x0_order">order</a>.emit_order_modified&lt;BaseAsset, QuoteAsset&gt;(self.id.to_inner(), <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms());
}
</code></pre>



</details>

<a name="0x0_pool_cancel_order"></a>

## Function `cancel_order`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_cancel_order">cancel_order</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, order_id: u128, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_cancel_order">cancel_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    order_id: u128,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &TxContext,
) {
    <b>let</b> <b>mut</b> <a href="order.md#0x0_order">order</a> = self.<a href="book.md#0x0_book">book</a>.<a href="pool.md#0x0_pool_cancel_order">cancel_order</a>(order_id);
    self.<a href="state.md#0x0_state">state</a>.process_cancel(&<b>mut</b> <a href="order.md#0x0_order">order</a>, order_id, <a href="account.md#0x0_account">account</a>.owner(), ctx);
    self.<a href="vault.md#0x0_vault">vault</a>.settle_user(self.<a href="state.md#0x0_state">state</a>.user_mut(<a href="account.md#0x0_account">account</a>.owner(), ctx.epoch()), <a href="account.md#0x0_account">account</a>, proof);

    <a href="order.md#0x0_order">order</a>.emit_order_canceled&lt;BaseAsset, QuoteAsset&gt;(self.id.to_inner(), <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms());
}
</code></pre>



</details>

<a name="0x0_pool_stake"></a>

## Function `stake`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_stake">stake</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, amount: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_stake">stake</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    amount: u64,
    ctx: &TxContext,
) {
    self.<a href="state.md#0x0_state">state</a>.process_stake(<a href="account.md#0x0_account">account</a>.owner(), amount, ctx);
    self.<a href="vault.md#0x0_vault">vault</a>.settle_user(self.<a href="state.md#0x0_state">state</a>.user_mut(<a href="account.md#0x0_account">account</a>.owner(), ctx.epoch()), <a href="account.md#0x0_account">account</a>, proof);
}
</code></pre>



</details>

<a name="0x0_pool_unstake"></a>

## Function `unstake`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_unstake">unstake</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_unstake">unstake</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    ctx: &TxContext,
) {
    <a href="account.md#0x0_account">account</a>.validate_proof(proof);

    self.<a href="state.md#0x0_state">state</a>.process_unstake(<a href="account.md#0x0_account">account</a>.owner(), ctx);
    self.<a href="vault.md#0x0_vault">vault</a>.settle_user(self.<a href="state.md#0x0_state">state</a>.user_mut(<a href="account.md#0x0_account">account</a>.owner(), ctx.epoch()), <a href="account.md#0x0_account">account</a>, proof);
}
</code></pre>



</details>

<a name="0x0_pool_submit_proposal"></a>

## Function `submit_proposal`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_submit_proposal">submit_proposal</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, taker_fee: u64, maker_fee: u64, stake_required: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_submit_proposal">submit_proposal</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
    ctx: &TxContext,
) {
    <a href="account.md#0x0_account">account</a>.validate_proof(proof);

    self.<a href="state.md#0x0_state">state</a>.process_proposal(<a href="account.md#0x0_account">account</a>.owner(), taker_fee, maker_fee, stake_required, ctx);
}
</code></pre>



</details>

<a name="0x0_pool_vote"></a>

## Function `vote`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_vote">vote</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, proposal_id: <b>address</b>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_vote">vote</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    proposal_id: <b>address</b>,
    ctx: &TxContext,
) {
    <a href="account.md#0x0_account">account</a>.validate_proof(proof);

    self.<a href="state.md#0x0_state">state</a>.process_vote(<a href="account.md#0x0_account">account</a>.owner(), proposal_id, ctx);
}
</code></pre>



</details>

<a name="0x0_pool_claim_rebates"></a>

## Function `claim_rebates`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_claim_rebates">claim_rebates</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_claim_rebates">claim_rebates</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    ctx: &TxContext,
) {
    <b>let</b> <a href="user.md#0x0_user">user</a> = self.<a href="state.md#0x0_state">state</a>.user_mut(<a href="account.md#0x0_account">account</a>.owner(), ctx.epoch());
    <a href="user.md#0x0_user">user</a>.<a href="pool.md#0x0_pool_claim_rebates">claim_rebates</a>();
    self.<a href="vault.md#0x0_vault">vault</a>.settle_user(<a href="user.md#0x0_user">user</a>, <a href="account.md#0x0_account">account</a>, proof);
}
</code></pre>



</details>

<a name="0x0_pool_get_amount_out"></a>

## Function `get_amount_out`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_get_amount_out">get_amount_out</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, base_amount: u64, quote_amount: u64): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_get_amount_out">get_amount_out</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    base_amount: u64,
    quote_amount: u64,
): (u64, u64) {
    self.<a href="book.md#0x0_book">book</a>.<a href="pool.md#0x0_pool_get_amount_out">get_amount_out</a>(base_amount, quote_amount)
}
</code></pre>



</details>

<a name="0x0_pool_mid_price"></a>

## Function `mid_price`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_mid_price">mid_price</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_mid_price">mid_price</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
): u64 {
    self.<a href="book.md#0x0_book">book</a>.<a href="pool.md#0x0_pool_mid_price">mid_price</a>()
}
</code></pre>



</details>

<a name="0x0_pool_user_open_orders"></a>

## Function `user_open_orders`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_user_open_orders">user_open_orders</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="user.md#0x0_user">user</a>: <b>address</b>): <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set_VecSet">vec_set::VecSet</a>&lt;u128&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_user_open_orders">user_open_orders</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    <a href="user.md#0x0_user">user</a>: <b>address</b>,
): VecSet&lt;u128&gt; {
    self.<a href="state.md#0x0_state">state</a>.<a href="user.md#0x0_user">user</a>(<a href="user.md#0x0_user">user</a>).open_orders()
}
</code></pre>



</details>

<a name="0x0_pool_get_level2_range"></a>

## Function `get_level2_range`



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
    self.<a href="book.md#0x0_book">book</a>.get_level2_range_and_ticks(price_low, price_high, <a href="pool.md#0x0_pool_MAX_U64">MAX_U64</a>, is_bid)
}
</code></pre>



</details>

<a name="0x0_pool_get_level2_ticks_from_mid"></a>

## Function `get_level2_ticks_from_mid`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_get_level2_ticks_from_mid">get_level2_ticks_from_mid</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, ticks: u64): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_get_level2_ticks_from_mid">get_level2_ticks_from_mid</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    ticks: u64,
): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;) {
    <b>let</b> (bid_price, bid_quantity) = self.<a href="book.md#0x0_book">book</a>.get_level2_range_and_ticks(<a href="pool.md#0x0_pool_MIN_PRICE">MIN_PRICE</a>, <a href="pool.md#0x0_pool_MAX_PRICE">MAX_PRICE</a>, ticks, <b>true</b>);
    <b>let</b> (ask_price, ask_quantity) = self.<a href="book.md#0x0_book">book</a>.get_level2_range_and_ticks(<a href="pool.md#0x0_pool_MIN_PRICE">MIN_PRICE</a>, <a href="pool.md#0x0_pool_MAX_PRICE">MAX_PRICE</a>, ticks, <b>false</b>);

    (bid_price, bid_quantity, ask_price, ask_quantity)
}
</code></pre>



</details>

<a name="0x0_pool_add_deep_price_point"></a>

## Function `add_deep_price_point`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_add_deep_price_point">add_deep_price_point</a>&lt;BaseAsset, QuoteAsset, DEEPBaseAsset, DEEPQuoteAsset&gt;(target_pool: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, reference_pool: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;DEEPBaseAsset, DEEPQuoteAsset&gt;, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_add_deep_price_point">add_deep_price_point</a>&lt;BaseAsset, QuoteAsset, DEEPBaseAsset, DEEPQuoteAsset&gt;(
    target_pool: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    reference_pool: &<a href="pool.md#0x0_pool_Pool">Pool</a>&lt;DEEPBaseAsset, DEEPQuoteAsset&gt;,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
) {
    <b>assert</b>!(reference_pool.<a href="pool.md#0x0_pool_whitelisted">whitelisted</a>(), <a href="pool.md#0x0_pool_EIneligibleReferencePool">EIneligibleReferencePool</a>);
    <b>let</b> <a href="deep_price.md#0x0_deep_price">deep_price</a> = reference_pool.<a href="pool.md#0x0_pool_mid_price">mid_price</a>();
    <b>let</b> pool_price = target_pool.<a href="pool.md#0x0_pool_mid_price">mid_price</a>();
    <b>let</b> deep_base_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;DEEPBaseAsset&gt;();
    <b>let</b> deep_quote_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;DEEPQuoteAsset&gt;();

    target_pool.<a href="vault.md#0x0_vault">vault</a>.<a href="pool.md#0x0_pool_add_deep_price_point">add_deep_price_point</a>(<a href="deep_price.md#0x0_deep_price">deep_price</a>, pool_price, deep_base_type, deep_quote_type, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>.timestamp_ms());
}
</code></pre>



</details>

<a name="0x0_pool_set_stable"></a>

## Function `set_stable`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_set_stable">set_stable</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, _cap: &<a href="pool.md#0x0_pool_DeepBookAdminCap">pool::DeepBookAdminCap</a>, stable: bool, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_set_stable">set_stable</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    _cap: &<a href="pool.md#0x0_pool_DeepBookAdminCap">DeepBookAdminCap</a>,
    stable: bool,
    ctx: &TxContext,
) {
    self.<a href="state.md#0x0_state">state</a>.governance_mut(ctx).<a href="pool.md#0x0_pool_set_stable">set_stable</a>(stable);
}
</code></pre>



</details>

<a name="0x0_pool_set_whitelist"></a>

## Function `set_whitelist`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_set_whitelist">set_whitelist</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, _cap: &<a href="pool.md#0x0_pool_DeepBookAdminCap">pool::DeepBookAdminCap</a>, whitelist: bool)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_set_whitelist">set_whitelist</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>&lt;BaseAsset, QuoteAsset&gt;,
    _cap: &<a href="pool.md#0x0_pool_DeepBookAdminCap">DeepBookAdminCap</a>,
    whitelist: bool,
) {
    <b>let</b> base = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;BaseAsset&gt;();
    <b>let</b> quote = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;QuoteAsset&gt;();
    <b>let</b> deep_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;DEEP&gt;();
    <b>assert</b>!(base == deep_type || quote == deep_type, <a href="pool.md#0x0_pool_EIneligibleWhitelist">EIneligibleWhitelist</a>);

    self.<a href="state.md#0x0_state">state</a>.<a href="pool.md#0x0_pool_set_whitelist">set_whitelist</a>(whitelist);
}
</code></pre>



</details>
