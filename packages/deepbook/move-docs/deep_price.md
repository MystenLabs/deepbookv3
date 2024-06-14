
<a name="0x0_deep_price"></a>

# Module `0x0::deep_price`



-  [Struct `Price`](#0x0_deep_price_Price)
-  [Struct `DeepPrice`](#0x0_deep_price_DeepPrice)
-  [Struct `OrderDeepPrice`](#0x0_deep_price_OrderDeepPrice)
-  [Constants](#@Constants_0)
-  [Function `empty`](#0x0_deep_price_empty)
-  [Function `new_order_deep_price`](#0x0_deep_price_new_order_deep_price)
-  [Function `get_order_deep_price`](#0x0_deep_price_get_order_deep_price)
-  [Function `deep_per_asset`](#0x0_deep_price_deep_per_asset)
-  [Function `asset_is_base`](#0x0_deep_price_asset_is_base)
-  [Function `quantity_in_deep`](#0x0_deep_price_quantity_in_deep)
-  [Function `add_price_point`](#0x0_deep_price_add_price_point)
-  [Function `calculate_order_deep_price`](#0x0_deep_price_calculate_order_deep_price)
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
<code>conversion_rate: u64</code>
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

<a name="0x0_deep_price_DeepPrice"></a>

## Struct `DeepPrice`

DEEP price points used for trading fee calculations.


<pre><code><b>struct</b> <a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>base_prices: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="deep_price.md#0x0_deep_price_Price">deep_price::Price</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>cumulative_base: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>quote_prices: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="deep_price.md#0x0_deep_price_Price">deep_price::Price</a>&gt;</code>
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

<a name="0x0_deep_price_OrderDeepPrice"></a>

## Struct `OrderDeepPrice`



<pre><code><b>struct</b> <a href="deep_price.md#0x0_deep_price_OrderDeepPrice">OrderDeepPrice</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>asset_is_base: bool</code>
</dt>
<dd>

</dd>
<dt>
<code>deep_per_asset: u64</code>
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



<a name="0x0_deep_price_ENoDataPoints"></a>



<pre><code><b>const</b> <a href="deep_price.md#0x0_deep_price_ENoDataPoints">ENoDataPoints</a>: u64 = 2;
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
        base_prices: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
        cumulative_base: 0,
        quote_prices: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
        cumulative_quote: 0,
    }
}
</code></pre>



</details>

<a name="0x0_deep_price_new_order_deep_price"></a>

## Function `new_order_deep_price`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_new_order_deep_price">new_order_deep_price</a>(asset_is_base: bool, deep_per_asset: u64): <a href="deep_price.md#0x0_deep_price_OrderDeepPrice">deep_price::OrderDeepPrice</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="deep_price.md#0x0_deep_price_new_order_deep_price">new_order_deep_price</a>(
    asset_is_base: bool,
    deep_per_asset: u64,
): <a href="deep_price.md#0x0_deep_price_OrderDeepPrice">OrderDeepPrice</a> {
    <a href="deep_price.md#0x0_deep_price_OrderDeepPrice">OrderDeepPrice</a> {
        asset_is_base: asset_is_base,
        deep_per_asset: deep_per_asset,
    }
}
</code></pre>



</details>

<a name="0x0_deep_price_get_order_deep_price"></a>

## Function `get_order_deep_price`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_get_order_deep_price">get_order_deep_price</a>(self: &<a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>, whitelisted: bool): <a href="deep_price.md#0x0_deep_price_OrderDeepPrice">deep_price::OrderDeepPrice</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="deep_price.md#0x0_deep_price_get_order_deep_price">get_order_deep_price</a>(
    self: &<a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a>,
    whitelisted: bool,
): <a href="deep_price.md#0x0_deep_price_OrderDeepPrice">OrderDeepPrice</a> {
    <b>let</b> (asset_is_base, deep_per_asset) = self.<a href="deep_price.md#0x0_deep_price_calculate_order_deep_price">calculate_order_deep_price</a>(whitelisted);

    <a href="deep_price.md#0x0_deep_price_new_order_deep_price">new_order_deep_price</a>(asset_is_base, deep_per_asset)
}
</code></pre>



</details>

<a name="0x0_deep_price_deep_per_asset"></a>

## Function `deep_per_asset`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_deep_per_asset">deep_per_asset</a>(self: &<a href="deep_price.md#0x0_deep_price_OrderDeepPrice">deep_price::OrderDeepPrice</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="deep_price.md#0x0_deep_price_deep_per_asset">deep_per_asset</a>(
    self: &<a href="deep_price.md#0x0_deep_price_OrderDeepPrice">OrderDeepPrice</a>,
): u64 {
    self.deep_per_asset
}
</code></pre>



</details>

<a name="0x0_deep_price_asset_is_base"></a>

## Function `asset_is_base`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_asset_is_base">asset_is_base</a>(self: &<a href="deep_price.md#0x0_deep_price_OrderDeepPrice">deep_price::OrderDeepPrice</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="deep_price.md#0x0_deep_price_asset_is_base">asset_is_base</a>(
    self: &<a href="deep_price.md#0x0_deep_price_OrderDeepPrice">OrderDeepPrice</a>,
): bool {
    self.asset_is_base
}
</code></pre>



</details>

<a name="0x0_deep_price_quantity_in_deep"></a>

## Function `quantity_in_deep`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_quantity_in_deep">quantity_in_deep</a>(self: &<a href="deep_price.md#0x0_deep_price_OrderDeepPrice">deep_price::OrderDeepPrice</a>, base_quantity: u64, quote_quantity: u64, price: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="deep_price.md#0x0_deep_price_quantity_in_deep">quantity_in_deep</a>(
    self: &<a href="deep_price.md#0x0_deep_price_OrderDeepPrice">OrderDeepPrice</a>,
    base_quantity: u64,
    quote_quantity: u64,
    price: u64,
): u64 {
    <b>if</b> (self.asset_is_base) {
        math::mul(base_quantity, self.deep_per_asset)
    } <b>else</b> {
        math::mul(
            math::mul(quote_quantity, price),
            self.deep_per_asset
        )
    }
}
</code></pre>



</details>

<a name="0x0_deep_price_add_price_point"></a>

## Function `add_price_point`

Add a price point. If max data points are reached, the oldest data point is removed.
Remove all data points older than MAX_DATA_POINT_AGE_MS.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price_add_price_point">add_price_point</a>(self: &<b>mut</b> <a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>, conversion_rate: u64, timestamp: u64, is_base_conversion: bool)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="deep_price.md#0x0_deep_price_add_price_point">add_price_point</a>(
    self: &<b>mut</b> <a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a>,
    conversion_rate: u64,
    timestamp: u64,
    is_base_conversion: bool,
) {
    <b>assert</b>!(self.<a href="deep_price.md#0x0_deep_price_last_insert_timestamp">last_insert_timestamp</a>(is_base_conversion) + <a href="deep_price.md#0x0_deep_price_MIN_DURATION_BETWEEN_DATA_POINTS_MS">MIN_DURATION_BETWEEN_DATA_POINTS_MS</a> &lt; timestamp, <a href="deep_price.md#0x0_deep_price_EDataPointRecentlyAdded">EDataPointRecentlyAdded</a>);
    <b>let</b> asset_prices = <b>if</b> (is_base_conversion) {
        &<b>mut</b> self.base_prices
    } <b>else</b> {
        &<b>mut</b> self.quote_prices
    };

    asset_prices.push_back(<a href="deep_price.md#0x0_deep_price_Price">Price</a> {
        timestamp: timestamp,
        conversion_rate: conversion_rate,
    });
    <b>if</b> (is_base_conversion) {
        self.cumulative_base = self.cumulative_base + conversion_rate;
        <b>while</b> (
            asset_prices.length() == <a href="deep_price.md#0x0_deep_price_MAX_DATA_POINTS">MAX_DATA_POINTS</a> + 1 ||
            asset_prices[0].timestamp + <a href="deep_price.md#0x0_deep_price_MAX_DATA_POINT_AGE_MS">MAX_DATA_POINT_AGE_MS</a> &lt; timestamp
        ) {
            self.cumulative_base = self.cumulative_base - asset_prices[0].conversion_rate;
            asset_prices.remove(0);
        }
    } <b>else</b> {
        self.cumulative_quote = self.cumulative_quote + conversion_rate;
        <b>while</b> (
            asset_prices.length() == <a href="deep_price.md#0x0_deep_price_MAX_DATA_POINTS">MAX_DATA_POINTS</a> + 1 ||
            asset_prices[0].timestamp + <a href="deep_price.md#0x0_deep_price_MAX_DATA_POINT_AGE_MS">MAX_DATA_POINT_AGE_MS</a> &lt; timestamp
        ) {
            self.cumulative_quote = self.cumulative_quote - asset_prices[0].conversion_rate;
            asset_prices.remove(0);
        }
    };
}
</code></pre>



</details>

<a name="0x0_deep_price_calculate_order_deep_price"></a>

## Function `calculate_order_deep_price`

Returns the conversion rate of DEEP per asset token.
Base will be used by default, if there are no base data then quote will be used


<pre><code><b>fun</b> <a href="deep_price.md#0x0_deep_price_calculate_order_deep_price">calculate_order_deep_price</a>(self: &<a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>, whitelisted: bool): (bool, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="deep_price.md#0x0_deep_price_calculate_order_deep_price">calculate_order_deep_price</a>(
    self: &<a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a>,
    whitelisted: bool,
): (bool, u64) {
    <b>if</b> (whitelisted) {
        <b>return</b> (<b>false</b>, 0) // no fees for whitelist
    };
    <b>assert</b>!(self.<a href="deep_price.md#0x0_deep_price_last_insert_timestamp">last_insert_timestamp</a>(<b>true</b>) &gt; 0 || self.<a href="deep_price.md#0x0_deep_price_last_insert_timestamp">last_insert_timestamp</a>(<b>false</b>) &gt; 0, <a href="deep_price.md#0x0_deep_price_ENoDataPoints">ENoDataPoints</a>);

    <b>let</b> is_base_conversion = self.<a href="deep_price.md#0x0_deep_price_last_insert_timestamp">last_insert_timestamp</a>(<b>true</b>) &gt; 0;

    <b>let</b> cumulative_asset = <b>if</b> (is_base_conversion) {
        self.cumulative_base
    } <b>else</b> {
        self.cumulative_quote
    };
    <b>let</b> asset_length = <b>if</b> (is_base_conversion) {
        self.base_prices.length()
    } <b>else</b> {
        self.quote_prices.length()
    };
    <b>let</b> deep_per_asset = cumulative_asset / asset_length;

    (is_base_conversion, deep_per_asset)
}
</code></pre>



</details>

<a name="0x0_deep_price_last_insert_timestamp"></a>

## Function `last_insert_timestamp`



<pre><code><b>fun</b> <a href="deep_price.md#0x0_deep_price_last_insert_timestamp">last_insert_timestamp</a>(self: &<a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>, is_base_conversion: bool): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="deep_price.md#0x0_deep_price_last_insert_timestamp">last_insert_timestamp</a>(
    self: &<a href="deep_price.md#0x0_deep_price_DeepPrice">DeepPrice</a>,
    is_base_conversion: bool,
): u64 {
    <b>let</b> prices = <b>if</b> (is_base_conversion) {
        &self.base_prices
    } <b>else</b> {
        &self.quote_prices
    };
    <b>if</b> (prices.length() &gt; 0) {
        prices[prices.length() - 1].timestamp
    } <b>else</b> {
        0
    }
}
</code></pre>



</details>
