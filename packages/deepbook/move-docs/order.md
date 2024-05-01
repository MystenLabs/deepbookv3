
<a name="0x0_order"></a>

# Module `0x0::order`

Order module defines the order struct and its methods.
All order matching happens in this module.


-  [Struct `Order`](#0x0_order_Order)
-  [Struct `OrderFilled`](#0x0_order_OrderFilled)
-  [Struct `OrderCanceled`](#0x0_order_OrderCanceled)
-  [Struct `OrderPlaced`](#0x0_order_OrderPlaced)
-  [Constants](#@Constants_0)
-  [Function `initial_order`](#0x0_order_initial_order)
-  [Function `copy_order`](#0x0_order_copy_order)
-  [Function `order_id`](#0x0_order_order_id)
-  [Function `owner`](#0x0_order_owner)
-  [Function `order_type`](#0x0_order_order_type)
-  [Function `price`](#0x0_order_price)
-  [Function `is_bid`](#0x0_order_is_bid)
-  [Function `original_quantity`](#0x0_order_original_quantity)
-  [Function `executed_quantity`](#0x0_order_executed_quantity)
-  [Function `cumulative_quote_quantity`](#0x0_order_cumulative_quote_quantity)
-  [Function `fee_is_deep`](#0x0_order_fee_is_deep)
-  [Function `is_expired`](#0x0_order_is_expired)
-  [Function `is_complete`](#0x0_order_is_complete)
-  [Function `can_match`](#0x0_order_can_match)
-  [Function `remaining_quantity`](#0x0_order_remaining_quantity)
-  [Function `fees_to_refund`](#0x0_order_fees_to_refund)
-  [Function `assert_post_only`](#0x0_order_assert_post_only)
-  [Function `assert_fill_or_kill`](#0x0_order_assert_fill_or_kill)
-  [Function `is_immediate_or_cancel`](#0x0_order_is_immediate_or_cancel)
-  [Function `fill_or_kill`](#0x0_order_fill_or_kill)
-  [Function `set_total_fees`](#0x0_order_set_total_fees)
-  [Function `set_canceled`](#0x0_order_set_canceled)
-  [Function `set_expired`](#0x0_order_set_expired)
-  [Function `validate_inputs`](#0x0_order_validate_inputs)
-  [Function `match_orders`](#0x0_order_match_orders)
-  [Function `add_fill`](#0x0_order_add_fill)
-  [Function `emit_order_filled`](#0x0_order_emit_order_filled)
-  [Function `emit_order_placed`](#0x0_order_emit_order_placed)
-  [Function `emit_order_canceled`](#0x0_order_emit_order_canceled)


<pre><code><b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="dependencies/sui-framework/event.md#0x2_event">0x2::event</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
</code></pre>



<a name="0x0_order_Order"></a>

## Struct `Order`

For each pool, order id is incremental and unique for each opening order.
Orders that are submitted earlier has lower order ids.


<pre><code><b>struct</b> <a href="order.md#0x0_order_Order">Order</a> <b>has</b> drop, store
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
<code>self_matching_prevention: u8</code>
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



<a name="0x0_order_EInvalidOrderType"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EInvalidOrderType">EInvalidOrderType</a>: u64 = 4;
</code></pre>



<a name="0x0_order_EOrderBelowMinimumSize"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EOrderBelowMinimumSize">EOrderBelowMinimumSize</a>: u64 = 1;
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



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_initial_order">initial_order</a>(pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, order_id: u128, client_order_id: u64, order_type: u8, price: u64, quantity: u64, fee_is_deep: bool, is_bid: bool, owner: <b>address</b>, expire_timestamp: u64): <a href="order.md#0x0_order_Order">order::Order</a>
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
): <a href="order.md#0x0_order_Order">Order</a> {
    <a href="order.md#0x0_order_Order">Order</a> {
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
        self_matching_prevention: 0, // TODO
    }
}
</code></pre>



</details>

<a name="0x0_order_copy_order"></a>

## Function `copy_order`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_copy_order">copy_order</a>(<a href="order.md#0x0_order">order</a>: &<a href="order.md#0x0_order_Order">order::Order</a>): <a href="order.md#0x0_order_Order">order::Order</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_copy_order">copy_order</a>(<a href="order.md#0x0_order">order</a>: &<a href="order.md#0x0_order_Order">Order</a>): <a href="order.md#0x0_order_Order">Order</a> {
    <a href="order.md#0x0_order_Order">Order</a> {
        pool_id: <a href="order.md#0x0_order">order</a>.pool_id,
        order_id: <a href="order.md#0x0_order">order</a>.order_id,
        client_order_id: <a href="order.md#0x0_order">order</a>.client_order_id,
        order_type: <a href="order.md#0x0_order">order</a>.order_type,
        price: <a href="order.md#0x0_order">order</a>.price,
        original_quantity: <a href="order.md#0x0_order">order</a>.original_quantity,
        executed_quantity: <a href="order.md#0x0_order">order</a>.executed_quantity,
        cumulative_quote_quantity: <a href="order.md#0x0_order">order</a>.cumulative_quote_quantity,
        paid_fees: <a href="order.md#0x0_order">order</a>.paid_fees,
        total_fees: <a href="order.md#0x0_order">order</a>.total_fees,
        fee_is_deep: <a href="order.md#0x0_order">order</a>.fee_is_deep,
        is_bid: <a href="order.md#0x0_order">order</a>.is_bid,
        owner: <a href="order.md#0x0_order">order</a>.owner,
        status: <a href="order.md#0x0_order">order</a>.status,
        expire_timestamp: <a href="order.md#0x0_order">order</a>.expire_timestamp,
        self_matching_prevention: <a href="order.md#0x0_order">order</a>.self_matching_prevention,
    }
}
</code></pre>



</details>

<a name="0x0_order_order_id"></a>

## Function `order_id`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_order_id">order_id</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u128
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_order_id">order_id</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u128 {
    self.order_id
}
</code></pre>



</details>

<a name="0x0_order_owner"></a>

## Function `owner`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_owner">owner</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_owner">owner</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): <b>address</b> {
    self.owner
}
</code></pre>



</details>

<a name="0x0_order_order_type"></a>

## Function `order_type`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_order_type">order_type</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_order_type">order_type</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u8 {
    self.order_type
}
</code></pre>



</details>

<a name="0x0_order_price"></a>

## Function `price`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_price">price</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_price">price</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.price
}
</code></pre>



</details>

<a name="0x0_order_is_bid"></a>

## Function `is_bid`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_is_bid">is_bid</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_is_bid">is_bid</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): bool{
    self.is_bid
}
</code></pre>



</details>

<a name="0x0_order_original_quantity"></a>

## Function `original_quantity`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_original_quantity">original_quantity</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_original_quantity">original_quantity</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.original_quantity
}
</code></pre>



</details>

<a name="0x0_order_executed_quantity"></a>

## Function `executed_quantity`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_executed_quantity">executed_quantity</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_executed_quantity">executed_quantity</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.executed_quantity
}
</code></pre>



</details>

<a name="0x0_order_cumulative_quote_quantity"></a>

## Function `cumulative_quote_quantity`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_cumulative_quote_quantity">cumulative_quote_quantity</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_cumulative_quote_quantity">cumulative_quote_quantity</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.cumulative_quote_quantity
}
</code></pre>



</details>

<a name="0x0_order_fee_is_deep"></a>

## Function `fee_is_deep`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_fee_is_deep">fee_is_deep</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_fee_is_deep">fee_is_deep</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): bool {
    self.fee_is_deep
}
</code></pre>



</details>

<a name="0x0_order_is_expired"></a>

## Function `is_expired`

Returns true if the order is expired.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_is_expired">is_expired</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>, timestamp: u64): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_is_expired">is_expired</a>(self: &<a href="order.md#0x0_order_Order">Order</a>, timestamp: u64): bool {
    self.expire_timestamp &lt;= timestamp
}
</code></pre>



</details>

<a name="0x0_order_is_complete"></a>

## Function `is_complete`

Returns true if the order is completely filled.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_is_complete">is_complete</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_is_complete">is_complete</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): bool {
    self.original_quantity == self.executed_quantity
}
</code></pre>



</details>

<a name="0x0_order_can_match"></a>

## Function `can_match`

Returns true if two orders are overlapping and can be matched.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_can_match">can_match</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>, other: &<a href="order.md#0x0_order_Order">order::Order</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_can_match">can_match</a>(self: &<a href="order.md#0x0_order_Order">Order</a>, other: &<a href="order.md#0x0_order_Order">Order</a>): bool {
    ((self.is_bid && self.price &gt;= other.price) || (!self.is_bid && self.<a href="order.md#0x0_order_price">price</a> &lt;= other.price))
}
</code></pre>



</details>

<a name="0x0_order_remaining_quantity"></a>

## Function `remaining_quantity`

Returns the remaining quantity for the order.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_remaining_quantity">remaining_quantity</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_remaining_quantity">remaining_quantity</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.original_quantity - self.executed_quantity
}
</code></pre>



</details>

<a name="0x0_order_fees_to_refund"></a>

## Function `fees_to_refund`

Returns the fees to refund for a canceled or expired order.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_fees_to_refund">fees_to_refund</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_fees_to_refund">fees_to_refund</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.paid_fees - self.total_fees
}
</code></pre>



</details>

<a name="0x0_order_assert_post_only"></a>

## Function `assert_post_only`

Asserts that the order doesn't have any fills.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_assert_post_only">assert_post_only</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_assert_post_only">assert_post_only</a>(self: &<a href="order.md#0x0_order_Order">Order</a>) {
    <b>if</b> (self.order_type == <a href="order.md#0x0_order_POST_ONLY">POST_ONLY</a>)
        <b>assert</b>!(self.executed_quantity == 0, <a href="order.md#0x0_order_EPOSTOrderCrossesOrderbook">EPOSTOrderCrossesOrderbook</a>);
}
</code></pre>



</details>

<a name="0x0_order_assert_fill_or_kill"></a>

## Function `assert_fill_or_kill`

Asserts that the order is fully filled.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_assert_fill_or_kill">assert_fill_or_kill</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_assert_fill_or_kill">assert_fill_or_kill</a>(self: &<a href="order.md#0x0_order_Order">Order</a>) {
    <b>if</b> (self.order_type == <a href="order.md#0x0_order_FILL_OR_KILL">FILL_OR_KILL</a>)
        <b>assert</b>!(self.executed_quantity == self.original_quantity, <a href="order.md#0x0_order_EFOKOrderCannotBeFullyFilled">EFOKOrderCannotBeFullyFilled</a>);
}
</code></pre>



</details>

<a name="0x0_order_is_immediate_or_cancel"></a>

## Function `is_immediate_or_cancel`

Checks whether this is an immediate or cancel type of order.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_is_immediate_or_cancel">is_immediate_or_cancel</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_is_immediate_or_cancel">is_immediate_or_cancel</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): bool {
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


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_set_total_fees">set_total_fees</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, total_fees: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_set_total_fees">set_total_fees</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>, total_fees: u64) {
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

<a name="0x0_order_validate_inputs"></a>

## Function `validate_inputs`

Validates that the initial order created meets the pool requirements.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_validate_inputs">validate_inputs</a>(<a href="order.md#0x0_order">order</a>: &<a href="order.md#0x0_order_Order">order::Order</a>, tick_size: u64, min_size: u64, lot_size: u64, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_validate_inputs">validate_inputs</a>(
    <a href="order.md#0x0_order">order</a>: &<a href="order.md#0x0_order_Order">Order</a>,
    tick_size: u64,
    min_size: u64,
    lot_size: u64,
    timestamp: u64,
) {
    <b>assert</b>!(<a href="order.md#0x0_order">order</a>.price &gt;= <a href="order.md#0x0_order_MIN_PRICE">MIN_PRICE</a> && <a href="order.md#0x0_order">order</a>.<a href="order.md#0x0_order_price">price</a> &lt;= <a href="order.md#0x0_order_MAX_PRICE">MAX_PRICE</a>, <a href="order.md#0x0_order_EOrderInvalidPrice">EOrderInvalidPrice</a>);
    <b>assert</b>!(<a href="order.md#0x0_order">order</a>.price % tick_size == 0, <a href="order.md#0x0_order_EOrderInvalidPrice">EOrderInvalidPrice</a>);
    <b>assert</b>!(<a href="order.md#0x0_order">order</a>.original_quantity &gt;= min_size, <a href="order.md#0x0_order_EOrderBelowMinimumSize">EOrderBelowMinimumSize</a>);
    <b>assert</b>!(<a href="order.md#0x0_order">order</a>.original_quantity % lot_size == 0, <a href="order.md#0x0_order_EOrderInvalidLotSize">EOrderInvalidLotSize</a>);
    <b>assert</b>!(<a href="order.md#0x0_order">order</a>.expire_timestamp &gt;= timestamp, <a href="order.md#0x0_order_EInvalidExpireTimestamp">EInvalidExpireTimestamp</a>);
    <b>assert</b>!(<a href="order.md#0x0_order">order</a>.order_type &gt;= <a href="order.md#0x0_order_NO_RESTRICTION">NO_RESTRICTION</a> && <a href="order.md#0x0_order">order</a>.<a href="order.md#0x0_order_order_type">order_type</a> &lt; <a href="order.md#0x0_order_MAX_RESTRICTION">MAX_RESTRICTION</a>, <a href="order.md#0x0_order_EInvalidOrderType">EInvalidOrderType</a>);
}
</code></pre>



</details>

<a name="0x0_order_match_orders"></a>

## Function `match_orders`

Matches two orders and returns the filled quantity and quote quantity.
Updates the orders to reflect their state after the match.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_match_orders">match_orders</a>(taker: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, maker: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, timestamp: u64): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_match_orders">match_orders</a>(
    taker: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>,
    maker: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>,
    timestamp: u64,
): (u64, u64) {
    <b>let</b> filled_quantity = <a href="dependencies/sui-framework/math.md#0x2_math_min">math::min</a>(taker.<a href="order.md#0x0_order_remaining_quantity">remaining_quantity</a>(), maker.<a href="order.md#0x0_order_remaining_quantity">remaining_quantity</a>());
    <b>let</b> quote_quantity = math::mul(filled_quantity, maker.price);
    taker.<a href="order.md#0x0_order_add_fill">add_fill</a>(filled_quantity, quote_quantity);
    maker.<a href="order.md#0x0_order_add_fill">add_fill</a>(filled_quantity, quote_quantity);

    <b>let</b> maker_fees = math::div(math::mul(filled_quantity, maker.total_fees), maker.original_quantity);
    maker.paid_fees = maker.paid_fees + maker_fees;

    taker.<a href="order.md#0x0_order_emit_order_filled">emit_order_filled</a>(timestamp);

    (filled_quantity, quote_quantity,)
}
</code></pre>



</details>

<a name="0x0_order_add_fill"></a>

## Function `add_fill`

Increase the executed quantity and cumulative quote quantity for the order.
Update the order status based on the executed quantity.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_add_fill">add_fill</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, fill_quantity: u64, quote_quantity: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_add_fill">add_fill</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>, fill_quantity: u64, quote_quantity: u64) {
    self.executed_quantity = self.executed_quantity + fill_quantity;
    self.cumulative_quote_quantity = self.cumulative_quote_quantity + quote_quantity;

    <b>if</b> (self.executed_quantity == self.original_quantity) {
        self.status = <a href="order.md#0x0_order_FILLED">FILLED</a>;
    } <b>else</b> <b>if</b> (self.executed_quantity &gt; 0) {
        self.status = <a href="order.md#0x0_order_PARTIALLY_FILLED">PARTIALLY_FILLED</a>;
    }
}
</code></pre>



</details>

<a name="0x0_order_emit_order_filled"></a>

## Function `emit_order_filled`



<pre><code><b>fun</b> <a href="order.md#0x0_order_emit_order_filled">emit_order_filled</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="order.md#0x0_order_emit_order_filled">emit_order_filled</a>(self: &<a href="order.md#0x0_order_Order">Order</a>, timestamp: u64) {
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



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_emit_order_placed">emit_order_placed</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_Order">order::Order</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_emit_order_placed">emit_order_placed</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_Order">Order</a>) {
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



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_emit_order_canceled">emit_order_canceled</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_Order">order::Order</a>, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="order.md#0x0_order_emit_order_canceled">emit_order_canceled</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_Order">Order</a>, timestamp: u64) {
    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="order.md#0x0_order_OrderCanceled">OrderCanceled</a>&lt;BaseAsset, QuoteAsset&gt; {
        pool_id: self.pool_id,
        order_id: self.order_id,
        client_order_id: self.client_order_id,
        is_bid: self.is_bid,
        owner: self.owner,
        original_quantity: self.original_quantity,
        base_asset_quantity_canceled: self.executed_quantity,
        timestamp,
        price: self.price
    });
}
</code></pre>



</details>
