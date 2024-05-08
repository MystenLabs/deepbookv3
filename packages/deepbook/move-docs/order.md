
<a name="0x0_order"></a>

# Module `0x0::order`

Order module defines the order struct and its methods.
All order matching happens in this module.


-  [Struct `OrderInfo`](#0x0_order_OrderInfo)
-  [Struct `Order`](#0x0_order_Order)
-  [Struct `OrderFilled`](#0x0_order_OrderFilled)
-  [Struct `OrderCanceled`](#0x0_order_OrderCanceled)
-  [Struct `OrderModified`](#0x0_order_OrderModified)
-  [Struct `OrderPlaced`](#0x0_order_OrderPlaced)
-  [Struct `Fill`](#0x0_order_Fill)
-  [Constants](#@Constants_0)
-  [Function `initial_order`](#0x0_order_initial_order)
-  [Function `pool_id`](#0x0_order_pool_id)
-  [Function `order_id`](#0x0_order_order_id)
-  [Function `client_order_id`](#0x0_order_client_order_id)
-  [Function `owner`](#0x0_order_owner)
-  [Function `order_type`](#0x0_order_order_type)
-  [Function `price`](#0x0_order_price)
-  [Function `is_bid`](#0x0_order_is_bid)
-  [Function `original_quantity`](#0x0_order_original_quantity)
-  [Function `executed_quantity`](#0x0_order_executed_quantity)
-  [Function `cumulative_quote_quantity`](#0x0_order_cumulative_quote_quantity)
-  [Function `paid_fees`](#0x0_order_paid_fees)
-  [Function `total_fees`](#0x0_order_total_fees)
-  [Function `fee_is_deep`](#0x0_order_fee_is_deep)
-  [Function `status`](#0x0_order_status)
-  [Function `expire_timestamp`](#0x0_order_expire_timestamp)
-  [Function `self_matching_prevention`](#0x0_order_self_matching_prevention)
-  [Function `book_order_id`](#0x0_order_book_order_id)
-  [Function `book_client_order_id`](#0x0_order_book_client_order_id)
-  [Function `book_quantity`](#0x0_order_book_quantity)
-  [Function `book_unpaid_fees`](#0x0_order_book_unpaid_fees)
-  [Function `book_fee_is_deep`](#0x0_order_book_fee_is_deep)
-  [Function `book_status`](#0x0_order_book_status)
-  [Function `book_expire_timestamp`](#0x0_order_book_expire_timestamp)
-  [Function `book_self_matching_prevention`](#0x0_order_book_self_matching_prevention)
-  [Function `to_order`](#0x0_order_to_order)
-  [Function `validate_inputs`](#0x0_order_validate_inputs)
-  [Function `validate_modification`](#0x0_order_validate_modification)
-  [Function `crosses_price`](#0x0_order_crosses_price)
-  [Function `remaining_quantity`](#0x0_order_remaining_quantity)
-  [Function `assert_post_only`](#0x0_order_assert_post_only)
-  [Function `assert_fill_or_kill`](#0x0_order_assert_fill_or_kill)
-  [Function `is_immediate_or_cancel`](#0x0_order_is_immediate_or_cancel)
-  [Function `fill_or_kill`](#0x0_order_fill_or_kill)
-  [Function `set_total_fees`](#0x0_order_set_total_fees)
-  [Function `set_canceled`](#0x0_order_set_canceled)
-  [Function `set_expired`](#0x0_order_set_expired)
-  [Function `fill_status`](#0x0_order_fill_status)
-  [Function `settled_quantities`](#0x0_order_settled_quantities)
-  [Function `match_maker`](#0x0_order_match_maker)
-  [Function `cancel_amounts`](#0x0_order_cancel_amounts)
-  [Function `refunds`](#0x0_order_refunds)
-  [Function `emit_order_filled`](#0x0_order_emit_order_filled)
-  [Function `emit_order_placed`](#0x0_order_emit_order_placed)
-  [Function `emit_order_canceled`](#0x0_order_emit_order_canceled)
-  [Function `emit_order_modified`](#0x0_order_emit_order_modified)


<pre><code><b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="utils.md#0x0_utils">0x0::utils</a>;
<b>use</b> <a href="dependencies/sui-framework/event.md#0x2_event">0x2::event</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
</code></pre>



<a name="0x0_order_OrderInfo"></a>

## Struct `OrderInfo`

OrderInfo struct represents all order information.
This objects gets created at the beginning of the order lifecycle and
gets updated until it is completed or placed in the book.
It is returned to the user at the end of the order lifecycle.


<pre><code><b>struct</b> <a href="order.md#0x0_order_OrderInfo">OrderInfo</a> <b>has</b> drop, store
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
<code>paid_fees: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>total_fees: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>fee_is_deep: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>status: u8</code>
</dt>
<dd>

</dd>
<dt>
<code>expire_timestamp: u64</code>
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

<a name="0x0_order_Order"></a>

## Struct `Order`

Order struct represents the order in the order book. It is optimized for space.


<pre><code><b>struct</b> <a href="order.md#0x0_order_Order">Order</a> <b>has</b> drop, store
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
<code>owner: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>unpaid_fees: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>fee_is_deep: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>status: u8</code>
</dt>
<dd>

</dd>
<dt>
<code>expire_timestamp: u64</code>
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

<a name="0x0_order_OrderFilled"></a>

## Struct `OrderFilled`

Emitted when a maker order is filled.


<pre><code><b>struct</b> <a href="order.md#0x0_order_OrderFilled">OrderFilled</a> <b>has</b> <b>copy</b>, drop, store
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
<code>is_bid: bool</code>
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

<a name="0x0_order_OrderCanceled"></a>

## Struct `OrderCanceled`

Emitted when a maker order is canceled.


<pre><code><b>struct</b> <a href="order.md#0x0_order_OrderCanceled">OrderCanceled</a>&lt;BaseAsset, QuoteAsset&gt; <b>has</b> <b>copy</b>, drop, store
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

<a name="0x0_order_OrderModified"></a>

## Struct `OrderModified`

Emitted when a maker order is modified.


<pre><code><b>struct</b> <a href="order.md#0x0_order_OrderModified">OrderModified</a>&lt;BaseAsset, QuoteAsset&gt; <b>has</b> <b>copy</b>, drop, store
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

<a name="0x0_order_OrderPlaced"></a>

## Struct `OrderPlaced`

Emitted when a maker order is injected into the order book.


<pre><code><b>struct</b> <a href="order.md#0x0_order_OrderPlaced">OrderPlaced</a>&lt;BaseAsset, QuoteAsset&gt; <b>has</b> <b>copy</b>, drop, store
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
<code>original_quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>executed_quantity: u64</code>
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

<a name="0x0_order_Fill"></a>

## Struct `Fill`

Fill struct represents the results of a match between two orders.
It is used to update the state.


<pre><code><b>struct</b> <a href="order.md#0x0_order_Fill">Fill</a> <b>has</b> drop
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


<a name="0x0_order_CANCELED"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_CANCELED">CANCELED</a>: u8 = 3;
</code></pre>



<a name="0x0_order_EFOKOrderCannotBeFullyFilled"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EFOKOrderCannotBeFullyFilled">EFOKOrderCannotBeFullyFilled</a>: u64 = 6;
</code></pre>



<a name="0x0_order_EInvalidExpireTimestamp"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EInvalidExpireTimestamp">EInvalidExpireTimestamp</a>: u64 = 3;
</code></pre>



<a name="0x0_order_EInvalidNewQuantity"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EInvalidNewQuantity">EInvalidNewQuantity</a>: u64 = 7;
</code></pre>



<a name="0x0_order_EInvalidOrderType"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EInvalidOrderType">EInvalidOrderType</a>: u64 = 4;
</code></pre>



<a name="0x0_order_EOrderBelowMinimumSize"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EOrderBelowMinimumSize">EOrderBelowMinimumSize</a>: u64 = 1;
</code></pre>



<a name="0x0_order_EOrderExpired"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EOrderExpired">EOrderExpired</a>: u64 = 8;
</code></pre>



<a name="0x0_order_EOrderInvalidLotSize"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EOrderInvalidLotSize">EOrderInvalidLotSize</a>: u64 = 2;
</code></pre>



<a name="0x0_order_EOrderInvalidPrice"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EOrderInvalidPrice">EOrderInvalidPrice</a>: u64 = 0;
</code></pre>



<a name="0x0_order_EPOSTOrderCrossesOrderbook"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EPOSTOrderCrossesOrderbook">EPOSTOrderCrossesOrderbook</a>: u64 = 5;
</code></pre>



<a name="0x0_order_EXPIRED"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EXPIRED">EXPIRED</a>: u8 = 4;
</code></pre>



<a name="0x0_order_FILLED"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_FILLED">FILLED</a>: u8 = 2;
</code></pre>



<a name="0x0_order_FILL_OR_KILL"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_FILL_OR_KILL">FILL_OR_KILL</a>: u8 = 2;
</code></pre>



<a name="0x0_order_IMMEDIATE_OR_CANCEL"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_IMMEDIATE_OR_CANCEL">IMMEDIATE_OR_CANCEL</a>: u8 = 1;
</code></pre>



<a name="0x0_order_LIVE"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_LIVE">LIVE</a>: u8 = 0;
</code></pre>



<a name="0x0_order_MAX_PRICE"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_MAX_PRICE">MAX_PRICE</a>: u64 = 4611686018427387904;
</code></pre>



<a name="0x0_order_MAX_RESTRICTION"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_MAX_RESTRICTION">MAX_RESTRICTION</a>: u8 = 3;
</code></pre>



<a name="0x0_order_MIN_PRICE"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_MIN_PRICE">MIN_PRICE</a>: u64 = 1;
</code></pre>



<a name="0x0_order_NO_RESTRICTION"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_NO_RESTRICTION">NO_RESTRICTION</a>: u8 = 0;
</code></pre>



<a name="0x0_order_PARTIALLY_FILLED"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_PARTIALLY_FILLED">PARTIALLY_FILLED</a>: u8 = 1;
</code></pre>



<a name="0x0_order_POST_ONLY"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_POST_ONLY">POST_ONLY</a>: u8 = 3;
</code></pre>



<a name="0x0_order_initial_order"></a>

## Function `initial_order`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_initial_order">initial_order</a>(pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, order_id: u128, client_order_id: u64, order_type: u8, price: u64, quantity: u64, fee_is_deep: bool, is_bid: bool, owner: <b>address</b>, expire_timestamp: u64): <a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_initial_order">initial_order</a>(
    pool_id: ID,
    order_id: u128,
    client_order_id: u64,
    order_type: u8,
    price: u64,
    quantity: u64,
    fee_is_deep: bool,
    is_bid: bool,
    owner: <b>address</b>,
    expire_timestamp: u64,
): <a href="order.md#0x0_order_OrderInfo">OrderInfo</a> {
    <a href="order.md#0x0_order_OrderInfo">OrderInfo</a> {
        pool_id,
        order_id,
        client_order_id,
        order_type,
        price,
        original_quantity: quantity,
        executed_quantity: 0,
        cumulative_quote_quantity: 0,
        paid_fees: 0,
        total_fees: 0,
        fee_is_deep,
        is_bid,
        owner,
        status: <a href="order.md#0x0_order_LIVE">LIVE</a>,
        expire_timestamp,
        self_matching_prevention: <b>false</b>,
    }
}
</code></pre>



</details>

<a name="0x0_order_pool_id"></a>

## Function `pool_id`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_pool_id">pool_id</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_pool_id">pool_id</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): ID {
    self.pool_id
}
</code></pre>



</details>

<a name="0x0_order_order_id"></a>

## Function `order_id`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_order_id">order_id</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): u128
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_order_id">order_id</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): u128 {
    self.order_id
}
</code></pre>



</details>

<a name="0x0_order_client_order_id"></a>

## Function `client_order_id`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_client_order_id">client_order_id</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_client_order_id">client_order_id</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): u64 {
    self.client_order_id
}
</code></pre>



</details>

<a name="0x0_order_owner"></a>

## Function `owner`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_owner">owner</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_owner">owner</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): <b>address</b> {
    self.owner
}
</code></pre>



</details>

<a name="0x0_order_order_type"></a>

## Function `order_type`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_order_type">order_type</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_order_type">order_type</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): u8 {
    self.order_type
}
</code></pre>



</details>

<a name="0x0_order_price"></a>

## Function `price`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_price">price</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_price">price</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): u64 {
    self.price
}
</code></pre>



</details>

<a name="0x0_order_is_bid"></a>

## Function `is_bid`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_is_bid">is_bid</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_is_bid">is_bid</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): bool{
    self.is_bid
}
</code></pre>



</details>

<a name="0x0_order_original_quantity"></a>

## Function `original_quantity`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_original_quantity">original_quantity</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_original_quantity">original_quantity</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): u64 {
    self.original_quantity
}
</code></pre>



</details>

<a name="0x0_order_executed_quantity"></a>

## Function `executed_quantity`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_executed_quantity">executed_quantity</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_executed_quantity">executed_quantity</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): u64 {
    self.executed_quantity
}
</code></pre>



</details>

<a name="0x0_order_cumulative_quote_quantity"></a>

## Function `cumulative_quote_quantity`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_cumulative_quote_quantity">cumulative_quote_quantity</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_cumulative_quote_quantity">cumulative_quote_quantity</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): u64 {
    self.cumulative_quote_quantity
}
</code></pre>



</details>

<a name="0x0_order_paid_fees"></a>

## Function `paid_fees`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_paid_fees">paid_fees</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_paid_fees">paid_fees</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): u64 {
    self.paid_fees
}
</code></pre>



</details>

<a name="0x0_order_total_fees"></a>

## Function `total_fees`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_total_fees">total_fees</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_total_fees">total_fees</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): u64 {
    self.total_fees
}
</code></pre>



</details>

<a name="0x0_order_fee_is_deep"></a>

## Function `fee_is_deep`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_fee_is_deep">fee_is_deep</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_fee_is_deep">fee_is_deep</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): bool {
    self.fee_is_deep
}
</code></pre>



</details>

<a name="0x0_order_status"></a>

## Function `status`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_status">status</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_status">status</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): u8 {
    self.status
}
</code></pre>



</details>

<a name="0x0_order_expire_timestamp"></a>

## Function `expire_timestamp`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_expire_timestamp">expire_timestamp</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_expire_timestamp">expire_timestamp</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): u64 {
    self.expire_timestamp
}
</code></pre>



</details>

<a name="0x0_order_self_matching_prevention"></a>

## Function `self_matching_prevention`



<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_self_matching_prevention">self_matching_prevention</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="order.md#0x0_order_self_matching_prevention">self_matching_prevention</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): bool {
    self.self_matching_prevention
}
</code></pre>



</details>

<a name="0x0_order_book_order_id"></a>

## Function `book_order_id`

TODO: Better naming to avoid conflict?


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_book_order_id">book_order_id</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u128
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_book_order_id">book_order_id</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u128 {
    self.order_id
}
</code></pre>



</details>

<a name="0x0_order_book_client_order_id"></a>

## Function `book_client_order_id`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_book_client_order_id">book_client_order_id</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_book_client_order_id">book_client_order_id</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.client_order_id
}
</code></pre>



</details>

<a name="0x0_order_book_quantity"></a>

## Function `book_quantity`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_book_quantity">book_quantity</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_book_quantity">book_quantity</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.quantity
}
</code></pre>



</details>

<a name="0x0_order_book_unpaid_fees"></a>

## Function `book_unpaid_fees`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_book_unpaid_fees">book_unpaid_fees</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_book_unpaid_fees">book_unpaid_fees</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.unpaid_fees
}
</code></pre>



</details>

<a name="0x0_order_book_fee_is_deep"></a>

## Function `book_fee_is_deep`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_book_fee_is_deep">book_fee_is_deep</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_book_fee_is_deep">book_fee_is_deep</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): bool {
    self.fee_is_deep
}
</code></pre>



</details>

<a name="0x0_order_book_status"></a>

## Function `book_status`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_book_status">book_status</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_book_status">book_status</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u8 {
    self.status
}
</code></pre>



</details>

<a name="0x0_order_book_expire_timestamp"></a>

## Function `book_expire_timestamp`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_book_expire_timestamp">book_expire_timestamp</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_book_expire_timestamp">book_expire_timestamp</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.expire_timestamp
}
</code></pre>



</details>

<a name="0x0_order_book_self_matching_prevention"></a>

## Function `book_self_matching_prevention`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_book_self_matching_prevention">book_self_matching_prevention</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_book_self_matching_prevention">book_self_matching_prevention</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): bool {
    self.self_matching_prevention
}
</code></pre>



</details>

<a name="0x0_order_to_order"></a>

## Function `to_order`

OrderInfo is converted to an Order before being injected into the order book.
This is done to save space in the order book. Order contains the minimum
information required to match orders.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_to_order">to_order</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): <a href="order.md#0x0_order_Order">order::Order</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_to_order">to_order</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): <a href="order.md#0x0_order_Order">Order</a> {
    <a href="order.md#0x0_order_Order">Order</a> {
        order_id: self.order_id,
        client_order_id: self.client_order_id,
        owner: self.owner,
        quantity: self.original_quantity,
        unpaid_fees: self.total_fees - self.paid_fees,
        fee_is_deep: self.fee_is_deep,
        status: self.status,
        expire_timestamp: self.expire_timestamp,
        self_matching_prevention: self.self_matching_prevention,
    }
}
</code></pre>



</details>

<a name="0x0_order_validate_inputs"></a>

## Function `validate_inputs`

Validates that the initial order created meets the pool requirements.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_validate_inputs">validate_inputs</a>(order_info: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>, tick_size: u64, min_size: u64, lot_size: u64, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_validate_inputs">validate_inputs</a>(
    order_info: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>,
    tick_size: u64,
    min_size: u64,
    lot_size: u64,
    timestamp: u64,
) {
    <b>assert</b>!(order_info.price &gt;= <a href="order.md#0x0_order_MIN_PRICE">MIN_PRICE</a> && order_info.<a href="order.md#0x0_order_price">price</a> &lt;= <a href="order.md#0x0_order_MAX_PRICE">MAX_PRICE</a>, <a href="order.md#0x0_order_EOrderInvalidPrice">EOrderInvalidPrice</a>);
    <b>assert</b>!(order_info.price % tick_size == 0, <a href="order.md#0x0_order_EOrderInvalidPrice">EOrderInvalidPrice</a>);
    <b>assert</b>!(order_info.original_quantity &gt;= min_size, <a href="order.md#0x0_order_EOrderBelowMinimumSize">EOrderBelowMinimumSize</a>);
    <b>assert</b>!(order_info.original_quantity % lot_size == 0, <a href="order.md#0x0_order_EOrderInvalidLotSize">EOrderInvalidLotSize</a>);
    <b>assert</b>!(order_info.expire_timestamp &gt;= timestamp, <a href="order.md#0x0_order_EInvalidExpireTimestamp">EInvalidExpireTimestamp</a>);
    <b>assert</b>!(order_info.order_type &gt;= <a href="order.md#0x0_order_NO_RESTRICTION">NO_RESTRICTION</a> && order_info.<a href="order.md#0x0_order_order_type">order_type</a> &lt;= <a href="order.md#0x0_order_MAX_RESTRICTION">MAX_RESTRICTION</a>, <a href="order.md#0x0_order_EInvalidOrderType">EInvalidOrderType</a>);
}
</code></pre>



</details>

<a name="0x0_order_validate_modification"></a>

## Function `validate_modification`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_validate_modification">validate_modification</a>(<a href="order.md#0x0_order">order</a>: &<a href="order.md#0x0_order_Order">order::Order</a>, book_quantity: u64, new_quantity: u64, min_size: u64, lot_size: u64, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_validate_modification">validate_modification</a>(
    <a href="order.md#0x0_order">order</a>: &<a href="order.md#0x0_order_Order">Order</a>,
    book_quantity: u64,
    new_quantity: u64,
    min_size: u64,
    lot_size: u64,
    timestamp: u64,
) {
    <b>assert</b>!(new_quantity &gt; 0 && new_quantity &lt; book_quantity, <a href="order.md#0x0_order_EInvalidNewQuantity">EInvalidNewQuantity</a>);
    <b>assert</b>!(new_quantity &gt;= min_size, <a href="order.md#0x0_order_EOrderBelowMinimumSize">EOrderBelowMinimumSize</a>);
    <b>assert</b>!(new_quantity % lot_size == 0, <a href="order.md#0x0_order_EOrderInvalidLotSize">EOrderInvalidLotSize</a>);
    <b>assert</b>!(timestamp &lt; <a href="order.md#0x0_order">order</a>.<a href="order.md#0x0_order_book_expire_timestamp">book_expire_timestamp</a>(), <a href="order.md#0x0_order_EOrderExpired">EOrderExpired</a>);
}
</code></pre>



</details>

<a name="0x0_order_crosses_price"></a>

## Function `crosses_price`

Returns true if two opposite orders are overlapping in price.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_crosses_price">crosses_price</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>, <a href="order.md#0x0_order">order</a>: &<a href="order.md#0x0_order_Order">order::Order</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_crosses_price">crosses_price</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>, <a href="order.md#0x0_order">order</a>: &<a href="order.md#0x0_order_Order">Order</a>): bool {
    <b>let</b> (is_bid, price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(<a href="order.md#0x0_order">order</a>.order_id);

    (
        self.original_quantity - self.executed_quantity &gt; 0 &&
        ((self.is_bid && !is_bid && self.price &gt;= price) ||
        (!self.is_bid && is_bid && self.<a href="order.md#0x0_order_price">price</a> &lt;= price))
    )
}
</code></pre>



</details>

<a name="0x0_order_remaining_quantity"></a>

## Function `remaining_quantity`

Returns the remaining quantity for the order.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_remaining_quantity">remaining_quantity</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_remaining_quantity">remaining_quantity</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): u64 {
    self.original_quantity - self.executed_quantity
}
</code></pre>



</details>

<a name="0x0_order_assert_post_only"></a>

## Function `assert_post_only`

Asserts that the order doesn't have any fills.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_assert_post_only">assert_post_only</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_assert_post_only">assert_post_only</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>) {
    <b>if</b> (self.order_type == <a href="order.md#0x0_order_POST_ONLY">POST_ONLY</a>)
        <b>assert</b>!(self.executed_quantity == 0, <a href="order.md#0x0_order_EPOSTOrderCrossesOrderbook">EPOSTOrderCrossesOrderbook</a>);
}
</code></pre>



</details>

<a name="0x0_order_assert_fill_or_kill"></a>

## Function `assert_fill_or_kill`

Asserts that the order is fully filled.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_assert_fill_or_kill">assert_fill_or_kill</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_assert_fill_or_kill">assert_fill_or_kill</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>) {
    <b>if</b> (self.order_type == <a href="order.md#0x0_order_FILL_OR_KILL">FILL_OR_KILL</a>)
        <b>assert</b>!(self.executed_quantity == self.original_quantity, <a href="order.md#0x0_order_EFOKOrderCannotBeFullyFilled">EFOKOrderCannotBeFullyFilled</a>);
}
</code></pre>



</details>

<a name="0x0_order_is_immediate_or_cancel"></a>

## Function `is_immediate_or_cancel`

Checks whether this is an immediate or cancel type of order.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_is_immediate_or_cancel">is_immediate_or_cancel</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_is_immediate_or_cancel">is_immediate_or_cancel</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>): bool {
    self.order_type == <a href="order.md#0x0_order_IMMEDIATE_OR_CANCEL">IMMEDIATE_OR_CANCEL</a>
}
</code></pre>



</details>

<a name="0x0_order_fill_or_kill"></a>

## Function `fill_or_kill`

Returns the fill or kill constant.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_fill_or_kill">fill_or_kill</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_fill_or_kill">fill_or_kill</a>(): u8 {
    <a href="order.md#0x0_order_FILL_OR_KILL">FILL_OR_KILL</a>
}
</code></pre>



</details>

<a name="0x0_order_set_total_fees"></a>

## Function `set_total_fees`

Sets the total fees for the order.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_set_total_fees">set_total_fees</a>(self: &<b>mut</b> <a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>, total_fees: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_set_total_fees">set_total_fees</a>(self: &<b>mut</b> <a href="order.md#0x0_order_OrderInfo">OrderInfo</a>, total_fees: u64) {
    self.total_fees = total_fees;
}
</code></pre>



</details>

<a name="0x0_order_set_canceled"></a>

## Function `set_canceled`

Update the order status to canceled.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_set_canceled">set_canceled</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_set_canceled">set_canceled</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>) {
    self.status = <a href="order.md#0x0_order_CANCELED">CANCELED</a>;
}
</code></pre>



</details>

<a name="0x0_order_set_expired"></a>

## Function `set_expired`

Update the order status to expired.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_set_expired">set_expired</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_set_expired">set_expired</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>) {
    self.status = <a href="order.md#0x0_order_EXPIRED">EXPIRED</a>;
}
</code></pre>



</details>

<a name="0x0_order_fill_status"></a>

## Function `fill_status`

Returns the result of the fill and the maker id & owner.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_fill_status">fill_status</a>(fill: &<a href="order.md#0x0_order_Fill">order::Fill</a>): (u128, <b>address</b>, bool, bool)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_fill_status">fill_status</a>(fill: &<a href="order.md#0x0_order_Fill">Fill</a>): (u128, <b>address</b>, bool, bool) {
    (fill.order_id, fill.owner, fill.expired, fill.complete)
}
</code></pre>



</details>

<a name="0x0_order_settled_quantities"></a>

## Function `settled_quantities`

Returns the settled quantities for the fill.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_settled_quantities">settled_quantities</a>(fill: &<a href="order.md#0x0_order_Fill">order::Fill</a>): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_settled_quantities">settled_quantities</a>(fill: &<a href="order.md#0x0_order_Fill">Fill</a>): (u64, u64, u64) {
    (fill.settled_base, fill.settled_quote, fill.settled_deep)
}
</code></pre>



</details>

<a name="0x0_order_match_maker"></a>

## Function `match_maker`

Matches an OrderInfo with an Order from the book. Returns a Fill.
If the book order is expired, it returns a Fill with the expired flag set to true.
Funds for an expired order are returned to the maker as settled.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_match_maker">match_maker</a>(self: &<b>mut</b> <a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>, maker: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, timestamp: u64): <a href="order.md#0x0_order_Fill">order::Fill</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_match_maker">match_maker</a>(
    self: &<b>mut</b> <a href="order.md#0x0_order_OrderInfo">OrderInfo</a>,
    maker: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>,
    timestamp: u64,
): <a href="order.md#0x0_order_Fill">Fill</a> {
    <b>if</b> (maker.<a href="order.md#0x0_order_expire_timestamp">expire_timestamp</a> &lt; timestamp) {
        maker.status = <a href="order.md#0x0_order_EXPIRED">EXPIRED</a>;
        <b>let</b> (base, quote, deep) = maker.<a href="order.md#0x0_order_cancel_amounts">cancel_amounts</a>();
        <b>return</b> <a href="order.md#0x0_order_Fill">Fill</a> {
            order_id: maker.order_id,
            owner: maker.owner,
            expired: <b>true</b>,
            complete: <b>false</b>,
            settled_base: base,
            settled_quote: quote,
            settled_deep: deep,
        }
    };

    <b>let</b> (_, price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(maker.order_id);
    <b>let</b> filled_quantity = <a href="math.md#0x0_math_min">math::min</a>(self.<a href="order.md#0x0_order_remaining_quantity">remaining_quantity</a>(), maker.quantity);
    <b>let</b> quote_quantity = <a href="math.md#0x0_math_mul">math::mul</a>(filled_quantity, price);
    maker.quantity = maker.quantity - filled_quantity;
    self.executed_quantity = self.executed_quantity + filled_quantity;
    self.cumulative_quote_quantity = self.cumulative_quote_quantity + quote_quantity;

    self.status = <a href="order.md#0x0_order_PARTIALLY_FILLED">PARTIALLY_FILLED</a>;
    maker.status = <a href="order.md#0x0_order_PARTIALLY_FILLED">PARTIALLY_FILLED</a>;
    <b>if</b> (self.<a href="order.md#0x0_order_remaining_quantity">remaining_quantity</a>() == 0) self.status = <a href="order.md#0x0_order_FILLED">FILLED</a>;
    <b>if</b> (maker.quantity == 0) maker.status = <a href="order.md#0x0_order_FILLED">FILLED</a>;

    <b>let</b> maker_fees = <a href="math.md#0x0_math_div">math::div</a>(<a href="math.md#0x0_math_mul">math::mul</a>(filled_quantity, maker.unpaid_fees), maker.quantity);
    maker.unpaid_fees = maker.unpaid_fees - maker_fees;

    self.<a href="order.md#0x0_order_emit_order_filled">emit_order_filled</a>(timestamp);

    <a href="order.md#0x0_order_Fill">Fill</a> {
        order_id: maker.order_id,
        owner: maker.owner,
        expired: <b>false</b>,
        complete: maker.quantity == 0,
        settled_base: <b>if</b> (self.is_bid) filled_quantity <b>else</b> 0,
        settled_quote: <b>if</b> (self.is_bid) 0 <b>else</b> quote_quantity,
        settled_deep: 0,
    }
}
</code></pre>



</details>

<a name="0x0_order_cancel_amounts"></a>

## Function `cancel_amounts`

Amounts to settle for a canceled order.
Returns the base, quote and deep quantities to settle.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_cancel_amounts">cancel_amounts</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_cancel_amounts">cancel_amounts</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): (u64, u64, u64) {
    <b>let</b> (is_bid, price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(self.order_id);
    <b>let</b> <b>mut</b> base_quantity = <b>if</b> (is_bid) 0 <b>else</b> self.quantity;
    <b>let</b> <b>mut</b> quote_quantity = <b>if</b> (is_bid) <a href="math.md#0x0_math_mul">math::mul</a>(self.quantity, price) <b>else</b> 0;
    <b>let</b> deep_quantity = <b>if</b> (self.fee_is_deep) {
        self.unpaid_fees
    } <b>else</b> {
        <b>if</b> (is_bid) quote_quantity = quote_quantity + self.unpaid_fees
        <b>else</b> base_quantity = base_quantity + self.unpaid_fees;
        0
    };

    (base_quantity, quote_quantity, deep_quantity)
}
</code></pre>



</details>

<a name="0x0_order_refunds"></a>

## Function `refunds`

Amounts to settle for a modified order. Modifies the order in place.
Returns the base, quote and deep quantities to settle.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_refunds">refunds</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, quantity_cancelled: u64): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_refunds">refunds</a>(
    self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>,
    quantity_cancelled: u64,
): (u64, u64, u64) {
    <b>let</b> (is_bid, price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(self.order_id);
    <b>let</b> <b>mut</b> base_quantity = <b>if</b> (is_bid) 0 <b>else</b> quantity_cancelled;
    <b>let</b> <b>mut</b> quote_quantity = <b>if</b> (is_bid) <a href="math.md#0x0_math_mul">math::mul</a>(quantity_cancelled, price) <b>else</b> 0;
    <b>let</b> fee_refund = <a href="math.md#0x0_math_div">math::div</a>(<a href="math.md#0x0_math_mul">math::mul</a>(self.unpaid_fees, quantity_cancelled), self.quantity);
    <b>let</b> deep_quantity = <b>if</b> (self.fee_is_deep) {
        fee_refund
    } <b>else</b> {
        <b>if</b> (is_bid) quote_quantity = quote_quantity + fee_refund
        <b>else</b> base_quantity = base_quantity + fee_refund;
        0
    };

    self.quantity = self.quantity - quantity_cancelled;
    self.unpaid_fees = self.unpaid_fees - fee_refund;

    (base_quantity, quote_quantity, deep_quantity)
}
</code></pre>



</details>

<a name="0x0_order_emit_order_filled"></a>

## Function `emit_order_filled`



<pre><code><b>fun</b> <a href="order.md#0x0_order_emit_order_filled">emit_order_filled</a>(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="order.md#0x0_order_emit_order_filled">emit_order_filled</a>(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>, timestamp: u64) {
    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="order.md#0x0_order_OrderFilled">OrderFilled</a> {
        pool_id: self.pool_id,
        maker_order_id: self.order_id,
        taker_order_id: self.order_id,
        maker_client_order_id: self.client_order_id,
        taker_client_order_id: self.client_order_id,
        base_quantity: self.original_quantity,
        quote_quantity: self.original_quantity * self.price,
        price: self.price,
        maker_address: self.owner,
        taker_address: self.owner,
        is_bid: self.is_bid,
        timestamp,
    });
}
</code></pre>



</details>

<a name="0x0_order_emit_order_placed"></a>

## Function `emit_order_placed`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_emit_order_placed">emit_order_placed</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_emit_order_placed">emit_order_placed</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_OrderInfo">OrderInfo</a>) {
    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="order.md#0x0_order_OrderPlaced">OrderPlaced</a>&lt;BaseAsset, QuoteAsset&gt; {
        pool_id: self.pool_id,
        order_id: self.order_id,
        client_order_id: self.client_order_id,
        is_bid: self.is_bid,
        owner: self.owner,
        original_quantity: self.original_quantity,
        executed_quantity: self.executed_quantity,
        price: self.price,
        expire_timestamp: self.expire_timestamp,
    });
}
</code></pre>



</details>

<a name="0x0_order_emit_order_canceled"></a>

## Function `emit_order_canceled`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_emit_order_canceled">emit_order_canceled</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_Order">order::Order</a>, pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_emit_order_canceled">emit_order_canceled</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_Order">Order</a>, pool_id: ID, timestamp: u64) {
    <b>let</b> (is_bid, price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(self.order_id);
    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="order.md#0x0_order_OrderCanceled">OrderCanceled</a>&lt;BaseAsset, QuoteAsset&gt; {
        pool_id,
        order_id: self.order_id,
        client_order_id: self.client_order_id,
        is_bid,
        owner: self.owner,
        base_asset_quantity_canceled: self.quantity,
        timestamp,
        price,
    });
}
</code></pre>



</details>

<a name="0x0_order_emit_order_modified"></a>

## Function `emit_order_modified`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_emit_order_modified">emit_order_modified</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_Order">order::Order</a>, pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_emit_order_modified">emit_order_modified</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_Order">Order</a>, pool_id: ID, timestamp: u64) {
    <b>let</b> (is_bid, price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(self.order_id);
    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="order.md#0x0_order_OrderModified">OrderModified</a>&lt;BaseAsset, QuoteAsset&gt; {
        pool_id,
        order_id: self.order_id,
        client_order_id: self.client_order_id,
        owner: self.owner,
        price,
        is_bid,
        new_quantity: self.quantity,
        timestamp,
    });
}
</code></pre>



</details>
