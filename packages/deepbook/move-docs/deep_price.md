
<a name="0x0_deep_price"></a>

# Module `0x0::deep_price`



-  [Struct `DeepPrice`](#0x0_deep_price_DeepPrice)
-  [Function `empty`](#0x0_deep_price_empty)
-  [Function `add_price_point`](#0x0_deep_price_add_price_point)
-  [Function `deep_per_base`](#0x0_deep_price_deep_per_base)
-  [Function `deep_per_quote`](#0x0_deep_price_deep_per_quote)


<pre><code></code></pre>



<a name="0x0_deep_price_DeepPrice"></a>

## Struct `DeepPrice`



<pre><code><b>struct</b> <a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>last_insert_timestamp: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>price_points_base: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>price_points_quote: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>deep_per_base: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>deep_per_quote: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_deep_price_empty"></a>

## Function `empty`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_empty">empty</a>(): <a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_empty">empty</a>(): <a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a> {
    // Initialize the DEEP price points
    <a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a> {
        last_insert_timestamp: 0,
        price_points_base: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
        price_points_quote: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
        deep_per_base: 0,
        deep_per_quote: 0,
    }
}
</code></pre>



</details>

<a name="0x0_deep_price_add_price_point"></a>

## Function `add_price_point`

Add a price point. All values are validated by this point.
Calculate the rolling average and update deep_per_base, deep_per_quote.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_add_price_point">add_price_point</a>(_deep_price: &<b>mut</b> <a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>, _timestamp: u64, _base_conversion_rate: u64, _quote_conversion_rate: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_add_price_point">add_price_point</a>(
    _deep_price: &<b>mut</b> <a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a>,
    _timestamp: u64,
    _base_conversion_rate: u64,
    _quote_conversion_rate: u64,
) {
    // TODO
}
</code></pre>



</details>

<a name="0x0_deep_price_deep_per_base"></a>

## Function `deep_per_base`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_deep_per_base">deep_per_base</a>(<a href="deep_price.md#0x0_deep_price">deep_price</a>: &<a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_deep_per_base">deep_per_base</a>(<a href="deep_price.md#0x0_deep_price">deep_price</a>: &<a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a>): u64 {
    <a href="deep_price.md#0x0_deep_price">deep_price</a>.deep_per_base
}
</code></pre>



</details>

<a name="0x0_deep_price_deep_per_quote"></a>

## Function `deep_per_quote`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_deep_per_quote">deep_per_quote</a>(<a href="deep_price.md#0x0_deep_price">deep_price</a>: &<a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_deep_per_quote">deep_per_quote</a>(<a href="deep_price.md#0x0_deep_price">deep_price</a>: &<a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a>): u64 {
    <a href="deep_price.md#0x0_deep_price">deep_price</a>.deep_per_quote
}
</code></pre>



</details>
