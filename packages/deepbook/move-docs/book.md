
<a name="0x0_book"></a>

# Module `0x0::book`



-  [Struct `Book`](#0x0_book_Book)
-  [Constants](#@Constants_0)
-  [Function `empty`](#0x0_book_empty)
-  [Function `create_order`](#0x0_book_create_order)
-  [Function `get_amount_out`](#0x0_book_get_amount_out)
-  [Function `cancel_order`](#0x0_book_cancel_order)
-  [Function `modify_order`](#0x0_book_modify_order)
-  [Function `lot_size`](#0x0_book_lot_size)
-  [Function `mid_price`](#0x0_book_mid_price)
-  [Function `get_level2_range_and_ticks`](#0x0_book_get_level2_range_and_ticks)
-  [Function `match_against_book`](#0x0_book_match_against_book)
-  [Function `get_order_id`](#0x0_book_get_order_id)
-  [Function `inject_limit_order`](#0x0_book_inject_limit_order)


<pre><code><b>use</b> <a href="big_vector.md#0x0_big_vector">0x0::big_vector</a>;
<b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="order.md#0x0_order">0x0::order</a>;
<b>use</b> <a href="utils.md#0x0_utils">0x0::utils</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
</code></pre>



<a name="0x0_book_Book"></a>

## Struct `Book`



<pre><code><b>struct</b> <a href="book.md#0x0_book_Book">Book</a> <b>has</b> store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
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
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_book_EEmptyOrderbook"></a>



<pre><code><b>const</b> <a href="book.md#0x0_book_EEmptyOrderbook">EEmptyOrderbook</a>: u64 = 2;
</code></pre>



<a name="0x0_book_EInvalidAmountIn"></a>



<pre><code><b>const</b> <a href="book.md#0x0_book_EInvalidAmountIn">EInvalidAmountIn</a>: u64 = 1;
</code></pre>



<a name="0x0_book_EInvalidPriceRange"></a>



<pre><code><b>const</b> <a href="book.md#0x0_book_EInvalidPriceRange">EInvalidPriceRange</a>: u64 = 3;
</code></pre>



<a name="0x0_book_EInvalidTicks"></a>



<pre><code><b>const</b> <a href="book.md#0x0_book_EInvalidTicks">EInvalidTicks</a>: u64 = 4;
</code></pre>



<a name="0x0_book_START_ASK_ORDER_ID"></a>



<pre><code><b>const</b> <a href="book.md#0x0_book_START_ASK_ORDER_ID">START_ASK_ORDER_ID</a>: u64 = 1;
</code></pre>



<a name="0x0_book_START_BID_ORDER_ID"></a>



<pre><code><b>const</b> <a href="book.md#0x0_book_START_BID_ORDER_ID">START_BID_ORDER_ID</a>: u64 = 9223372036854775808;
</code></pre>



<a name="0x0_book_empty"></a>

## Function `empty`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="book.md#0x0_book_empty">empty</a>(tick_size: u64, lot_size: u64, min_size: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="book.md#0x0_book_Book">book::Book</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="book.md#0x0_book_empty">empty</a>(tick_size: u64, lot_size: u64, min_size: u64, ctx: &<b>mut</b> TxContext): <a href="book.md#0x0_book_Book">Book</a> {
    <a href="book.md#0x0_book_Book">Book</a> {
        tick_size,
        lot_size,
        min_size,
        bids: <a href="big_vector.md#0x0_big_vector_empty">big_vector::empty</a>(10000, 1000, ctx),
        asks: <a href="big_vector.md#0x0_big_vector_empty">big_vector::empty</a>(10000, 1000, ctx),
        next_bid_order_id: <a href="book.md#0x0_book_START_BID_ORDER_ID">START_BID_ORDER_ID</a>,
        next_ask_order_id: <a href="book.md#0x0_book_START_ASK_ORDER_ID">START_ASK_ORDER_ID</a>,
    }
}
</code></pre>



</details>

<a name="0x0_book_create_order"></a>

## Function `create_order`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="book.md#0x0_book_create_order">create_order</a>(self: &<b>mut</b> <a href="book.md#0x0_book_Book">book::Book</a>, order_info: &<b>mut</b> <a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="book.md#0x0_book_create_order">create_order</a>(self: &<b>mut</b> <a href="book.md#0x0_book_Book">Book</a>, order_info: &<b>mut</b> OrderInfo, timestamp: u64) {
    order_info.validate_inputs(self.tick_size, self.min_size, self.lot_size, timestamp);
    <b>let</b> order_id = <a href="utils.md#0x0_utils_encode_order_id">utils::encode_order_id</a>(order_info.is_bid(), order_info.price(), self.<a href="book.md#0x0_book_get_order_id">get_order_id</a>(order_info.is_bid()));
    order_info.set_order_id(order_id);
    self.<a href="book.md#0x0_book_match_against_book">match_against_book</a>(order_info, timestamp);
    order_info.assert_post_only();
    order_info.assert_fill_or_kill();
    <b>if</b> (order_info.is_immediate_or_cancel() || order_info.original_quantity() == order_info.executed_quantity()) {
        <b>return</b>
    };

    <b>if</b> (order_info.remaining_quantity() &gt; 0) {
        self.<a href="book.md#0x0_book_inject_limit_order">inject_limit_order</a>(order_info);
    };
}
</code></pre>



</details>

<a name="0x0_book_get_amount_out"></a>

## Function `get_amount_out`

Given base_amount and quote_amount, calculate the base_amount_out and quote_amount_out.
Will return (base_amount_out, quote_amount_out) if base_amount > 0 or quote_amount > 0.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="book.md#0x0_book_get_amount_out">get_amount_out</a>(self: &<a href="book.md#0x0_book_Book">book::Book</a>, base_amount: u64, quote_amount: u64): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="book.md#0x0_book_get_amount_out">get_amount_out</a>(self: &<a href="book.md#0x0_book_Book">Book</a>, base_amount: u64, quote_amount: u64): (u64, u64) {
    <b>assert</b>!((base_amount &gt; 0 || quote_amount &gt; 0) && !(base_amount &gt; 0 && quote_amount &gt; 0), <a href="book.md#0x0_book_EInvalidAmountIn">EInvalidAmountIn</a>);
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

<a name="0x0_book_cancel_order"></a>

## Function `cancel_order`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="book.md#0x0_book_cancel_order">cancel_order</a>(self: &<b>mut</b> <a href="book.md#0x0_book_Book">book::Book</a>, order_id: u128): <a href="order.md#0x0_order_Order">order::Order</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="book.md#0x0_book_cancel_order">cancel_order</a>(self: &<b>mut</b> <a href="book.md#0x0_book_Book">Book</a>, order_id: u128): Order {
    <b>let</b> (is_bid, _, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(order_id);
    <b>if</b> (is_bid) {
        self.bids.remove(order_id)
    } <b>else</b> {
        self.asks.remove(order_id)
    }
}
</code></pre>



</details>

<a name="0x0_book_modify_order"></a>

## Function `modify_order`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="book.md#0x0_book_modify_order">modify_order</a>(self: &<b>mut</b> <a href="book.md#0x0_book_Book">book::Book</a>, order_id: u128, new_quantity: u64, timestamp: u64): (u64, u64, u64, &<a href="order.md#0x0_order_Order">order::Order</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="book.md#0x0_book_modify_order">modify_order</a>(self: &<b>mut</b> <a href="book.md#0x0_book_Book">Book</a>, order_id: u128, new_quantity: u64, timestamp: u64): (u64, u64, u64, &Order) {
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
        timestamp,
    );
    <a href="order.md#0x0_order">order</a>.set_book_quantity(new_quantity);

    <b>let</b> (base, quote, deep) = <a href="order.md#0x0_order">order</a>.cancel_amounts(book_quantity - new_quantity, <b>true</b>);

    (base, quote, deep, <a href="order.md#0x0_order">order</a>)
}
</code></pre>



</details>

<a name="0x0_book_lot_size"></a>

## Function `lot_size`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="book.md#0x0_book_lot_size">lot_size</a>(self: &<a href="book.md#0x0_book_Book">book::Book</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="book.md#0x0_book_lot_size">lot_size</a>(self: &<a href="book.md#0x0_book_Book">Book</a>): u64 {
    self.lot_size
}
</code></pre>



</details>

<a name="0x0_book_mid_price"></a>

## Function `mid_price`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="book.md#0x0_book_mid_price">mid_price</a>(self: &<a href="book.md#0x0_book_Book">book::Book</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="book.md#0x0_book_mid_price">mid_price</a>(self: &<a href="book.md#0x0_book_Book">Book</a>): u64 {
    <b>let</b> (ask_ref, ask_offset) = self.asks.min_slice();
    <b>let</b> (bid_ref, bid_offset) = self.bids.max_slice();
    <b>assert</b>!(!ask_ref.is_null() && !bid_ref.is_null(), <a href="book.md#0x0_book_EEmptyOrderbook">EEmptyOrderbook</a>);
    <b>let</b> ask_order = &self.asks.borrow_slice(ask_ref)[ask_offset];
    <b>let</b> (_, ask_price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(ask_order.book_order_id());
    <b>let</b> bid_order = &self.bids.borrow_slice(bid_ref)[bid_offset];
    <b>let</b> (_, bid_price, _) = <a href="utils.md#0x0_utils_decode_order_id">utils::decode_order_id</a>(bid_order.book_order_id());

    <a href="math.md#0x0_math_div">math::div</a>(ask_price + bid_price, 2)
}
</code></pre>



</details>

<a name="0x0_book_get_level2_range_and_ticks"></a>

## Function `get_level2_range_and_ticks`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="book.md#0x0_book_get_level2_range_and_ticks">get_level2_range_and_ticks</a>(self: &<a href="book.md#0x0_book_Book">book::Book</a>, price_low: u64, price_high: u64, ticks: u64, is_bid: bool): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="book.md#0x0_book_get_level2_range_and_ticks">get_level2_range_and_ticks</a>(
    self: &<a href="book.md#0x0_book_Book">Book</a>,
    price_low: u64,
    price_high: u64,
    ticks: u64,
    is_bid: bool,
): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;) {
    <b>assert</b>!(price_low &lt;= price_high, <a href="book.md#0x0_book_EInvalidPriceRange">EInvalidPriceRange</a>);
    <b>assert</b>!(ticks &gt; 0, <a href="book.md#0x0_book_EInvalidTicks">EInvalidTicks</a>);

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

<a name="0x0_book_match_against_book"></a>

## Function `match_against_book`

Matches the given order and quantity against the order book.
If is_bid, it will match against asks, otherwise against bids.
Mutates the order and the maker order as necessary.


<pre><code><b>fun</b> <a href="book.md#0x0_book_match_against_book">match_against_book</a>(self: &<b>mut</b> <a href="book.md#0x0_book_Book">book::Book</a>, order_info: &<b>mut</b> <a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="book.md#0x0_book_match_against_book">match_against_book</a>(
    self: &<b>mut</b> <a href="book.md#0x0_book_Book">Book</a>,
    order_info: &<b>mut</b> OrderInfo,
    timestamp: u64,
) {
    <b>let</b> is_bid = order_info.is_bid();
    <b>let</b> book_side = <b>if</b> (is_bid) &<b>mut</b> self.asks <b>else</b> &<b>mut</b> self.bids;
    <b>let</b> (<b>mut</b> ref, <b>mut</b> offset) = <b>if</b> (is_bid) book_side.min_slice() <b>else</b> book_side.max_slice();

    <b>while</b> (!ref.is_null()) {
        <b>let</b> maker_order = &<b>mut</b> book_side.borrow_slice_mut(ref)[offset];
        <b>if</b> (!order_info.match_maker(maker_order, timestamp)) <b>break</b>;
        (ref, offset) = <b>if</b> (is_bid) book_side.next_slice(ref, offset) <b>else</b> book_side.prev_slice(ref, offset);

        <b>let</b> (order_id, _, expired, complete) = order_info.last_fill().fill_status();
        <b>if</b> (expired || complete) {
            book_side.remove(order_id);
        };
    };
}
</code></pre>



</details>

<a name="0x0_book_get_order_id"></a>

## Function `get_order_id`



<pre><code><b>fun</b> <a href="book.md#0x0_book_get_order_id">get_order_id</a>(self: &<b>mut</b> <a href="book.md#0x0_book_Book">book::Book</a>, is_bid: bool): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="book.md#0x0_book_get_order_id">get_order_id</a>(self: &<b>mut</b> <a href="book.md#0x0_book_Book">Book</a>, is_bid: bool): u64 {
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

<a name="0x0_book_inject_limit_order"></a>

## Function `inject_limit_order`

Balance accounting happens before this function is called


<pre><code><b>fun</b> <a href="book.md#0x0_book_inject_limit_order">inject_limit_order</a>(self: &<b>mut</b> <a href="book.md#0x0_book_Book">book::Book</a>, order_info: &<a href="order.md#0x0_order_OrderInfo">order::OrderInfo</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="book.md#0x0_book_inject_limit_order">inject_limit_order</a>(
    self: &<b>mut</b> <a href="book.md#0x0_book_Book">Book</a>,
    order_info: &OrderInfo,
) {
    <b>let</b> <a href="order.md#0x0_order">order</a> = order_info.to_order();
    <b>if</b> (order_info.is_bid()) {
        self.bids.insert(order_info.order_id(), <a href="order.md#0x0_order">order</a>);
    } <b>else</b> {
        self.asks.insert(order_info.order_id(), <a href="order.md#0x0_order">order</a>);
    };
}
</code></pre>



</details>