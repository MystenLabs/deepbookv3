
<a name="0x0_deep_price"></a>

# Module `0x0::deep_price`



-  [Struct `DeepPrice`](#0x0_deep_price_DeepPrice)
-  [Function `new`](#0x0_deep_price_new)
-  [Function `add_price_point`](#0x0_deep_price_add_price_point)
-  [Function `verified`](#0x0_deep_price_verified)
-  [Function `calculate_fees`](#0x0_deep_price_calculate_fees)


<pre><code><b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
</code></pre>



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

<a name="0x0_deep_price_new"></a>

## Function `new`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_new">new</a>(): <a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_new">new</a>(): <a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a> {
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

<a name="0x0_deep_price_verified"></a>

## Function `verified`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_verified">verified</a>(self: &<a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_verified">verified</a>(
    self: &<a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a>,
): bool {
    self.last_insert_timestamp &gt; 0
}
</code></pre>



</details>

<a name="0x0_deep_price_calculate_fees"></a>

## Function `calculate_fees`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_calculate_fees">calculate_fees</a>(self: &<a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>, fee_rate: u64, base_quantity: u64, quote_quantity: u64): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_calculate_fees">calculate_fees</a>(
    self: &<a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a>,
    fee_rate: u64,
    base_quantity: u64,
    quote_quantity: u64,
): (u64, u64, u64) {
    <b>if</b> (self.<a href="deep_price.md#0x0_deep_price_verified">verified</a>()) {
        <b>let</b> base_fee = math::mul(fee_rate, math::mul(base_quantity, self.deep_per_base));
        <b>let</b> quote_fee = math::mul(fee_rate, math::mul(quote_quantity, self.deep_per_quote));

        <b>return</b> (0, 0, base_fee + quote_fee)
    };

    <b>let</b> base_fee = math::mul(fee_rate, base_quantity);
    <b>let</b> quote_fee = math::mul(fee_rate, quote_quantity);

    (base_fee, quote_fee, 0)
}
</code></pre>



</details>
