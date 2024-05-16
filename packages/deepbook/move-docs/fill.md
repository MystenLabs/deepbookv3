
<a name="0x0_fill"></a>

# Module `0x0::fill`



-  [Struct `Fill`](#0x0_fill_Fill)
-  [Function `new`](#0x0_fill_new)
-  [Function `order_id`](#0x0_fill_order_id)
-  [Function `account_id`](#0x0_fill_account_id)
-  [Function `expired`](#0x0_fill_expired)
-  [Function `completed`](#0x0_fill_completed)
-  [Function `volume`](#0x0_fill_volume)
-  [Function `settled_base`](#0x0_fill_settled_base)
-  [Function `settled_quote`](#0x0_fill_settled_quote)
-  [Function `settled_deep`](#0x0_fill_settled_deep)


<pre><code><b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
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

<a name="0x0_fill_new"></a>

## Function `new`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_new">new</a>(order_id: u128, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, expired: bool, completed: bool, volume: u64, settled_base: u64, settled_quote: u64, settled_deep: u64): <a href="fill.md#0x0_fill_Fill">fill::Fill</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_new">new</a>(
    order_id: u128,
    account_id: ID,
    expired: bool,
    completed: bool,
    volume: u64,
    settled_base: u64,
    settled_quote: u64,
    settled_deep: u64,
): <a href="fill.md#0x0_fill_Fill">Fill</a> {
    <a href="fill.md#0x0_fill_Fill">Fill</a> {
        order_id,
        account_id,
        expired,
        completed,
        volume,
        settled_base,
        settled_quote,
        settled_deep,
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

<a name="0x0_fill_settled_base"></a>

## Function `settled_base`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_settled_base">settled_base</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_settled_base">settled_base</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): u64 {
    self.settled_base
}
</code></pre>



</details>

<a name="0x0_fill_settled_quote"></a>

## Function `settled_quote`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_settled_quote">settled_quote</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_settled_quote">settled_quote</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): u64 {
    self.settled_quote
}
</code></pre>



</details>

<a name="0x0_fill_settled_deep"></a>

## Function `settled_deep`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="fill.md#0x0_fill_settled_deep">settled_deep</a>(self: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="fill.md#0x0_fill_settled_deep">settled_deep</a>(self: &<a href="fill.md#0x0_fill_Fill">Fill</a>): u64 {
    self.settled_deep
}
</code></pre>



</details>
