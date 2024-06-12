
<a name="0x0_fill"></a>

# Module `0x0::fill`



-  [Struct `Fill`](#0x0_fill_Fill)
-  [Function `new`](#0x0_fill_new)
-  [Function `order_id`](#0x0_fill_order_id)
-  [Function `balance_manager_id`](#0x0_fill_balance_manager_id)
-  [Function `expired`](#0x0_fill_expired)
-  [Function `completed`](#0x0_fill_completed)
-  [Function `base_quantity`](#0x0_fill_base_quantity)
-  [Function `taker_is_bid`](#0x0_fill_taker_is_bid)
-  [Function `quote_quantity`](#0x0_fill_quote_quantity)
-  [Function `maker_epoch`](#0x0_fill_maker_epoch)
-  [Function `maker_deep_per_base`](#0x0_fill_maker_deep_per_base)
-  [Function `get_settled_maker_quantities`](#0x0_fill_get_settled_maker_quantities)


<pre><code><b>use</b> <a href="balances.md#0x0_balances">0x0::balances</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
</code></pre>



<a name="0x0_fill_Fill"></a>

## Struct `Fill`

Fill struct represents the results of a match between two orders.
It is used to update the state.


<pre><code><b>struct</b> <a href="fill.md#0x0_fill_Fill">Fill</a> <b>has</b> <b>copy</b>, drop, store
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
<code>balance_manager_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
</dt>
<dd>

</dd>
<dt>
<code>expired: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>completed: bool</code>
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
<code>taker_is_bid: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>maker_epoch: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>maker_deep_per_base: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_fill_new"></a>

## Function `new`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_new">new</a>(order_id: u128, balance_manager_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, expired: bool, completed: bool, base_quantity: u64, quote_quantity: u64, taker_is_bid: bool, maker_epoch: u64, maker_deep_per_base: u64): <a href="fill.md#0x0_fill_Fill">fill::Fill</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_new">new</a>(
    order_id: u128,
    balance_manager_id: ID,
    expired: bool,
    completed: bool,
    base_quantity: u64,
    quote_quantity: u64,
    taker_is_bid: bool,
    maker_epoch: u64,
    maker_deep_per_base: u64,
): <a href="fill.md#0x0_fill_Fill">Fill</a> {
    <a href="fill.md#0x0_fill_Fill">Fill</a> {
        order_id,
        balance_manager_id,
        expired,
        completed,
        base_quantity,
        quote_quantity,
        taker_is_bid,
        maker_epoch,
        maker_deep_per_base,
    }
}
</code></pre>



</details>

<a name="0x0_fill_order_id"></a>

## Function `order_id`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_order_id">order_id</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): u128
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_order_id">order_id</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): u128 {
    self.order_id
}
</code></pre>



</details>

<a name="0x0_fill_balance_manager_id"></a>

## Function `balance_manager_id`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_balance_manager_id">balance_manager_id</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_balance_manager_id">balance_manager_id</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): ID {
    self.balance_manager_id
}
</code></pre>



</details>

<a name="0x0_fill_expired"></a>

## Function `expired`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_expired">expired</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_expired">expired</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): bool {
    self.expired
}
</code></pre>



</details>

<a name="0x0_fill_completed"></a>

## Function `completed`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_completed">completed</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_completed">completed</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): bool {
    self.completed
}
</code></pre>



</details>

<a name="0x0_fill_base_quantity"></a>

## Function `base_quantity`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_base_quantity">base_quantity</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_base_quantity">base_quantity</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): u64 {
    self.base_quantity
}
</code></pre>



</details>

<a name="0x0_fill_taker_is_bid"></a>

## Function `taker_is_bid`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_taker_is_bid">taker_is_bid</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_taker_is_bid">taker_is_bid</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): bool {
    self.taker_is_bid
}
</code></pre>



</details>

<a name="0x0_fill_quote_quantity"></a>

## Function `quote_quantity`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_quote_quantity">quote_quantity</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_quote_quantity">quote_quantity</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): u64 {
    <b>if</b> (self.expired) {
        0
    } <b>else</b> {
        self.quote_quantity
    }
}
</code></pre>



</details>

<a name="0x0_fill_maker_epoch"></a>

## Function `maker_epoch`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_maker_epoch">maker_epoch</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_maker_epoch">maker_epoch</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): u64 {
    self.maker_epoch
}
</code></pre>



</details>

<a name="0x0_fill_maker_deep_per_base"></a>

## Function `maker_deep_per_base`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_maker_deep_per_base">maker_deep_per_base</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_maker_deep_per_base">maker_deep_per_base</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): u64 {
    self.maker_deep_per_base
}
</code></pre>



</details>

<a name="0x0_fill_get_settled_maker_quantities"></a>

## Function `get_settled_maker_quantities`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_get_settled_maker_quantities">get_settled_maker_quantities</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): <a href="balances.md#0x0_balances_Balances">balances::Balances</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_get_settled_maker_quantities">get_settled_maker_quantities</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): Balances {
    <b>let</b> (base, quote) = <b>if</b> (self.expired) {
        <b>if</b> (self.taker_is_bid) {
            (self.base_quantity, 0)
        } <b>else</b> {
            (0, self.quote_quantity)
        }
    } <b>else</b> {
        <b>if</b> (self.taker_is_bid) {
            (0, self.quote_quantity)
        } <b>else</b> {
            (self.base_quantity, 0)
        }
    };

    <a href="balances.md#0x0_balances_new">balances::new</a>(base, quote, 0)
}
</code></pre>



</details>
