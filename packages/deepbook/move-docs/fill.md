
<a name="0x0_fill"></a>

# Module `0x0::fill`



-  [Struct `Fill`](#0x0_fill_Fill)
-  [Function `new`](#0x0_fill_new)
-  [Function `order_id`](#0x0_fill_order_id)
-  [Function `account_id`](#0x0_fill_account_id)
-  [Function `expired`](#0x0_fill_expired)
-  [Function `completed`](#0x0_fill_completed)
-  [Function `volume`](#0x0_fill_volume)
-  [Function `taker_is_bid`](#0x0_fill_taker_is_bid)
-  [Function `quote_quantity`](#0x0_fill_quote_quantity)
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
<code>account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a></code>
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
<code>volume: u64</code>
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
</dl>


</details>

<a name="0x0_fill_new"></a>

## Function `new`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_new">new</a>(order_id: u128, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, expired: bool, completed: bool, volume: u64, quote_quantity: u64, taker_is_bid: bool): <a href="fill.md#0x0_fill_Fill">fill::Fill</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_new">new</a>(
    order_id: u128,
    account_id: ID,
    expired: bool,
    completed: bool,
    volume: u64,
    quote_quantity: u64,
    taker_is_bid: bool,
): <a href="fill.md#0x0_fill_Fill">Fill</a> {
    <a href="fill.md#0x0_fill_Fill">Fill</a> {
        order_id,
        account_id,
        expired,
        completed,
        volume,
        quote_quantity,
        taker_is_bid,
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

<a name="0x0_fill_account_id"></a>

## Function `account_id`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_account_id">account_id</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_account_id">account_id</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): ID {
    self.account_id
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

<a name="0x0_fill_volume"></a>

## Function `volume`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_volume">volume</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_volume">volume</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): u64 {
    self.volume
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

<a name="0x0_fill_get_settled_maker_quantities"></a>

## Function `get_settled_maker_quantities`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_get_settled_maker_quantities">get_settled_maker_quantities</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): <a href="balances.md#0x0_balances_Balances">balances::Balances</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_get_settled_maker_quantities">get_settled_maker_quantities</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): Balances {
    <b>let</b> (base, quote) = <b>if</b> (self.expired) {
        <b>if</b> (self.taker_is_bid) {
            (self.volume, 0)
        } <b>else</b> {
            (0, self.quote_quantity)
        }
    } <b>else</b> {
        <b>if</b> (self.taker_is_bid) {
            (0, self.quote_quantity)
        } <b>else</b> {
            (self.volume, 0)
        }
    };

    <a href="balances.md#0x0_balances_new">balances::new</a>(base, quote, 0)
}
</code></pre>



</details>
