
<a name="0x0_deep_price"></a>

# Module `0x0::deep_price`



-  [Struct `Price`](#0x0_deep_price_Price)
-  [Struct `DeepPrice`](#0x0_deep_price_DeepPrice)
-  [Constants](#@Constants_0)
-  [Function `empty`](#0x0_deep_price_empty)
-  [Function `add_price_point`](#0x0_deep_price_add_price_point)
-  [Function `conversion_rate`](#0x0_deep_price_conversion_rate)
-  [Function `last_insert_timestamp`](#0x0_deep_price_last_insert_timestamp)


<pre><code><b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">0x1::vector</a>;
</code></pre>



<a name="0x0_deep_price_Price"></a>

## Struct `Price`

DEEP price point.


<pre><code><b>struct</b> <a href="deep_price.md#0x0_deep_price_Price">Price</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>timestamp: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>base_conversion_rate: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_deep_price_DeepPrice"></a>

## Struct `DeepPrice`

DEEP price points used for trading fee calculations.


<pre><code><b>struct</b> <a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>prices: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="deep_price.md#0x0_deep_price_Price">deep_price::Price</a>&gt;</code>
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



<a name="0x0_deep_price_MAX_DATA_POINT_AGE_MS"></a>



<pre><code><b>const</b> <a href="deep_price.md#0x0_deep_price_MAX_DATA_POINT_AGE_MS">MAX_DATA_POINT_AGE_MS</a>: u64 = 86400000;
</code></pre>



<a name="0x0_deep_price_MIN_DURATION_BETWEEN_DATA_POINTS_MS"></a>



<pre><code><b>const</b> <a href="deep_price.md#0x0_deep_price_MIN_DURATION_BETWEEN_DATA_POINTS_MS">MIN_DURATION_BETWEEN_DATA_POINTS_MS</a>: u64 = 60000;
</code></pre>



<a name="0x0_deep_price_empty"></a>

## Function `empty`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_empty">empty</a>(): <a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="deep_price.md#0x0_deep_price_empty">empty</a>(): <a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a> {
    <a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a> {
        prices: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
        index_to_replace: 0,
        cumulative_base: 0,
    }
}
</code></pre>



</details>

<a name="0x0_deep_price_add_price_point"></a>

## Function `add_price_point`

Add a price point. If max data points are reached, the oldest data point is removed.
Remove all data points older than MAX_DATA_POINT_AGE_MS.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_add_price_point">add_price_point</a>(self: &<b>mut</b> <a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>, timestamp: u64, base_conversion_rate: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="deep_price.md#0x0_deep_price_add_price_point">add_price_point</a>(
    self: &<b>mut</b> <a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a>,
    timestamp: u64,
    base_conversion_rate: u64,
) {
    <b>assert</b>!(self.<a href="deep_price.md#0x0_deep_price_last_insert_timestamp">last_insert_timestamp</a>() + <a href="deep_price.md#0x0_deep_price_MIN_DURATION_BETWEEN_DATA_POINTS_MS">MIN_DURATION_BETWEEN_DATA_POINTS_MS</a> &lt; timestamp, <a href="deep_price.md#0x0_deep_price_EDataPointRecentlyAdded">EDataPointRecentlyAdded</a>);
    self.prices.push_back(<a href="deep_price.md#0x0_deep_price_Price">Price</a> {
        timestamp: timestamp,
        base_conversion_rate: base_conversion_rate,
    });
    self.cumulative_base = self.cumulative_base + base_conversion_rate;

    <b>let</b> idx = self.index_to_replace;
    <b>if</b> (self.prices.length() == <a href="deep_price.md#0x0_deep_price_MAX_DATA_POINTS">MAX_DATA_POINTS</a> + 1) {
        self.cumulative_base = self.cumulative_base - self.prices[idx].base_conversion_rate;
        self.prices.swap_remove(idx);
        self.prices.swap_remove(idx);
        self.index_to_replace = self.index_to_replace + 1 % <a href="deep_price.md#0x0_deep_price_MAX_DATA_POINTS">MAX_DATA_POINTS</a>;
    };

    <b>let</b> <b>mut</b> idx = self.index_to_replace;
    <b>while</b> (self.prices[idx].timestamp + <a href="deep_price.md#0x0_deep_price_MAX_DATA_POINT_AGE_MS">MAX_DATA_POINT_AGE_MS</a> &lt; timestamp) {
        self.cumulative_base = self.cumulative_base - self.prices[idx].base_conversion_rate;
        self.prices.remove(idx);
        self.index_to_replace = self.index_to_replace + 1 % <a href="deep_price.md#0x0_deep_price_MAX_DATA_POINTS">MAX_DATA_POINTS</a>;
        idx = self.index_to_replace;
    }
}
</code></pre>



</details>

<a name="0x0_deep_price_conversion_rate"></a>

## Function `conversion_rate`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_conversion_rate">conversion_rate</a>(self: &<a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="deep_price.md#0x0_deep_price_conversion_rate">conversion_rate</a>(
    self: &<a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a>,
): u64 {
    // TODO: Add <b>assert</b>, <b>assert</b>!(self.<a href="deep_price.md#0x0_deep_price_last_insert_timestamp">last_insert_timestamp</a>() &gt; 0, ENoDataPoints);
    <b>if</b> (self.<a href="deep_price.md#0x0_deep_price_last_insert_timestamp">last_insert_timestamp</a>() == 0) <b>return</b> 10 * 1_000_000_000; // Default deep conversion rate <b>to</b> 10
    <b>let</b> deep_per_base = <a href="math.md#0x0_math_div">math::div</a>(self.cumulative_base, self.prices.length());

    deep_per_base
}
</code></pre>



</details>

<a name="0x0_deep_price_last_insert_timestamp"></a>

## Function `last_insert_timestamp`



<pre><code><b>fun</b> <a href="deep_price.md#0x0_deep_price_last_insert_timestamp">last_insert_timestamp</a>(self: &<a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="deep_price.md#0x0_deep_price_last_insert_timestamp">last_insert_timestamp</a>(self: &<a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a>): u64 {
    <b>if</b> (self.prices.length() &gt; 0) {
        self.prices[self.prices.length() - 1].timestamp
    } <b>else</b> {
        0
    }
}
</code></pre>



</details>
