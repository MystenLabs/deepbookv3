
<a name="0x0_deep_price"></a>

# Module `0x0::deep_price`



-  [Struct `DeepPrice`](#0x0_deep_price_DeepPrice)
-  [Constants](#@Constants_0)
-  [Function `new`](#0x0_deep_price_new)
-  [Function `add_price_point`](#0x0_deep_price_add_price_point)
-  [Function `verified`](#0x0_deep_price_verified)
-  [Function `calculate_fees`](#0x0_deep_price_calculate_fees)


<pre><code><b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">0x1::vector</a>;
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
<code>index_to_replace: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>cumulative_base: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>cumulative_quote: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_deep_price_EDataPointRecentlyAdded"></a>



<pre><code><b>const</b> <a href="deep_price.md#0x0_deep_price_EDataPointRecentlyAdded">EDataPointRecentlyAdded</a>: u64 = 1;
</code></pre>



<a name="0x0_deep_price_MAX_DATA_POINTS"></a>



<pre><code><b>const</b> <a href="deep_price.md#0x0_deep_price_MAX_DATA_POINTS">MAX_DATA_POINTS</a>: u64 = 100;
</code></pre>



<a name="0x0_deep_price_MIN_DURATION_BETWEEN_DATA_POINTS_MS"></a>



<pre><code><b>const</b> <a href="deep_price.md#0x0_deep_price_MIN_DURATION_BETWEEN_DATA_POINTS_MS">MIN_DURATION_BETWEEN_DATA_POINTS_MS</a>: u64 = 900000;
</code></pre>



<a name="0x0_deep_price_new"></a>

## Function `new`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_new">new</a>(): <a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_new">new</a>(): <a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a> {
    <a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a> {
        last_insert_timestamp: 0,
        price_points_base: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
        price_points_quote: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
        index_to_replace: 0,
        cumulative_base: 0,
        cumulative_quote: 0,
    }
}
</code></pre>



</details>

<a name="0x0_deep_price_add_price_point"></a>

## Function `add_price_point`

Add a price point. All values are validated by this point.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_add_price_point">add_price_point</a>(self: &<b>mut</b> <a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>, timestamp: u64, base_conversion_rate: u64, quote_conversion_rate: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_add_price_point">add_price_point</a>(
    self: &<b>mut</b> <a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a>,
    timestamp: u64,
    base_conversion_rate: u64,
    quote_conversion_rate: u64,
) {
    <b>assert</b>!(self.last_insert_timestamp + <a href="deep_price.md#0x0_deep_price_MIN_DURATION_BETWEEN_DATA_POINTS_MS">MIN_DURATION_BETWEEN_DATA_POINTS_MS</a> &lt; timestamp, <a href="deep_price.md#0x0_deep_price_EDataPointRecentlyAdded">EDataPointRecentlyAdded</a>);

    <b>if</b> (self.price_points_base.length() == <a href="deep_price.md#0x0_deep_price_MAX_DATA_POINTS">MAX_DATA_POINTS</a>) {
        <b>let</b> idx = self.index_to_replace;
        self.cumulative_base = self.cumulative_base - self.price_points_base[idx] + base_conversion_rate;
        self.cumulative_quote = self.cumulative_quote - self.price_points_quote[idx] + quote_conversion_rate;
        self.price_points_base.insert(idx, base_conversion_rate);
        self.price_points_quote.insert(idx, quote_conversion_rate);
        self.index_to_replace = self.index_to_replace + 1 % <a href="deep_price.md#0x0_deep_price_MAX_DATA_POINTS">MAX_DATA_POINTS</a>;
    } <b>else</b> {
        self.price_points_base.push_back(base_conversion_rate);
        self.price_points_quote.push_back(quote_conversion_rate);
        self.cumulative_base = self.cumulative_base + base_conversion_rate;
        self.cumulative_quote = self.cumulative_quote + quote_conversion_rate;
    }
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
        <b>let</b> deep_per_base = math::div(self.cumulative_base, self.price_points_base.length());
        <b>let</b> deep_per_quote = math::div(self.cumulative_quote, self.price_points_quote.length());
        <b>let</b> base_fee = math::mul(fee_rate, math::mul(base_quantity, deep_per_base));
        <b>let</b> quote_fee = math::mul(fee_rate, math::mul(quote_quantity, deep_per_quote));

        <b>return</b> (0, 0, base_fee + quote_fee)
    };

    <b>let</b> base_fee = math::mul(fee_rate, base_quantity);
    <b>let</b> quote_fee = math::mul(fee_rate, quote_quantity);

    (base_fee, quote_fee, 0)
}
</code></pre>



</details>
