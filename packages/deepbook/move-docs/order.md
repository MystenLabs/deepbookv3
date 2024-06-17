
<a name="0x0_order"></a>

# Module `0x0::order`

Order module defines the order struct and its methods.
All order matching happens in this module.


-  [Struct `Order`](#0x0_order_Order)
-  [Struct `OrderCanceled`](#0x0_order_OrderCanceled)
-  [Struct `OrderModified`](#0x0_order_OrderModified)
-  [Constants](#@Constants_0)
-  [Function `new`](#0x0_order_new)
-  [Function `generate_fill`](#0x0_order_generate_fill)
-  [Function `modify`](#0x0_order_modify)
-  [Function `calculate_cancel_refund`](#0x0_order_calculate_cancel_refund)
-  [Function `emit_order_canceled`](#0x0_order_emit_order_canceled)
-  [Function `emit_order_modified`](#0x0_order_emit_order_modified)
-  [Function `set_canceled`](#0x0_order_set_canceled)
-  [Function `order_id`](#0x0_order_order_id)
-  [Function `client_order_id`](#0x0_order_client_order_id)
-  [Function `balance_manager_id`](#0x0_order_balance_manager_id)
-  [Function `price`](#0x0_order_price)
-  [Function `is_bid`](#0x0_order_is_bid)
-  [Function `quantity`](#0x0_order_quantity)
-  [Function `filled_quantity`](#0x0_order_filled_quantity)
-  [Function `order_deep_price`](#0x0_order_order_deep_price)
-  [Function `epoch`](#0x0_order_epoch)
-  [Function `status`](#0x0_order_status)
-  [Function `expire_timestamp`](#0x0_order_expire_timestamp)


<pre><code><b>use</b> <a href="balances.md#0x0_balances">0x0::balances</a>;
<b>use</b> <a href="constants.md#0x0_constants">0x0::constants</a>;
<b>use</b> <a href="deep_price.md#0x0_deep_price">0x0::deep_price</a>;
<b>use</b> <a href="fill.md#0x0_fill">0x0::fill</a>;
<b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="utils.md#0x0_utils">0x0::utils</a>;
<b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
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
<code>balance_manager_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
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
<code>quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>filled_quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>fee_is_deep: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>order_deep_price: <a href="deep_price.md#0x0_deep_price_OrderDeepPrice">deep_price::OrderDeepPrice</a></code>
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
<code>expire_timestamp: u64</code>
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


<a name="0x0_order_EInvalidNewQuantity"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EInvalidNewQuantity">EInvalidNewQuantity</a>: u64 = 0;
</code></pre>



<a name="0x0_order_EOrderExpired"></a>



<pre><code><b>const</b> <a href="order.md#0x0_order_EOrderExpired">EOrderExpired</a>: u64 = 1;
</code></pre>



<a name="0x0_order_new"></a>

## Function `new`

initialize the order struct.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_new">new</a>(order_id: u128, balance_manager_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, client_order_id: u64, quantity: u64, fee_is_deep: bool, order_deep_price: <a href="deep_price.md#0x0_deep_price_OrderDeepPrice">deep_price::OrderDeepPrice</a>, epoch: u64, status: u8, expire_timestamp: u64): <a href="order.md#0x0_order_Order">order::Order</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_new">new</a>(
    order_id: u128,
    balance_manager_id: ID,
    client_order_id: u64,
    quantity: u64,
    fee_is_deep: bool,
    order_deep_price: OrderDeepPrice,
    epoch: u64,
    status: u8,
    expire_timestamp: u64,
): <a href="order.md#0x0_order_Order">Order</a> {
    <a href="order.md#0x0_order_Order">Order</a> {
        order_id,
        balance_manager_id,
        client_order_id,
        quantity,
        filled_quantity: 0,
        fee_is_deep,
        order_deep_price,
        epoch,
        status,
        expire_timestamp,
    }
}
</code></pre>



</details>

<a name="0x0_order_generate_fill"></a>

## Function `generate_fill`

Generate a fill for the resting order given the timestamp,
quantity and whether the order is a bid.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_generate_fill">generate_fill</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, timestamp: u64, quantity: u64, is_bid: bool, expire_maker: bool): <a href="fill.md#0x0_fill_Fill">fill::Fill</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_generate_fill">generate_fill</a>(
    self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>,
    timestamp: u64,
    quantity: u64,
    is_bid: bool,
    expire_maker: bool,
): Fill {
    <b>let</b> base_quantity = <a href="dependencies/sui-framework/math.md#0x2_math_min">math::min</a>(self.quantity, quantity);
    <b>let</b> quote_quantity = math::mul(base_quantity, self.<a href="order.md#0x0_order_price">price</a>());

    <b>let</b> order_id = self.order_id;
    <b>let</b> balance_manager_id = self.balance_manager_id;
    <b>let</b> expired = self.<a href="order.md#0x0_order_expire_timestamp">expire_timestamp</a> &lt; timestamp || expire_maker;

    <b>if</b> (expired) {
        self.status = <a href="constants.md#0x0_constants_expired">constants::expired</a>();
    } <b>else</b> {
        self.filled_quantity = self.filled_quantity + base_quantity;
        self.status = <b>if</b> (self.quantity == self.filled_quantity) <a href="constants.md#0x0_constants_filled">constants::filled</a>() <b>else</b> <a href="constants.md#0x0_constants_partially_filled">constants::partially_filled</a>();
    };

    <a href="fill.md#0x0_fill_new">fill::new</a>(
        order_id,
        balance_manager_id,
        expired,
        self.quantity == self.filled_quantity,
        base_quantity,
        quote_quantity,
        is_bid,
        self.epoch,
        self.order_deep_price
    )
}
</code></pre>



</details>

<a name="0x0_order_modify"></a>

## Function `modify`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_modify">modify</a>(self: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, new_quantity: u64, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_modify">modify</a>(
    self: &<b>mut</b> <a href="order.md#0x0_order_Order">Order</a>,
    new_quantity: u64,
    timestamp: u64,
) {
    <b>assert</b>!(new_quantity &gt; self.filled_quantity &&
            new_quantity &lt; self.quantity, <a href="order.md#0x0_order_EInvalidNewQuantity">EInvalidNewQuantity</a>);
    <b>assert</b>!(timestamp &lt;= self.expire_timestamp, <a href="order.md#0x0_order_EOrderExpired">EOrderExpired</a>);
    self.quantity = new_quantity;
}
</code></pre>



</details>

<a name="0x0_order_calculate_cancel_refund"></a>

## Function `calculate_cancel_refund`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_calculate_cancel_refund">calculate_cancel_refund</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>, maker_fee: u64, cancel_quantity: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;u64&gt;): <a href="balances.md#0x0_balances_Balances">balances::Balances</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_calculate_cancel_refund">calculate_cancel_refund</a>(
    self: &<a href="order.md#0x0_order_Order">Order</a>,
    maker_fee: u64,
    cancel_quantity: Option&lt;u64&gt;,
): Balances {
    <b>let</b> cancel_quantity = <b>if</b> (cancel_quantity.is_some()) {
        *cancel_quantity.borrow()
    } <b>else</b> {
        self.quantity - self.filled_quantity
    };
    <b>let</b> deep_out = math::mul(
        maker_fee,
        math::mul(
            cancel_quantity,
            self.<a href="order.md#0x0_order_order_deep_price">order_deep_price</a>().deep_quantity(
                cancel_quantity,
                math::mul(cancel_quantity, self.<a href="order.md#0x0_order_price">price</a>())
            )
        )
    );

    <b>let</b> <b>mut</b> base_out = 0;
    <b>let</b> <b>mut</b> quote_out = 0;
    <b>if</b> (self.<a href="order.md#0x0_order_is_bid">is_bid</a>()) {
        quote_out = math::mul(cancel_quantity, self.<a href="order.md#0x0_order_price">price</a>());
    } <b>else</b> {
        base_out = cancel_quantity;
    };

    <a href="balances.md#0x0_balances_new">balances::new</a>(base_out, quote_out, deep_out)
}
</code></pre>



</details>

<a name="0x0_order_emit_order_canceled"></a>

## Function `emit_order_canceled`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_emit_order_canceled">emit_order_canceled</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_Order">order::Order</a>, pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, trader: <b>address</b>, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_emit_order_canceled">emit_order_canceled</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="order.md#0x0_order_Order">Order</a>,
    pool_id: ID,
    trader: <b>address</b>,
    timestamp: u64
) {
    <b>let</b> is_bid = self.<a href="order.md#0x0_order_is_bid">is_bid</a>();
    <b>let</b> price = self.<a href="order.md#0x0_order_price">price</a>();
    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="order.md#0x0_order_OrderCanceled">OrderCanceled</a>&lt;BaseAsset, QuoteAsset&gt; {
        pool_id,
        order_id: self.order_id,
        balance_manager_id: self.balance_manager_id,
        client_order_id: self.client_order_id,
        is_bid,
        trader,
        base_asset_quantity_canceled: self.quantity,
        timestamp,
        price,
    });
}
</code></pre>



</details>

<a name="0x0_order_emit_order_modified"></a>

## Function `emit_order_modified`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_emit_order_modified">emit_order_modified</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<a href="order.md#0x0_order_Order">order::Order</a>, pool_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, trader: <b>address</b>, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_emit_order_modified">emit_order_modified</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<a href="order.md#0x0_order_Order">Order</a>,
    pool_id: ID,
    trader: <b>address</b>,
    timestamp: u64
) {
    <b>let</b> is_bid = self.<a href="order.md#0x0_order_is_bid">is_bid</a>();
    <b>let</b> price = self.<a href="order.md#0x0_order_price">price</a>();
    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="order.md#0x0_order_OrderModified">OrderModified</a>&lt;BaseAsset, QuoteAsset&gt; {
        order_id: self.order_id,
        pool_id,
        client_order_id: self.client_order_id,
        balance_manager_id: self.balance_manager_id,
        trader,
        price,
        is_bid,
        new_quantity: self.quantity,
        timestamp,
    });
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
    self.status = <a href="constants.md#0x0_constants_canceled">constants::canceled</a>();
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

<a name="0x0_order_balance_manager_id"></a>

## Function `balance_manager_id`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_balance_manager_id">balance_manager_id</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_balance_manager_id">balance_manager_id</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): ID {
    self.balance_manager_id
}
</code></pre>



</details>

<a name="0x0_order_price"></a>

## Function `price`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_price">price</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_price">price</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    <b>let</b> (_, price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(self.order_id);

    price
}
</code></pre>



</details>

<a name="0x0_order_is_bid"></a>

## Function `is_bid`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_is_bid">is_bid</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_is_bid">is_bid</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): bool {
    <b>let</b> (is_bid, _, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(self.order_id);

    is_bid
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

<a name="0x0_order_filled_quantity"></a>

## Function `filled_quantity`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_filled_quantity">filled_quantity</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_filled_quantity">filled_quantity</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.filled_quantity
}
</code></pre>



</details>

<a name="0x0_order_order_deep_price"></a>

## Function `order_deep_price`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_order_deep_price">order_deep_price</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): <a href="deep_price.md#0x0_deep_price_OrderDeepPrice">deep_price::OrderDeepPrice</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_order_deep_price">order_deep_price</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): OrderDeepPrice {
    self.order_deep_price
}
</code></pre>



</details>

<a name="0x0_order_epoch"></a>

## Function `epoch`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="order.md#0x0_order_epoch">epoch</a>(self: &<a href="order.md#0x0_order_Order">order::Order</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="order.md#0x0_order_epoch">epoch</a>(self: &<a href="order.md#0x0_order_Order">Order</a>): u64 {
    self.epoch
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
