
<a name="0x0_order_info"></a>

# Module `0x0::order_info`

Order module defines the order struct and its methods.
All order matching happens in this module.


-  [Struct `OrderInfo`](#0x0_order_info_OrderInfo)
-  [Struct `OrderFilled`](#0x0_order_info_OrderFilled)
-  [Struct `OrderCanceled`](#0x0_order_info_OrderCanceled)
-  [Struct `OrderModified`](#0x0_order_info_OrderModified)
-  [Struct `OrderPlaced`](#0x0_order_info_OrderPlaced)
-  [Struct `Fill`](#0x0_order_info_Fill)
-  [Constants](#@Constants_0)
-  [Function `initial_order`](#0x0_order_info_initial_order)
-  [Function `pool_id`](#0x0_order_info_pool_id)
-  [Function `order_id`](#0x0_order_info_order_id)
-  [Function `client_order_id`](#0x0_order_info_client_order_id)
-  [Function `owner`](#0x0_order_info_owner)
-  [Function `order_type`](#0x0_order_info_order_type)
-  [Function `price`](#0x0_order_info_price)
-  [Function `is_bid`](#0x0_order_info_is_bid)
-  [Function `original_quantity`](#0x0_order_info_original_quantity)
-  [Function `executed_quantity`](#0x0_order_info_executed_quantity)
-  [Function `cumulative_quote_quantity`](#0x0_order_info_cumulative_quote_quantity)
-  [Function `paid_fees`](#0x0_order_info_paid_fees)
-  [Function `maker_fee`](#0x0_order_info_maker_fee)
-  [Function `fee_is_deep`](#0x0_order_info_fee_is_deep)
-  [Function `status`](#0x0_order_info_status)
-  [Function `expire_timestamp`](#0x0_order_info_expire_timestamp)
-  [Function `self_matching_prevention`](#0x0_order_info_self_matching_prevention)
-  [Function `fills`](#0x0_order_info_fills)
-  [Function `last_fill`](#0x0_order_info_last_fill)
-  [Function `set_order_id`](#0x0_order_info_set_order_id)
-  [Function `to_order`](#0x0_order_info_to_order)
-  [Function `validate_inputs`](#0x0_order_info_validate_inputs)
-  [Function `remaining_quantity`](#0x0_order_info_remaining_quantity)
-  [Function `assert_post_only`](#0x0_order_info_assert_post_only)
-  [Function `assert_fill_or_kill`](#0x0_order_info_assert_fill_or_kill)
-  [Function `is_immediate_or_cancel`](#0x0_order_info_is_immediate_or_cancel)
-  [Function `fill_or_kill`](#0x0_order_info_fill_or_kill)
-  [Function `fill_status`](#0x0_order_info_fill_status)
-  [Function `settled_quantities`](#0x0_order_info_settled_quantities)
-  [Function `crosses_price`](#0x0_order_info_crosses_price)
-  [Function `match_maker`](#0x0_order_info_match_maker)
-  [Function `emit_order_placed`](#0x0_order_info_emit_order_placed)
-  [Function `emit_order_filled`](#0x0_order_info_emit_order_filled)


<pre><code><b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="order.md#0x0_order">0x0::order</a>;
<b>use</b> <a href="utils.md#0x0_utils">0x0::utils</a>;
<b>use</b> <a href="dependencies/sui-framework/event.md#0x2_event">0x2::event</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
</code></pre>



<a name="0x0_order_info_OrderInfo"></a>

## Struct `OrderInfo`

OrderInfo struct represents all order information.
This objects gets created at the beginning of the order lifecycle and
gets updated until it is completed or placed in the book.
It is returned to the user at the end of the order lifecycle.


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
<code>client_order_id: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>owner: <b>address</b></code>
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
<code>fills: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="order_info.md#0x0_order_info_Fill">order_info::Fill</a>&gt;</code>
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
<code>maker_fee: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>status: u8</code>
</dt>
<dd>

</dd>
<dt>
<code>self_matching_prevention: bool</code>
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
<code>owner: <b>address</b></code>
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
<code>owner: <b>address</b></code>
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
<code>owner: <b>address</b></code>
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

<a name="0x0_order_info_Fill"></a>

## Struct `Fill`

Fill struct represents the results of a match between two orders.
It is used to update the state.


<pre><code><b>struct</b> <a href="order_info.md#0x0_order_info_Fill">Fill</a> <b>has</b> <b>copy</b>, drop, store
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
<code>owner: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>expired: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>complete: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>settled_base: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>settled_quote: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>settled_deep: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_order_info_EOrderBelowMinimumSize"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EOrderBelowMinimumSize">EOrderBelowMinimumSize</a>: u64 = 1;
</code></pre>



<a name="0x0_order_info_EOrderInvalidLotSize"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EOrderInvalidLotSize">EOrderInvalidLotSize</a>: u64 = 2;
</code></pre>



<a name="0x0_order_info_FILLED"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_FILLED">FILLED</a>: u8 = 2;
</code></pre>



<a name="0x0_order_info_LIVE"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_LIVE">LIVE</a>: u8 = 0;
</code></pre>



<a name="0x0_order_info_PARTIALLY_FILLED"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_PARTIALLY_FILLED">PARTIALLY_FILLED</a>: u8 = 1;
</code></pre>



<a name="0x0_order_info_EFOKOrderCannotBeFullyFilled"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EFOKOrderCannotBeFullyFilled">EFOKOrderCannotBeFullyFilled</a>: u64 = 6;
</code></pre>



<a name="0x0_order_info_EInvalidExpireTimestamp"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EInvalidExpireTimestamp">EInvalidExpireTimestamp</a>: u64 = 3;
</code></pre>



<a name="0x0_order_info_EInvalidOrderType"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EInvalidOrderType">EInvalidOrderType</a>: u64 = 4;
</code></pre>



<a name="0x0_order_info_EOrderInvalidPrice"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EOrderInvalidPrice">EOrderInvalidPrice</a>: u64 = 0;
</code></pre>



<a name="0x0_order_info_EPOSTOrderCrossesOrderbook"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_EPOSTOrderCrossesOrderbook">EPOSTOrderCrossesOrderbook</a>: u64 = 5;
</code></pre>



<a name="0x0_order_info_FILL_OR_KILL"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_FILL_OR_KILL">FILL_OR_KILL</a>: u8 = 2;
</code></pre>



<a name="0x0_order_info_IMMEDIATE_OR_CANCEL"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_IMMEDIATE_OR_CANCEL">IMMEDIATE_OR_CANCEL</a>: u8 = 1;
</code></pre>



<a name="0x0_order_info_MAX_PRICE"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_MAX_PRICE">MAX_PRICE</a>: u64 = 4611686018427387904;
</code></pre>



<a name="0x0_order_info_MAX_RESTRICTION"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_MAX_RESTRICTION">MAX_RESTRICTION</a>: u8 = 3;
</code></pre>



<a name="0x0_order_info_MIN_PRICE"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_MIN_PRICE">MIN_PRICE</a>: u64 = 1;
</code></pre>



<a name="0x0_order_info_NO_RESTRICTION"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_NO_RESTRICTION">NO_RESTRICTION</a>: u8 = 0;
</code></pre>



<a name="0x0_order_info_POST_ONLY"></a>



<pre><code><b>const</b> <a href="order_info.md#0x0_order_info_POST_ONLY">POST_ONLY</a>: u8 = 3;
</code></pre>



<a name="0x0_order_info_initial_order"></a>

## Function `initial_order`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_initial_order">initial_order</a>(pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, client_order_id: u64, owner: <b>address</b>, trader: <b>address</b>, order_type: u8, price: u64, quantity: u64, is_bid: bool, expire_timestamp: u64, maker_fee: u64): <a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_initial_order">initial_order</a>(
    pool_id: ID,
    client_order_id: u64,
    owner: <b>address</b>,
    trader: <b>address</b>,
    order_type: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    expire_timestamp: u64,
    maker_fee: u64,
): <a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a> {
    <a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a> {
        pool_id,
        order_id: 0,
        client_order_id,
        owner,
        trader,
        order_type,
        price,
        is_bid,
        original_quantity: quantity,
        expire_timestamp,
        executed_quantity: 0,
        cumulative_quote_quantity: 0,
        fills: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
        fee_is_deep: <b>false</b>,
        paid_fees: 0,
        maker_fee,
        status: <a href="order_info.md#0x0_order_info_LIVE">LIVE</a>,
        self_matching_prevention: <b>false</b>,
    }
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

<a name="0x0_order_info_owner"></a>

## Function `owner`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_owner">owner</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_owner">owner</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): <b>address</b> {
    self.owner
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

<a name="0x0_order_info_maker_fee"></a>

## Function `maker_fee`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_maker_fee">maker_fee</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_maker_fee">maker_fee</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): u64 {
    self.maker_fee
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

<a name="0x0_order_info_self_matching_prevention"></a>

## Function `self_matching_prevention`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_self_matching_prevention">self_matching_prevention</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_self_matching_prevention">self_matching_prevention</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): bool {
    self.self_matching_prevention
}
</code></pre>



</details>

<a name="0x0_order_info_fills"></a>

## Function `fills`



<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_fills">fills</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="order_info.md#0x0_order_info_Fill">order_info::Fill</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order_info.md#0x0_order_info_fills">fills</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="order_info.md#0x0_order_info_Fill">Fill</a>&gt; {
    self.fills
}
</code></pre>



</details>

<a name="0x0_order_info_last_fill"></a>

## Function `last_fill`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_last_fill">last_fill</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): &<a href="order_info.md#0x0_order_info_Fill">order_info::Fill</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_last_fill">last_fill</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): &<a href="order_info.md#0x0_order_info_Fill">Fill</a> {
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
    self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>
): Order {
    <b>let</b> unpaid_fees = self.<a href="order_info.md#0x0_order_info_remaining_quantity">remaining_quantity</a>() * self.<a href="order_info.md#0x0_order_info_maker_fee">maker_fee</a>();
    <a href="order.md#0x0_order_init_order">order::init_order</a>(
        self.order_id,
        self.client_order_id,
        self.owner,
        self.original_quantity,
        unpaid_fees,
        self.fee_is_deep,
        self.status,
        self.expire_timestamp,
        self.self_matching_prevention,
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
    <b>assert</b>!(<a href="order_info.md#0x0_order_info">order_info</a>.price &gt;= <a href="order_info.md#0x0_order_info_MIN_PRICE">MIN_PRICE</a> && <a href="order_info.md#0x0_order_info">order_info</a>.<a href="order_info.md#0x0_order_info_price">price</a> &lt;= <a href="order_info.md#0x0_order_info_MAX_PRICE">MAX_PRICE</a>, <a href="order_info.md#0x0_order_info_EOrderInvalidPrice">EOrderInvalidPrice</a>);
    <b>assert</b>!(<a href="order_info.md#0x0_order_info">order_info</a>.price % tick_size == 0, <a href="order_info.md#0x0_order_info_EOrderInvalidPrice">EOrderInvalidPrice</a>);
    <b>assert</b>!(<a href="order_info.md#0x0_order_info">order_info</a>.original_quantity &gt;= min_size, <a href="order_info.md#0x0_order_info_EOrderBelowMinimumSize">EOrderBelowMinimumSize</a>);
    <b>assert</b>!(<a href="order_info.md#0x0_order_info">order_info</a>.original_quantity % lot_size == 0, <a href="order_info.md#0x0_order_info_EOrderInvalidLotSize">EOrderInvalidLotSize</a>);
    <b>assert</b>!(<a href="order_info.md#0x0_order_info">order_info</a>.expire_timestamp &gt;= timestamp, <a href="order_info.md#0x0_order_info_EInvalidExpireTimestamp">EInvalidExpireTimestamp</a>);
    <b>assert</b>!(<a href="order_info.md#0x0_order_info">order_info</a>.order_type &gt;= <a href="order_info.md#0x0_order_info_NO_RESTRICTION">NO_RESTRICTION</a> && <a href="order_info.md#0x0_order_info">order_info</a>.<a href="order_info.md#0x0_order_info_order_type">order_type</a> &lt;= <a href="order_info.md#0x0_order_info_MAX_RESTRICTION">MAX_RESTRICTION</a>, <a href="order_info.md#0x0_order_info_EInvalidOrderType">EInvalidOrderType</a>);
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

<a name="0x0_order_info_assert_post_only"></a>

## Function `assert_post_only`

Asserts that the order doesn't have any fills.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_assert_post_only">assert_post_only</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_assert_post_only">assert_post_only</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>) {
    <b>if</b> (self.order_type == <a href="order_info.md#0x0_order_info_POST_ONLY">POST_ONLY</a>)
        <b>assert</b>!(self.executed_quantity == 0, <a href="order_info.md#0x0_order_info_EPOSTOrderCrossesOrderbook">EPOSTOrderCrossesOrderbook</a>);
}
</code></pre>



</details>

<a name="0x0_order_info_assert_fill_or_kill"></a>

## Function `assert_fill_or_kill`

Asserts that the order is fully filled.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_assert_fill_or_kill">assert_fill_or_kill</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_assert_fill_or_kill">assert_fill_or_kill</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>) {
    <b>if</b> (self.order_type == <a href="order_info.md#0x0_order_info_FILL_OR_KILL">FILL_OR_KILL</a>)
        <b>assert</b>!(self.executed_quantity == self.original_quantity, <a href="order_info.md#0x0_order_info_EFOKOrderCannotBeFullyFilled">EFOKOrderCannotBeFullyFilled</a>);
}
</code></pre>



</details>

<a name="0x0_order_info_is_immediate_or_cancel"></a>

## Function `is_immediate_or_cancel`

Checks whether this is an immediate or cancel type of order.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_is_immediate_or_cancel">is_immediate_or_cancel</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_is_immediate_or_cancel">is_immediate_or_cancel</a>(self: &<a href="order_info.md#0x0_order_info_OrderInfo">OrderInfo</a>): bool {
    self.order_type == <a href="order_info.md#0x0_order_info_IMMEDIATE_OR_CANCEL">IMMEDIATE_OR_CANCEL</a>
}
</code></pre>



</details>

<a name="0x0_order_info_fill_or_kill"></a>

## Function `fill_or_kill`

Returns the fill or kill constant.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_fill_or_kill">fill_or_kill</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_fill_or_kill">fill_or_kill</a>(): u8 {
    <a href="order_info.md#0x0_order_info_FILL_OR_KILL">FILL_OR_KILL</a>
}
</code></pre>



</details>

<a name="0x0_order_info_fill_status"></a>

## Function `fill_status`

Returns the result of the fill and the maker id & owner.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_fill_status">fill_status</a>(fill: &<a href="order_info.md#0x0_order_info_Fill">order_info::Fill</a>): (u128, <b>address</b>, bool, bool)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_fill_status">fill_status</a>(fill: &<a href="order_info.md#0x0_order_info_Fill">Fill</a>): (u128, <b>address</b>, bool, bool) {
    (fill.order_id, fill.owner, fill.expired, fill.complete)
}
</code></pre>



</details>

<a name="0x0_order_info_settled_quantities"></a>

## Function `settled_quantities`

Returns the settled quantities for the fill.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order_info.md#0x0_order_info_settled_quantities">settled_quantities</a>(fill: &<a href="order_info.md#0x0_order_info_Fill">order_info::Fill</a>): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order_info.md#0x0_order_info_settled_quantities">settled_quantities</a>(fill: &<a href="order_info.md#0x0_order_info_Fill">Fill</a>): (u64, u64, u64) {
    (fill.settled_base, fill.settled_quote, fill.settled_deep)
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
    <b>let</b> (is_bid, price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(<a href="order.md#0x0_order">order</a>.<a href="order_info.md#0x0_order_info_order_id">order_id</a>());

    (
        self.original_quantity - self.executed_quantity &gt; 0 &&
        ((self.is_bid && !is_bid && self.price &gt;= price) ||
        (!self.is_bid && is_bid && self.<a href="order_info.md#0x0_order_info_price">price</a> &lt;= price))
    )
}
</code></pre>



</details>

<a name="0x0_order_info_match_maker"></a>

## Function `match_maker`

Matches an OrderInfo with an Order from the book. Returns a Fill.
If the book order is expired, it returns a Fill with the expired flag set to true.
Funds for an expired order are returned to the maker as settled.


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
    <b>let</b> maker_quantity = maker.quantity();
    <b>if</b> (maker.<a href="order_info.md#0x0_order_info_expire_timestamp">expire_timestamp</a>() &lt; timestamp) {
        maker.set_expired();
        <b>let</b> cancel_quantity = maker_quantity;
        <b>let</b> (base, quote, deep) = maker.cancel_amounts(
            cancel_quantity,
            <b>false</b>,
        );
        self.fills.push_back(<a href="order_info.md#0x0_order_info_Fill">Fill</a> {
            order_id: maker.<a href="order_info.md#0x0_order_info_order_id">order_id</a>(),
            owner: maker.<a href="order_info.md#0x0_order_info_owner">owner</a>(),
            expired: <b>true</b>,
            complete: <b>false</b>,
            settled_base: base,
            settled_quote: quote,
            settled_deep: deep,
        });

        <b>return</b> <b>true</b>
    };

    <b>let</b> (_, price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(maker.<a href="order_info.md#0x0_order_info_order_id">order_id</a>());
    <b>let</b> filled_quantity = <a href="math.md#0x0_math_min">math::min</a>(self.<a href="order_info.md#0x0_order_info_remaining_quantity">remaining_quantity</a>(), maker_quantity);
    <b>let</b> quote_quantity = <a href="math.md#0x0_math_mul">math::mul</a>(filled_quantity, price);
    maker.set_quantity(maker_quantity - filled_quantity);
    self.executed_quantity = self.executed_quantity + filled_quantity;
    self.cumulative_quote_quantity = self.cumulative_quote_quantity + quote_quantity;

    self.status = <a href="order_info.md#0x0_order_info_PARTIALLY_FILLED">PARTIALLY_FILLED</a>;
    maker.set_partially_filled();
    <b>if</b> (self.<a href="order_info.md#0x0_order_info_remaining_quantity">remaining_quantity</a>() == 0) self.status = <a href="order_info.md#0x0_order_info_FILLED">FILLED</a>;
    <b>if</b> (maker.quantity() == 0) maker.set_filled();

    <b>let</b> unpaid_fees = maker.unpaid_fees();
    <b>let</b> maker_fees = <a href="math.md#0x0_math_div">math::div</a>(<a href="math.md#0x0_math_mul">math::mul</a>(filled_quantity, unpaid_fees), maker.quantity());
    maker.set_unpaid_fees(unpaid_fees - maker_fees);

    self.<a href="order_info.md#0x0_order_info_emit_order_filled">emit_order_filled</a>(
        maker,
        price,
        filled_quantity,
        quote_quantity,
        timestamp
    );

    self.fills.push_back(<a href="order_info.md#0x0_order_info_Fill">Fill</a> {
        order_id: maker.<a href="order_info.md#0x0_order_info_order_id">order_id</a>(),
        owner: maker.<a href="order_info.md#0x0_order_info_owner">owner</a>(),
        expired: <b>false</b>,
        complete: maker.quantity() == 0,
        settled_base: <b>if</b> (self.is_bid) filled_quantity <b>else</b> 0,
        settled_quote: <b>if</b> (self.is_bid) 0 <b>else</b> quote_quantity,
        settled_deep: 0,
    });

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
        pool_id: self.pool_id,
        order_id: self.order_id,
        client_order_id: self.client_order_id,
        is_bid: self.is_bid,
        owner: self.owner,
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
        maker_address: maker.<a href="order_info.md#0x0_order_info_owner">owner</a>(),
        taker_address: self.owner,
        taker_is_bid: self.is_bid,
        timestamp,
    });
}
</code></pre>



</details>
