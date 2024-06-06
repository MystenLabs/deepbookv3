
<a name="0x0_order_info"></a>

# Module `0x0::order_info`

Order module defines the order struct and its methods.
All order matching happens in this module.


-  [Struct `OrderInfo`](#0x0_order_info_OrderInfo)
-  [Struct `OrderFilled`](#0x0_order_info_OrderFilled)
-  [Struct `OrderCanceled`](#0x0_order_info_OrderCanceled)
-  [Struct `OrderModified`](#0x0_order_info_OrderModified)
-  [Struct `OrderPlaced`](#0x0_order_info_OrderPlaced)
-  [Constants](#@Constants_0)
-  [Function `balance_manager_id`](#0x0_order_info_balance_manager_id)
-  [Function `pool_id`](#0x0_order_info_pool_id)
-  [Function `order_id`](#0x0_order_info_order_id)
-  [Function `client_order_id`](#0x0_order_info_client_order_id)
-  [Function `order_type`](#0x0_order_info_order_type)
-  [Function `self_matching_option`](#0x0_order_info_self_matching_option)
-  [Function `price`](#0x0_order_info_price)
-  [Function `is_bid`](#0x0_order_info_is_bid)
-  [Function `original_quantity`](#0x0_order_info_original_quantity)
-  [Function `executed_quantity`](#0x0_order_info_executed_quantity)
-  [Function `deep_per_base`](#0x0_order_info_deep_per_base)
-  [Function `cumulative_quote_quantity`](#0x0_order_info_cumulative_quote_quantity)
-  [Function `paid_fees`](#0x0_order_info_paid_fees)
-  [Function `epoch`](#0x0_order_info_epoch)
-  [Function `fee_is_deep`](#0x0_order_info_fee_is_deep)
-  [Function `status`](#0x0_order_info_status)
-  [Function `expire_timestamp`](#0x0_order_info_expire_timestamp)
-  [Function `fills`](#0x0_order_info_fills)
-  [Function `new`](#0x0_order_info_new)
-  [Function `market_order`](#0x0_order_info_market_order)
-  [Function `last_fill`](#0x0_order_info_last_fill)
-  [Function `set_order_id`](#0x0_order_info_set_order_id)
-  [Function `set_paid_fees`](#0x0_order_info_set_paid_fees)
-  [Function `add_fill`](#0x0_order_info_add_fill)
-  [Function `calculate_partial_fill_balances`](#0x0_order_info_calculate_partial_fill_balances)
-  [Function `to_order`](#0x0_order_info_to_order)
-  [Function `validate_inputs`](#0x0_order_info_validate_inputs)
-  [Function `assert_execution`](#0x0_order_info_assert_execution)
-  [Function `remaining_quantity`](#0x0_order_info_remaining_quantity)
-  [Function `crosses_price`](#0x0_order_info_crosses_price)
-  [Function `match_maker`](#0x0_order_info_match_maker)
-  [Function `emit_order_placed`](#0x0_order_info_emit_order_placed)
-  [Function `emit_order_filled`](#0x0_order_info_emit_order_filled)


<pre><code><b>use</b> <a href="balances.md#0x0_balances">0x0::balances</a>;
<b>use</b> <a href="constants.md#0x0_constants">0x0::constants</a>;
<b>use</b> <a href="fill.md#0x0_fill">0x0::fill</a>;
<b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="order.md#0x0_order">0x0::order</a>;
<b>use</b> <a href="dependencies/sui-framework/event.md#0x2_event">0x2::event</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
</code></pre>



<a name="0x0_order_info_OrderInfo"></a>

## Struct `OrderInfo`

OrderInfo struct represents all order information.
This objects gets created at the beginning of the order lifecycle and
gets updated until it is completed or placed in the book.
It is returned at the end of the order lifecycle.


<pre><code><b>struct</b> <a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a> <b>has</b> drop, store
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
<code>order_id: u128</code>
</dt>
<dd>

</dd>
<dt>
<code>balance_manager_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>

</dd>
<dt>
<code>client_order_id: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>trader: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>order_type: u8</code>
</dt>
<dd>

</dd>
<dt>
<code>self_matching_option: u8</code>
</dt>
<dd>

</dd>
<dt>
<code>price: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>is_bid: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>original_quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>deep_per_base: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>expire_timestamp: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>executed_quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>cumulative_quote_quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>fills: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="fill.md#0x0_fill_Fill">fill::Fill</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>fee_is_deep: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>paid_fees: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>epoch: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>status: u8</code>
</dt>
<dd>

</dd>
<dt>
<code>market_order: bool</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_order_info_OrderFilled"></a>

## Struct `OrderFilled`

Emitted when a maker order is filled.


<pre><code><b>struct</b> <a href="order_info.md#0x0_order_info_OrderFilled">OrderFilled</a> <b>has</b> <b>copy</b>, drop, store
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
<code>maker_order_id: u128</code>
</dt>
<dd>

</dd>
<dt>
<code>taker_order_id: u128</code>
</dt>
<dd>

</dd>
<dt>
<code>maker_client_order_id: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>taker_client_order_id: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>price: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>taker_is_bid: bool</code>
</dt>
<dd>

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
<code>maker_balance_manager_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>

</dd>
<dt>
<code>taker_balance_manager_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
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

<a name="0x0_order_info_OrderCanceled"></a>

## Struct `OrderCanceled`

Emitted when a maker order is canceled.


<pre><code><b>struct</b> <a href="order_info.md#0x0_order_info_OrderCanceled">OrderCanceled</a>&lt;BaseAsset, QuoteAsset&gt; <b>has</b> <b>copy</b>, drop, store
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
<code>price: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>is_bid: bool</code>
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
</dl>


</details>

<a name="0x0_order_info_OrderModified"></a>

## Struct `OrderModified`

Emitted when a maker order is modified.


<pre><code><b>struct</b> <a href="order_info.md#0x0_order_info_OrderModified">OrderModified</a>&lt;BaseAsset, QuoteAsset&gt; <b>has</b> <b>copy</b>, drop, store
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
<code>price: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>is_bid: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>new_quantity: u64</code>
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

<a name="0x0_order_info_OrderPlaced"></a>

## Struct `OrderPlaced`

Emitted when a maker order is injected into the order book.


<pre><code><b>struct</b> <a href="order_info.md#0x0_order_info_OrderPlaced">OrderPlaced</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>balance_manager_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>

</dd>
<dt>
<code>pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>

</dd>
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
<code>trader: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>price: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>is_bid: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>placed_quantity: u64</code>
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

<a name="@Constants_0"></a>

## Constants


<a name="0x0_order_info_EFOKOrderCannotBeFullyFilled"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EFOKOrderCannotBeFullyFilled">EFOKOrderCannotBeFullyFilled</a>: u64 = 6;
</code></pre>



<a name="0x0_order_info_EInvalidExpireTimestamp"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EInvalidExpireTimestamp">EInvalidExpireTimestamp</a>: u64 = 3;
</code></pre>



<a name="0x0_order_info_EInvalidOrderType"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EInvalidOrderType">EInvalidOrderType</a>: u64 = 4;
</code></pre>



<a name="0x0_order_info_EMarketOrderCannotBePostOnly"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EMarketOrderCannotBePostOnly">EMarketOrderCannotBePostOnly</a>: u64 = 7;
</code></pre>



<a name="0x0_order_info_EOrderBelowMinimumSize"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EOrderBelowMinimumSize">EOrderBelowMinimumSize</a>: u64 = 1;
</code></pre>



<a name="0x0_order_info_EOrderInvalidLotSize"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EOrderInvalidLotSize">EOrderInvalidLotSize</a>: u64 = 2;
</code></pre>



<a name="0x0_order_info_EOrderInvalidPrice"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EOrderInvalidPrice">EOrderInvalidPrice</a>: u64 = 0;
</code></pre>



<a name="0x0_order_info_EPOSTOrderCrossesOrderbook"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EPOSTOrderCrossesOrderbook">EPOSTOrderCrossesOrderbook</a>: u64 = 5;
</code></pre>



<a name="0x0_order_info_ESelfMatchingCancelTaker"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_ESelfMatchingCancelTaker">ESelfMatchingCancelTaker</a>: u64 = 8;
</code></pre>



<a name="0x0_order_info_balance_manager_id"></a>

## Function `balance_manager_id`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_balance_manager_id">balance_manager_id</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_balance_manager_id">balance_manager_id</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): ID {
    self.balance_manager_id
}
</code></pre>



</details>

<a name="0x0_order_info_pool_id"></a>

## Function `pool_id`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_pool_id">pool_id</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_pool_id">pool_id</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): ID {
    self.pool_id
}
</code></pre>



</details>

<a name="0x0_order_info_order_id"></a>

## Function `order_id`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_order_id">order_id</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u128
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_order_id">order_id</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u128 {
    self.order_id
}
</code></pre>



</details>

<a name="0x0_order_info_client_order_id"></a>

## Function `client_order_id`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_client_order_id">client_order_id</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_client_order_id">client_order_id</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u64 {
    self.client_order_id
}
</code></pre>



</details>

<a name="0x0_order_info_order_type"></a>

## Function `order_type`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_order_type">order_type</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_order_type">order_type</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u8 {
    self.order_type
}
</code></pre>



</details>

<a name="0x0_order_info_self_matching_option"></a>

## Function `self_matching_option`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_self_matching_option">self_matching_option</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_self_matching_option">self_matching_option</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u8 {
    self.self_matching_option
}
</code></pre>



</details>

<a name="0x0_order_info_price"></a>

## Function `price`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_price">price</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_price">price</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u64 {
    self.price
}
</code></pre>



</details>

<a name="0x0_order_info_is_bid"></a>

## Function `is_bid`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_is_bid">is_bid</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_is_bid">is_bid</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): bool{
    self.is_bid
}
</code></pre>



</details>

<a name="0x0_order_info_original_quantity"></a>

## Function `original_quantity`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_original_quantity">original_quantity</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_original_quantity">original_quantity</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u64 {
    self.original_quantity
}
</code></pre>



</details>

<a name="0x0_order_info_executed_quantity"></a>

## Function `executed_quantity`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_executed_quantity">executed_quantity</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_executed_quantity">executed_quantity</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u64 {
    self.executed_quantity
}
</code></pre>



</details>

<a name="0x0_order_info_deep_per_base"></a>

## Function `deep_per_base`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_deep_per_base">deep_per_base</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_deep_per_base">deep_per_base</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u64 {
    self.deep_per_base
}
</code></pre>



</details>

<a name="0x0_order_info_cumulative_quote_quantity"></a>

## Function `cumulative_quote_quantity`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_cumulative_quote_quantity">cumulative_quote_quantity</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_cumulative_quote_quantity">cumulative_quote_quantity</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u64 {
    self.cumulative_quote_quantity
}
</code></pre>



</details>

<a name="0x0_order_info_paid_fees"></a>

## Function `paid_fees`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_paid_fees">paid_fees</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_paid_fees">paid_fees</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u64 {
    self.paid_fees
}
</code></pre>



</details>

<a name="0x0_order_info_epoch"></a>

## Function `epoch`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_epoch">epoch</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_epoch">epoch</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u64 {
    self.epoch
}
</code></pre>



</details>

<a name="0x0_order_info_fee_is_deep"></a>

## Function `fee_is_deep`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_fee_is_deep">fee_is_deep</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_fee_is_deep">fee_is_deep</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): bool {
    self.fee_is_deep
}
</code></pre>



</details>

<a name="0x0_order_info_status"></a>

## Function `status`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_status">status</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_status">status</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u8 {
    self.status
}
</code></pre>



</details>

<a name="0x0_order_info_expire_timestamp"></a>

## Function `expire_timestamp`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_expire_timestamp">expire_timestamp</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_expire_timestamp">expire_timestamp</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u64 {
    self.expire_timestamp
}
</code></pre>



</details>

<a name="0x0_order_info_fills"></a>

## Function `fills`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_fills">fills</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="fill.md#0x0_fill_Fill">fill::Fill</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_fills">fills</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;Fill&gt; {
    self.fills
}
</code></pre>



</details>

<a name="0x0_order_info_new"></a>

## Function `new`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_new">new</a>(pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, balance_manager_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, client_order_id: u64, trader: <b>address</b>, order_type: u8, self_matching_option: u8, price: u64, quantity: u64, is_bid: bool, fee_is_deep: bool, epoch: u64, expire_timestamp: u64, deep_per_base: u64, market_order: bool): <a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_new">new</a>(
    pool_id: ID,
    balance_manager_id: ID,
    client_order_id: u64,
    trader: <b>address</b>,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    fee_is_deep: bool,
    epoch: u64,
    expire_timestamp: u64,
    deep_per_base: u64,
    market_order: bool,
): <a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a> {
    <a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a> {
        pool_id,
        order_id: 0,
        balance_manager_id,
        client_order_id,
        trader,
        order_type,
        self_matching_option,
        price,
        is_bid,
        original_quantity: quantity,
        deep_per_base,
        expire_timestamp,
        executed_quantity: 0,
        cumulative_quote_quantity: 0,
        fills: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
        fee_is_deep,
        epoch,
        paid_fees: 0,
        status: <a href="constants.md#0x0_constants_live">constants::live</a>(),
        market_order,
    }
}
</code></pre>



</details>

<a name="0x0_order_info_market_order"></a>

## Function `market_order`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_market_order">market_order</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_market_order">market_order</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): bool {
    self.market_order
}
</code></pre>



</details>

<a name="0x0_order_info_last_fill"></a>

## Function `last_fill`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_last_fill">last_fill</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_last_fill">last_fill</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): &Fill {
    &self.fills[self.fills.length() - 1]
}
</code></pre>



</details>

<a name="0x0_order_info_set_order_id"></a>

## Function `set_order_id`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_set_order_id">set_order_id</a>(self: &<b>mut</b> <a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>, order_id: u128)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_set_order_id">set_order_id</a>(self: &<b>mut</b> <a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>, order_id: u128) {
    self.order_id = order_id;
}
</code></pre>



</details>

<a name="0x0_order_info_set_paid_fees"></a>

## Function `set_paid_fees`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_set_paid_fees">set_paid_fees</a>(self: &<b>mut</b> <a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>, paid_fees: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_set_paid_fees">set_paid_fees</a>(self: &<b>mut</b> <a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>, paid_fees: u64) {
    self.paid_fees = paid_fees;
}
</code></pre>



</details>

<a name="0x0_order_info_add_fill"></a>

## Function `add_fill`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_add_fill">add_fill</a>(self: &<b>mut</b> <a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>, <a href="fill.md#0x0_fill">fill</a>: <a href="fill.md#0x0_fill_Fill">fill::Fill</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_add_fill">add_fill</a>(self: &<b>mut</b> <a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>, <a href="fill.md#0x0_fill">fill</a>: Fill) {
    self.fills.push_back(<a href="fill.md#0x0_fill">fill</a>);
}
</code></pre>



</details>

<a name="0x0_order_info_calculate_partial_fill_balances"></a>

## Function `calculate_partial_fill_balances`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_calculate_partial_fill_balances">calculate_partial_fill_balances</a>(self: &<b>mut</b> <a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>, taker_fee: u64, maker_fee: u64): (<a href="balances.md#0x0_balances_Balances">balances::Balances</a>, <a href="balances.md#0x0_balances_Balances">balances::Balances</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_calculate_partial_fill_balances">calculate_partial_fill_balances</a>(
    self: &<b>mut</b> <a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>,
    taker_fee: u64,
    maker_fee: u64,
): (Balances, Balances) {
    <b>let</b> deep_in = <a href="math.md#0x0_math_mul">math::mul</a>(
        self.deep_per_base,
        <a href="math.md#0x0_math_mul">math::mul</a>(self.executed_quantity, taker_fee)
    );
    self.paid_fees = deep_in;

    <b>let</b> <b>mut</b> settled_balances = <a href="balances.md#0x0_balances_new">balances::new</a>(0, 0, 0);
    <b>let</b> <b>mut</b> owed_balances = <a href="balances.md#0x0_balances_new">balances::new</a>(0, 0, 0);
    owed_balances.add_deep(deep_in);

    <b>if</b> (self.is_bid) {
        settled_balances.add_base(self.executed_quantity);
        owed_balances.add_quote(self.cumulative_quote_quantity);
    } <b>else</b> {
        settled_balances.add_quote(self.cumulative_quote_quantity);
        owed_balances.add_base(self.executed_quantity);
    };

    <b>let</b> remaining_quantity = self.<a href="order_info.md#0x0_order_info_remaining_quantity">remaining_quantity</a>();
    <b>if</b> (remaining_quantity &gt; 0 && !(self.<a href="order_info.md#0x0_order_info_order_type">order_type</a>() == <a href="constants.md#0x0_constants_immediate_or_cancel">constants::immediate_or_cancel</a>())) {
        <b>let</b> deep_in = <a href="math.md#0x0_math_mul">math::mul</a>(
            self.deep_per_base,
            <a href="math.md#0x0_math_mul">math::mul</a>(remaining_quantity, maker_fee)
        );
        owed_balances.add_deep(deep_in);
        <b>if</b> (self.is_bid) {
            owed_balances.add_quote(<a href="math.md#0x0_math_mul">math::mul</a>(remaining_quantity, self.<a href="order_info.md#0x0_order_info_price">price</a>()));
        } <b>else</b> {
            owed_balances.add_base(remaining_quantity);
        };
    };

    (settled_balances, owed_balances)
}
</code></pre>



</details>

<a name="0x0_order_info_to_order"></a>

## Function `to_order`

OrderInfo is converted to an Order before being injected into the order book.
This is done to save space in the order book. Order contains the minimum
information required to match orders.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_to_order">to_order</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): <a href="order.md#0x0_order_Order">order::Order</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_to_order">to_order</a>(
    self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>,
): Order {
    <a href="order.md#0x0_order_new">order::new</a>(
        self.order_id,
        self.balance_manager_id,
        self.client_order_id,
        self.<a href="order_info.md#0x0_order_info_remaining_quantity">remaining_quantity</a>(),
        self.deep_per_base,
        self.epoch,
        self.status,
        self.expire_timestamp,
    )
}
</code></pre>



</details>

<a name="0x0_order_info_validate_inputs"></a>

## Function `validate_inputs`

Validates that the initial order created meets the pool requirements.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_validate_inputs">validate_inputs</a>(<a href="order_info.md#0x0_order_info">order_info</a>: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>, tick_size: u64, min_size: u64, lot_size: u64, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_validate_inputs">validate_inputs</a>(
    <a href="order_info.md#0x0_order_info">order_info</a>: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>,
    tick_size: u64,
    min_size: u64,
    lot_size: u64,
    timestamp: u64,
) {
    <b>assert</b>!(<a href="order_info.md#0x0_order_info">order_info</a>.original_quantity &gt;= min_size, <a href="order_info.md#0x0_order_info_EOrderBelowMinimumSize">EOrderBelowMinimumSize</a>);
    <b>assert</b>!(<a href="order_info.md#0x0_order_info">order_info</a>.original_quantity % lot_size == 0, <a href="order_info.md#0x0_order_info_EOrderInvalidLotSize">EOrderInvalidLotSize</a>);
    <b>assert</b>!(<a href="order_info.md#0x0_order_info">order_info</a>.expire_timestamp &gt;= timestamp, <a href="order_info.md#0x0_order_info_EInvalidExpireTimestamp">EInvalidExpireTimestamp</a>);
    <b>assert</b>!(<a href="order_info.md#0x0_order_info">order_info</a>.order_type &gt;= <a href="constants.md#0x0_constants_no_restriction">constants::no_restriction</a>() && <a href="order_info.md#0x0_order_info">order_info</a>.<a href="order_info.md#0x0_order_info_order_type">order_type</a> &lt;= <a href="constants.md#0x0_constants_max_restriction">constants::max_restriction</a>(), <a href="order_info.md#0x0_order_info_EInvalidOrderType">EInvalidOrderType</a>);
    <b>if</b> (<a href="order_info.md#0x0_order_info">order_info</a>.market_order) {
        <b>assert</b>!(<a href="order_info.md#0x0_order_info">order_info</a>.order_type != <a href="constants.md#0x0_constants_post_only">constants::post_only</a>(), <a href="order_info.md#0x0_order_info_EMarketOrderCannotBePostOnly">EMarketOrderCannotBePostOnly</a>);
        <b>return</b>
    };
    <b>assert</b>!(<a href="order_info.md#0x0_order_info">order_info</a>.price &gt;= <a href="constants.md#0x0_constants_min_price">constants::min_price</a>() && <a href="order_info.md#0x0_order_info">order_info</a>.<a href="order_info.md#0x0_order_info_price">price</a> &lt;= <a href="constants.md#0x0_constants_max_price">constants::max_price</a>(), <a href="order_info.md#0x0_order_info_EOrderInvalidPrice">EOrderInvalidPrice</a>);
    <b>assert</b>!(<a href="order_info.md#0x0_order_info">order_info</a>.price % tick_size == 0, <a href="order_info.md#0x0_order_info_EOrderInvalidPrice">EOrderInvalidPrice</a>);
}
</code></pre>



</details>

<a name="0x0_order_info_assert_execution"></a>

## Function `assert_execution`

Assert order types after partial fill against the order book.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_assert_execution">assert_execution</a>(self: &<b>mut</b> <a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_assert_execution">assert_execution</a>(self: &<b>mut</b> <a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): bool {
    <b>if</b> (self.order_type == <a href="constants.md#0x0_constants_post_only">constants::post_only</a>())
        <b>assert</b>!(self.executed_quantity == 0, <a href="order_info.md#0x0_order_info_EPOSTOrderCrossesOrderbook">EPOSTOrderCrossesOrderbook</a>);
    <b>if</b> (self.order_type == <a href="constants.md#0x0_constants_fill_or_kill">constants::fill_or_kill</a>())
        <b>assert</b>!(self.executed_quantity == self.original_quantity, <a href="order_info.md#0x0_order_info_EFOKOrderCannotBeFullyFilled">EFOKOrderCannotBeFullyFilled</a>);
    <b>if</b> (self.order_type == <a href="constants.md#0x0_constants_immediate_or_cancel">constants::immediate_or_cancel</a>()) {
        <b>if</b> (self.<a href="order_info.md#0x0_order_info_remaining_quantity">remaining_quantity</a>() &gt; 0) {
            self.status = <a href="constants.md#0x0_constants_canceled">constants::canceled</a>();
        } <b>else</b> {
            self.status = <a href="constants.md#0x0_constants_filled">constants::filled</a>();
        };

        <b>return</b> <b>true</b>
    };

    <b>false</b>
}
</code></pre>



</details>

<a name="0x0_order_info_remaining_quantity"></a>

## Function `remaining_quantity`

Returns the remaining quantity for the order.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_remaining_quantity">remaining_quantity</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_remaining_quantity">remaining_quantity</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u64 {
    self.original_quantity - self.executed_quantity
}
</code></pre>



</details>

<a name="0x0_order_info_crosses_price"></a>

## Function `crosses_price`

Returns true if two opposite orders are overlapping in price.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_crosses_price">crosses_price</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>, <a href="order.md#0x0_order">order</a>: &<a href="order.md#0x0_order_Order">order::Order</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_crosses_price">crosses_price</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>, <a href="order.md#0x0_order">order</a>: &Order): bool {
    <b>let</b> maker_price = <a href="order.md#0x0_order">order</a>.<a href="order_info.md#0x0_order_info_price">price</a>();

    (self.original_quantity - self.executed_quantity &gt; 0 &&
    self.is_bid && self.price &gt;= maker_price ||
    !self.is_bid && self.<a href="order_info.md#0x0_order_info_price">price</a> &lt;= maker_price)
}
</code></pre>



</details>

<a name="0x0_order_info_match_maker"></a>

## Function `match_maker`

Matches an OrderInfo with an Order from the book. Appends a Fill to fills.
If the book order is expired, the Fill will have the expired flag set to true.
Funds for the match or an expired order are returned to the maker as settled.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_match_maker">match_maker</a>(self: &<b>mut</b> <a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>, maker: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, timestamp: u64): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_match_maker">match_maker</a>(
    self: &<b>mut</b> <a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>,
    maker: &<b>mut</b> Order,
    timestamp: u64,
): bool {
    <b>if</b> (!self.<a href="order_info.md#0x0_order_info_crosses_price">crosses_price</a>(maker)) <b>return</b> <b>false</b>;

    <b>if</b> (self.<a href="order_info.md#0x0_order_info_self_matching_option">self_matching_option</a>() == <a href="constants.md#0x0_constants_cancel_taker">constants::cancel_taker</a>()) {
        <b>assert</b>!(maker.<a href="order_info.md#0x0_order_info_balance_manager_id">balance_manager_id</a>() != self.<a href="order_info.md#0x0_order_info_balance_manager_id">balance_manager_id</a>(), <a href="order_info.md#0x0_order_info_ESelfMatchingCancelTaker">ESelfMatchingCancelTaker</a>);
    };
    <b>let</b> expire_maker =
        self.<a href="order_info.md#0x0_order_info_self_matching_option">self_matching_option</a>() == <a href="constants.md#0x0_constants_cancel_maker">constants::cancel_maker</a>() &&
        maker.<a href="order_info.md#0x0_order_info_balance_manager_id">balance_manager_id</a>() == self.<a href="order_info.md#0x0_order_info_balance_manager_id">balance_manager_id</a>();
    <b>let</b> <a href="fill.md#0x0_fill">fill</a> = maker.generate_fill(
        timestamp,
        self.<a href="order_info.md#0x0_order_info_remaining_quantity">remaining_quantity</a>(),
        self.is_bid,
        expire_maker
    );
    self.fills.push_back(<a href="fill.md#0x0_fill">fill</a>);
    <b>if</b> (<a href="fill.md#0x0_fill">fill</a>.expired()) <b>return</b> <b>true</b>;

    self.executed_quantity = self.executed_quantity + <a href="fill.md#0x0_fill">fill</a>.base_quantity();
    self.cumulative_quote_quantity = self.cumulative_quote_quantity + <a href="fill.md#0x0_fill">fill</a>.quote_quantity();
    self.status = <a href="constants.md#0x0_constants_partially_filled">constants::partially_filled</a>();
    <b>if</b> (self.<a href="order_info.md#0x0_order_info_remaining_quantity">remaining_quantity</a>() == 0) self.status = <a href="constants.md#0x0_constants_filled">constants::filled</a>();

    self.<a href="order_info.md#0x0_order_info_emit_order_filled">emit_order_filled</a>(
        maker,
        maker.<a href="order_info.md#0x0_order_info_price">price</a>(),
        <a href="fill.md#0x0_fill">fill</a>.base_quantity(),
        <a href="fill.md#0x0_fill">fill</a>.quote_quantity(),
        timestamp
    );

    <b>true</b>
}
</code></pre>



</details>

<a name="0x0_order_info_emit_order_placed"></a>

## Function `emit_order_placed`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_emit_order_placed">emit_order_placed</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_emit_order_placed">emit_order_placed</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>) {
    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="order_info.md#0x0_order_info_OrderPlaced">OrderPlaced</a> {
        balance_manager_id: self.balance_manager_id,
        pool_id: self.pool_id,
        order_id: self.order_id,
        client_order_id: self.client_order_id,
        is_bid: self.is_bid,
        trader: self.trader,
        placed_quantity: self.<a href="order_info.md#0x0_order_info_remaining_quantity">remaining_quantity</a>(),
        price: self.price,
        expire_timestamp: self.expire_timestamp,
    });
}
</code></pre>



</details>

<a name="0x0_order_info_emit_order_filled"></a>

## Function `emit_order_filled`



<pre><code><b>fun</b> <a href="order_info.md#0x0_order_info_emit_order_filled">emit_order_filled</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>, maker: &<a href="order.md#0x0_order_Order">order::Order</a>, price: u64, filled_quantity: u64, quote_quantity: u64, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="order_info.md#0x0_order_info_emit_order_filled">emit_order_filled</a>(
    self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>,
    maker: &Order,
    price: u64,
    filled_quantity: u64,
    quote_quantity: u64,
    timestamp: u64
) {
    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="order_info.md#0x0_order_info_OrderFilled">OrderFilled</a> {
        pool_id: self.pool_id,
        maker_order_id: maker.<a href="order_info.md#0x0_order_info_order_id">order_id</a>(),
        taker_order_id: self.order_id,
        maker_client_order_id: maker.<a href="order_info.md#0x0_order_info_client_order_id">client_order_id</a>(),
        taker_client_order_id: self.client_order_id,
        base_quantity: filled_quantity,
        quote_quantity: quote_quantity,
        price,
        maker_balance_manager_id: maker.<a href="order_info.md#0x0_order_info_balance_manager_id">balance_manager_id</a>(),
        taker_balance_manager_id: self.balance_manager_id,
        taker_is_bid: self.is_bid,
        timestamp,
    });
}
</code></pre>



</details>
