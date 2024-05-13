
<a name="0x0_order"></a>

# Module `0x0::order`

Order module defines the order struct and its methods.
All order matching happens in this module.


-  [Struct `Order`](#0x0_order_Order)
-  [Struct `OrderCanceled`](#0x0_order_OrderCanceled)
-  [Struct `OrderModified`](#0x0_order_OrderModified)
-  [Constants](#@Constants_0)
-  [Function `init_order`](#0x0_order_init_order)
-  [Function `order_id`](#0x0_order_order_id)
-  [Function `client_order_id`](#0x0_order_client_order_id)
-  [Function `owner`](#0x0_order_owner)
-  [Function `quantity`](#0x0_order_quantity)
-  [Function `unpaid_fees`](#0x0_order_unpaid_fees)
-  [Function `fee_is_deep`](#0x0_order_fee_is_deep)
-  [Function `status`](#0x0_order_status)
-  [Function `expire_timestamp`](#0x0_order_expire_timestamp)
-  [Function `self_matching_prevention`](#0x0_order_self_matching_prevention)
-  [Function `set_quantity`](#0x0_order_set_quantity)
-  [Function `set_unpaid_fees`](#0x0_order_set_unpaid_fees)
-  [Function `set_live`](#0x0_order_set_live)
-  [Function `set_partially_filled`](#0x0_order_set_partially_filled)
-  [Function `set_filled`](#0x0_order_set_filled)
-  [Function `set_canceled`](#0x0_order_set_canceled)
-  [Function `set_expired`](#0x0_order_set_expired)
-  [Function `validate_modification`](#0x0_order_validate_modification)
-  [Function `cancel_amounts`](#0x0_order_cancel_amounts)
-  [Function `emit_order_canceled`](#0x0_order_emit_order_canceled)
-  [Function `emit_order_modified`](#0x0_order_emit_order_modified)


<pre><code><b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="utils.md#0x0_utils">0x0::utils</a>;
<b>use</b> <a href="dependencies/sui-framework/event.md#0x2_event">0x2::event</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
</code></pre>



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

<a name="@Constants_0"></a>

## Constants


<a name="0x0_order_CANCELED"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_CANCELED">CANCELED</a>: u8 = 3;
</code></pre>



<a name="0x0_order_EInvalidNewQuantity"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EInvalidNewQuantity">EInvalidNewQuantity</a>: u64 = 0;
</code></pre>



<a name="0x0_order_EOrderBelowMinimumSize"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EOrderBelowMinimumSize">EOrderBelowMinimumSize</a>: u64 = 1;
</code></pre>



<a name="0x0_order_EOrderExpired"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EOrderExpired">EOrderExpired</a>: u64 = 3;
</code></pre>



<a name="0x0_order_EOrderInvalidLotSize"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EOrderInvalidLotSize">EOrderInvalidLotSize</a>: u64 = 2;
</code></pre>



<a name="0x0_order_EXPIRED"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EXPIRED">EXPIRED</a>: u8 = 4;
</code></pre>



<a name="0x0_order_FILLED"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_FILLED">FILLED</a>: u8 = 2;
</code></pre>



<a name="0x0_order_LIVE"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_LIVE">LIVE</a>: u8 = 0;
</code></pre>



<a name="0x0_order_PARTIALLY_FILLED"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_PARTIALLY_FILLED">PARTIALLY_FILLED</a>: u8 = 1;
</code></pre>



<a name="0x0_order_init_order"></a>

## Function `init_order`

initialize the order struct.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_init_order">init_order</a>(order_id: u128, client_order_id: u64, owner: <b>address</b>, quantity: u64, unpaid_fees: u64, fee_is_deep: bool, status: u8, expire_timestamp: u64, self_matching_prevention: bool): <a href="order.md#0x0_order_Order">order::Order</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_init_order">init_order</a>(
    order_id: u128,
    client_order_id: u64,
    owner: <b>address</b>,
    quantity: u64,
    unpaid_fees: u64,
    fee_is_deep: bool,
    status: u8,
    expire_timestamp: u64,
    self_matching_prevention: bool,
): <a href="order.md#0x0_order_Order">Order</a> {
    <a href="order.md#0x0_order_Order">Order</a> {
        order_id,
        client_order_id,
        owner,
        quantity,
        unpaid_fees,
        fee_is_deep,
        status,
        expire_timestamp,
        self_matching_prevention,
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


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_order_id">order_id</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u128 {
    self.order_id
}
</code></pre>



</details>

<a name="0x0_order_client_order_id"></a>

## Function `client_order_id`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_client_order_id">client_order_id</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_client_order_id">client_order_id</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.client_order_id
}
</code></pre>



</details>

<a name="0x0_order_owner"></a>

## Function `owner`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_owner">owner</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_owner">owner</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): <b>address</b> {
    self.owner
}
</code></pre>



</details>

<a name="0x0_order_quantity"></a>

## Function `quantity`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_quantity">quantity</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_quantity">quantity</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.quantity
}
</code></pre>



</details>

<a name="0x0_order_unpaid_fees"></a>

## Function `unpaid_fees`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_unpaid_fees">unpaid_fees</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_unpaid_fees">unpaid_fees</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.unpaid_fees
}
</code></pre>



</details>

<a name="0x0_order_fee_is_deep"></a>

## Function `fee_is_deep`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_fee_is_deep">fee_is_deep</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_fee_is_deep">fee_is_deep</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): bool {
    self.fee_is_deep
}
</code></pre>



</details>

<a name="0x0_order_status"></a>

## Function `status`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_status">status</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_status">status</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u8 {
    self.status
}
</code></pre>



</details>

<a name="0x0_order_expire_timestamp"></a>

## Function `expire_timestamp`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_expire_timestamp">expire_timestamp</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_expire_timestamp">expire_timestamp</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.expire_timestamp
}
</code></pre>



</details>

<a name="0x0_order_self_matching_prevention"></a>

## Function `self_matching_prevention`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_self_matching_prevention">self_matching_prevention</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_self_matching_prevention">self_matching_prevention</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): bool {
    self.self_matching_prevention
}
</code></pre>



</details>

<a name="0x0_order_set_quantity"></a>

## Function `set_quantity`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_set_quantity">set_quantity</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, quantity: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_set_quantity">set_quantity</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>, quantity: u64) {
    self.quantity = quantity;
}
</code></pre>



</details>

<a name="0x0_order_set_unpaid_fees"></a>

## Function `set_unpaid_fees`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_set_unpaid_fees">set_unpaid_fees</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, unpaid_fees: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_set_unpaid_fees">set_unpaid_fees</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>, unpaid_fees: u64) {
    self.unpaid_fees = unpaid_fees;
}
</code></pre>



</details>

<a name="0x0_order_set_live"></a>

## Function `set_live`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_set_live">set_live</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_set_live">set_live</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>) {
    self.status = <a href="order.md#0x0_order_LIVE">LIVE</a>;
}
</code></pre>



</details>

<a name="0x0_order_set_partially_filled"></a>

## Function `set_partially_filled`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_set_partially_filled">set_partially_filled</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_set_partially_filled">set_partially_filled</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>) {
    self.status = <a href="order.md#0x0_order_PARTIALLY_FILLED">PARTIALLY_FILLED</a>;
}
</code></pre>



</details>

<a name="0x0_order_set_filled"></a>

## Function `set_filled`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_set_filled">set_filled</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_set_filled">set_filled</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>) {
    self.status = <a href="order.md#0x0_order_FILLED">FILLED</a>;
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


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_set_canceled">set_canceled</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>) {
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


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_set_expired">set_expired</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>) {
    self.status = <a href="order.md#0x0_order_EXPIRED">EXPIRED</a>;
}
</code></pre>



</details>

<a name="0x0_order_validate_modification"></a>

## Function `validate_modification`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_validate_modification">validate_modification</a>(<a href="order.md#0x0_order">order</a>: &<a href="order.md#0x0_order_Order">order::Order</a>, quantity: u64, new_quantity: u64, min_size: u64, lot_size: u64, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_validate_modification">validate_modification</a>(
    <a href="order.md#0x0_order">order</a>: &<a href="order.md#0x0_order_Order">Order</a>,
    quantity: u64,
    new_quantity: u64,
    min_size: u64,
    lot_size: u64,
    timestamp: u64,
) {
    <b>assert</b>!(new_quantity &gt; 0 && new_quantity &lt; quantity, <a href="order.md#0x0_order_EInvalidNewQuantity">EInvalidNewQuantity</a>);
    <b>assert</b>!(new_quantity &gt;= min_size, <a href="order.md#0x0_order_EOrderBelowMinimumSize">EOrderBelowMinimumSize</a>);
    <b>assert</b>!(new_quantity % lot_size == 0, <a href="order.md#0x0_order_EOrderInvalidLotSize">EOrderInvalidLotSize</a>);
    <b>assert</b>!(timestamp &lt; <a href="order.md#0x0_order">order</a>.<a href="order.md#0x0_order_expire_timestamp">expire_timestamp</a>(), <a href="order.md#0x0_order_EOrderExpired">EOrderExpired</a>);
}
</code></pre>



</details>

<a name="0x0_order_cancel_amounts"></a>

## Function `cancel_amounts`

Amounts to settle for a cancelled or modified order. Modifies the order in place.
Returns the base, quote and deep quantities to settle.
Cancel quantity used to calculate the quantity outputs.
Modify_order is a flag to indicate whether the order should be modified.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_cancel_amounts">cancel_amounts</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, cancel_quantity: u64, modify_order: bool): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_cancel_amounts">cancel_amounts</a>(
    self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>,
    cancel_quantity: u64,
    modify_order: bool,
): (u64, u64, u64) {
    <b>let</b> (is_bid, price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(self.order_id);
    <b>let</b> <b>mut</b> base_quantity = <b>if</b> (is_bid) 0 <b>else</b> cancel_quantity;
    <b>let</b> <b>mut</b> quote_quantity = <b>if</b> (is_bid) <a href="math.md#0x0_math_mul">math::mul</a>(cancel_quantity, price) <b>else</b> 0;
    <b>let</b> fee_refund = <a href="math.md#0x0_math_div">math::div</a>(<a href="math.md#0x0_math_mul">math::mul</a>(self.unpaid_fees, cancel_quantity), self.quantity);
    <b>let</b> deep_quantity = <b>if</b> (self.fee_is_deep) {
        fee_refund
    } <b>else</b> {
        <b>if</b> (is_bid) quote_quantity = quote_quantity + fee_refund
        <b>else</b> base_quantity = base_quantity + fee_refund;
        0
    };

    <b>if</b> (modify_order) {
        self.quantity = self.quantity - cancel_quantity;
        self.unpaid_fees = self.unpaid_fees - fee_refund;
    };

    (base_quantity, quote_quantity, deep_quantity)
}
</code></pre>



</details>

<a name="0x0_order_emit_order_canceled"></a>

## Function `emit_order_canceled`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_emit_order_canceled">emit_order_canceled</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_Order">order::Order</a>, pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_emit_order_canceled">emit_order_canceled</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_Order">Order</a>, pool_id: ID, timestamp: u64) {
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


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_emit_order_modified">emit_order_modified</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_Order">Order</a>, pool_id: ID, timestamp: u64) {
    <b>let</b> (is_bid, price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(self.order_id);
    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="order.md#0x0_order_OrderModified">OrderModified</a>&lt;BaseAsset, QuoteAsset&gt; {
        order_id: self.order_id,
        pool_id,
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
