
<a name="0x0_pool"></a>

# Module `0x0::pool`



-  [Struct `Order`](#0x0_pool_Order)
-  [Struct `TickLevel`](#0x0_pool_TickLevel)
-  [Resource `Pool`](#0x0_pool_Pool)
-  [Function `init`](#0x0_pool_init)
-  [Function `place_limit_order_critbit`](#0x0_pool_place_limit_order_critbit)
-  [Function `place_limit_order_bigvec`](#0x0_pool_place_limit_order_bigvec)
-  [Function `encode_order_id`](#0x0_pool_encode_order_id)


<pre><code><b>use</b> <a href="big_vector.md#0x0_big_vector">0x0::big_vector</a>;
<b>use</b> <a href="critbit.md#0x0_critbit">0x0::critbit</a>;
<b>use</b> <a href="dependencies/sui-framework/event.md#0x2_event">0x2::event</a>;
<b>use</b> <a href="dependencies/sui-framework/linked_table.md#0x2_linked_table">0x2::linked_table</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
<b>use</b> <a href="dependencies/sui-framework/table.md#0x2_table">0x2::table</a>;
<b>use</b> <a href="dependencies/sui-framework/transfer.md#0x2_transfer">0x2::transfer</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
</code></pre>



<a name="0x0_pool_Order"></a>

## Struct `Order`



<pre><code><b>struct</b> <a href="pool.md#0x0_pool_Order">Order</a> <b>has</b> <b>copy</b>, drop, store
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
<code>price: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>quantity: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>owner: <b>address</b></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_pool_TickLevel"></a>

## Struct `TickLevel`



<pre><code><b>struct</b> <a href="pool.md#0x0_pool_TickLevel">TickLevel</a> <b>has</b> store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>price: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>open_orders: <a href="dependencies/sui-framework/linked_table.md#0x2_linked_table_LinkedTable">linked_table::LinkedTable</a>&lt;u128, <a href="pool.md#0x0_pool_Order">pool::Order</a>&gt;</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_pool_Pool"></a>

## Resource `Pool`



<pre><code><b>struct</b> <a href="pool.md#0x0_pool_Pool">Pool</a> <b>has</b> store, key
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
<code>bids_critbit: <a href="critbit.md#0x0_critbit_CritbitTree">critbit::CritbitTree</a>&lt;<a href="pool.md#0x0_pool_TickLevel">pool::TickLevel</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>asks_critbit: <a href="critbit.md#0x0_critbit_CritbitTree">critbit::CritbitTree</a>&lt;<a href="pool.md#0x0_pool_TickLevel">pool::TickLevel</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>bids_bigvec: <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;<a href="pool.md#0x0_pool_Order">pool::Order</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>asks_bigvec: <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;<a href="pool.md#0x0_pool_Order">pool::Order</a>&gt;</code>
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
<code>user_open_orders: <a href="dependencies/sui-framework/table.md#0x2_table_Table">table::Table</a>&lt;<b>address</b>, <a href="dependencies/sui-framework/linked_table.md#0x2_linked_table_LinkedTable">linked_table::LinkedTable</a>&lt;u128, u128&gt;&gt;</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_pool_init"></a>

## Function `init`



<pre><code><b>fun</b> <a href="pool.md#0x0_pool_init">init</a>(ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_init">init</a>(ctx: &<b>mut</b> TxContext) {
    <b>let</b> <a href="pool.md#0x0_pool">pool</a> = <a href="pool.md#0x0_pool_Pool">Pool</a> {
        id: <a href="dependencies/sui-framework/object.md#0x2_object_new">object::new</a>(ctx),
        bids_critbit: <a href="critbit.md#0x0_critbit_new">critbit::new</a>(ctx),
        asks_critbit: <a href="critbit.md#0x0_critbit_new">critbit::new</a>(ctx),
        bids_bigvec: <a href="big_vector.md#0x0_big_vector_empty">big_vector::empty</a>(10000, 1000, ctx),
        asks_bigvec: <a href="big_vector.md#0x0_big_vector_empty">big_vector::empty</a>(10000, 1000, ctx),
        next_bid_order_id: 0,
        next_ask_order_id: 1000000,
        user_open_orders: <a href="dependencies/sui-framework/table.md#0x2_table_new">table::new</a>(ctx),
    };

    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_share_object">transfer::share_object</a>(<a href="pool.md#0x0_pool">pool</a>);
}
</code></pre>



</details>

<a name="0x0_pool_place_limit_order_critbit"></a>

## Function `place_limit_order_critbit`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_place_limit_order_critbit">place_limit_order_critbit</a>(<a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>, price: u64, quantity: u64, is_bid: bool, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): u128
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_place_limit_order_critbit">place_limit_order_critbit</a>(
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>,
    price: u64,
    quantity: u64,
    is_bid: bool,
    ctx: &<b>mut</b> TxContext,
): u128 {
    <b>let</b> owner = ctx.sender();
    <b>let</b> order_id: u128;
    <b>let</b> open_orders: &<b>mut</b> CritbitTree&lt;<a href="pool.md#0x0_pool_TickLevel">TickLevel</a>&gt;;
    <b>if</b> (is_bid) {
        order_id = <a href="pool.md#0x0_pool">pool</a>.next_bid_order_id <b>as</b> u128;
        <a href="pool.md#0x0_pool">pool</a>.next_bid_order_id = <a href="pool.md#0x0_pool">pool</a>.next_bid_order_id + 1;
        open_orders = &<b>mut</b> <a href="pool.md#0x0_pool">pool</a>.bids_critbit;
    } <b>else</b> {
        order_id = <a href="pool.md#0x0_pool">pool</a>.next_ask_order_id <b>as</b> u128;
        <a href="pool.md#0x0_pool">pool</a>.next_ask_order_id = <a href="pool.md#0x0_pool">pool</a>.next_ask_order_id + 1;
        open_orders = &<b>mut</b> <a href="pool.md#0x0_pool">pool</a>.asks_critbit;
    };

    <b>let</b> order = <a href="pool.md#0x0_pool_Order">Order</a> {
        order_id: order_id,
        price: price,
        quantity: quantity,
        owner: owner,
    };

    <b>let</b> (tick_exists, <b>mut</b> tick_index) = open_orders.find_leaf(price);
    <b>if</b> (!tick_exists) {
        tick_index = open_orders.insert_leaf(
            price,
            <a href="pool.md#0x0_pool_TickLevel">TickLevel</a> {
                price,
                open_orders: <a href="dependencies/sui-framework/linked_table.md#0x2_linked_table_new">linked_table::new</a>(ctx),
            });
    };

    <b>let</b> tick_level = open_orders.borrow_mut_leaf_by_index(tick_index);
    tick_level.open_orders.push_back(order_id, order);
    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="pool.md#0x0_pool_Order">Order</a> {
        order_id,
        price,
        quantity,
        owner: owner,
    });
    <b>if</b> (!<a href="pool.md#0x0_pool">pool</a>.user_open_orders.contains(owner)) {
        <a href="pool.md#0x0_pool">pool</a>.user_open_orders.add(owner, <a href="dependencies/sui-framework/linked_table.md#0x2_linked_table_new">linked_table::new</a>(ctx));
    };
    <a href="pool.md#0x0_pool">pool</a>.user_open_orders.borrow_mut(owner).push_back(order_id, order_id);

    order_id
}
</code></pre>



</details>

<a name="0x0_pool_place_limit_order_bigvec"></a>

## Function `place_limit_order_bigvec`



<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_place_limit_order_bigvec">place_limit_order_bigvec</a>(<a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>, price: u64, quantity: u64, is_bid: bool, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): u128
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="pool.md#0x0_pool_place_limit_order_bigvec">place_limit_order_bigvec</a>(
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">Pool</a>,
    price: u64,
    quantity: u64,
    is_bid: bool,
    ctx: &<b>mut</b> TxContext,
): u128 {
    <b>let</b> owner = ctx.sender();
    <b>let</b> order_id;
    <b>let</b> open_orders: &<b>mut</b> BigVector&lt;<a href="pool.md#0x0_pool_Order">Order</a>&gt;;
    <b>if</b> (is_bid) {
        order_id = <a href="pool.md#0x0_pool_encode_order_id">encode_order_id</a>(price, <a href="pool.md#0x0_pool">pool</a>.next_bid_order_id);
        <a href="pool.md#0x0_pool">pool</a>.next_bid_order_id = <a href="pool.md#0x0_pool">pool</a>.next_bid_order_id - 1;
        open_orders = &<b>mut</b> <a href="pool.md#0x0_pool">pool</a>.bids_bigvec;
    } <b>else</b> {
        order_id = <a href="pool.md#0x0_pool_encode_order_id">encode_order_id</a>(price, <a href="pool.md#0x0_pool">pool</a>.next_ask_order_id);
        <a href="pool.md#0x0_pool">pool</a>.next_ask_order_id = <a href="pool.md#0x0_pool">pool</a>.next_ask_order_id + 1;
        open_orders = &<b>mut</b> <a href="pool.md#0x0_pool">pool</a>.asks_bigvec;
    };

    <b>let</b> order = <a href="pool.md#0x0_pool_Order">Order</a> {
        order_id: order_id,
        price: price,
        quantity: quantity,
        owner: owner,
    };

    open_orders.insert(order_id, order);

    <a href="dependencies/sui-framework/event.md#0x2_event_emit">event::emit</a>(<a href="pool.md#0x0_pool_Order">Order</a> {
        order_id,
        price,
        quantity,
        owner: owner,
    });
    <b>if</b> (!<a href="pool.md#0x0_pool">pool</a>.user_open_orders.contains(owner)) {
        <a href="pool.md#0x0_pool">pool</a>.user_open_orders.add(owner, <a href="dependencies/sui-framework/linked_table.md#0x2_linked_table_new">linked_table::new</a>(ctx));
    };
    <a href="pool.md#0x0_pool">pool</a>.user_open_orders.borrow_mut(owner).push_back(order_id, order_id);

    order_id
}
</code></pre>



</details>

<a name="0x0_pool_encode_order_id"></a>

## Function `encode_order_id`



<pre><code><b>fun</b> <a href="pool.md#0x0_pool_encode_order_id">encode_order_id</a>(price: u64, order_id: u64): u128
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool.md#0x0_pool_encode_order_id">encode_order_id</a>(
    price: u64,
    order_id: u64
): u128 {
    ((price <b>as</b> u128) &lt;&lt; 64) + (order_id <b>as</b> u128)
}
</code></pre>



</details>
