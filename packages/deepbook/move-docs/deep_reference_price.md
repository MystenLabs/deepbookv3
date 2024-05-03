
<a name="0x0_deep_reference_price"></a>

# Module `0x0::deep_reference_price`

The deep_reference_price module provides the functionality to add DEEP reference pools
and calculate the conversion rates between the DEEP token and any other token pair.


-  [Struct `DeepReferencePools`](#0x0_deep_reference_price_DeepReferencePools)
-  [Constants](#@Constants_0)
-  [Function `new`](#0x0_deep_reference_price_new)
-  [Function `add_reference_pool`](#0x0_deep_reference_price_add_reference_pool)
-  [Function `get_conversion_rates`](#0x0_deep_reference_price_get_conversion_rates)


<pre><code><b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="pool.md#0x0_pool">0x0::pool</a>;
<b>use</b> <a href="dependencies/move-stdlib/ascii.md#0x1_ascii">0x1::ascii</a>;
<b>use</b> <a href="dependencies/move-stdlib/type_name.md#0x1_type_name">0x1::type_name</a>;
<b>use</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">0x1::vector</a>;
</code></pre>



<a name="0x0_deep_reference_price_DeepReferencePools"></a>

## Struct `DeepReferencePools`

DeepReferencePools is a struct that holds the reference pools for the DEEP token.
DEEP/SUI, DEEP/USDC, DEEP/WETH


<pre><code><b>struct</b> <a href="deep_reference_price.md#0x0_deep_reference_price_DeepReferencePools">DeepReferencePools</a> <b>has</b> store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>reference_pools: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="dependencies/move-stdlib/ascii.md#0x1_ascii_String">ascii::String</a>&gt;</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_deep_reference_price_EIneligiblePool"></a>



<pre><code><b>const</b> <a href="deep_reference_price.md#0x0_deep_reference_price_EIneligiblePool">EIneligiblePool</a>: u64 = 1;
</code></pre>



<a name="0x0_deep_reference_price_new"></a>

## Function `new`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_reference_price.md#0x0_deep_reference_price_new">new</a>(): <a href="deep_reference_price.md#0x0_deep_reference_price_DeepReferencePools">deep_reference_price::DeepReferencePools</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="deep_reference_price.md#0x0_deep_reference_price_new">new</a>(): <a href="deep_reference_price.md#0x0_deep_reference_price_DeepReferencePools">DeepReferencePools</a> {
    <a href="deep_reference_price.md#0x0_deep_reference_price_DeepReferencePools">DeepReferencePools</a> {
        reference_pools: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
    }
}
</code></pre>



</details>

<a name="0x0_deep_reference_price_add_reference_pool"></a>

## Function `add_reference_pool`

Add a reference pool.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_reference_price.md#0x0_deep_reference_price_add_reference_pool">add_reference_pool</a>&lt;DEEP, QuoteAsset&gt;(self: &<b>mut</b> <a href="deep_reference_price.md#0x0_deep_reference_price_DeepReferencePools">deep_reference_price::DeepReferencePools</a>, <a href="pool.md#0x0_pool">pool</a>: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;DEEP, QuoteAsset&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="deep_reference_price.md#0x0_deep_reference_price_add_reference_pool">add_reference_pool</a>&lt;DEEP, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="deep_reference_price.md#0x0_deep_reference_price_DeepReferencePools">DeepReferencePools</a>,
    <a href="pool.md#0x0_pool">pool</a>: &Pool&lt;DEEP, QuoteAsset&gt;,
) {
    <b>let</b> (base, quote) = <a href="pool.md#0x0_pool">pool</a>.get_base_quote_types();
    <b>let</b> deep_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;DEEP&gt;().into_string();

    <b>assert</b>!(base == deep_type || quote == deep_type, <a href="deep_reference_price.md#0x0_deep_reference_price_EIneligiblePool">EIneligiblePool</a>);

    self.reference_pools.push_back(<a href="pool.md#0x0_pool">pool</a>.key());
}
</code></pre>



</details>

<a name="0x0_deep_reference_price_get_conversion_rates"></a>

## Function `get_conversion_rates`

Calculate the conversion rate between the DEEP token and the base and quote assets of a pool.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_reference_price.md#0x0_deep_reference_price_get_conversion_rates">get_conversion_rates</a>&lt;BaseAsset, QuoteAsset, DEEPQuoteAsset&gt;(self: &<a href="deep_reference_price.md#0x0_deep_reference_price_DeepReferencePools">deep_reference_price::DeepReferencePools</a>, <a href="pool.md#0x0_pool">pool</a>: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, deep_pool: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;<a href="pool.md#0x0_pool_DEEP">pool::DEEP</a>, DEEPQuoteAsset&gt;): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="deep_reference_price.md#0x0_deep_reference_price_get_conversion_rates">get_conversion_rates</a>&lt;BaseAsset, QuoteAsset, DEEPQuoteAsset&gt;(
    self: &<a href="deep_reference_price.md#0x0_deep_reference_price_DeepReferencePools">DeepReferencePools</a>,
    <a href="pool.md#0x0_pool">pool</a>: &Pool&lt;BaseAsset, QuoteAsset&gt;,
    deep_pool: &Pool&lt;DEEP, DEEPQuoteAsset&gt;,
): (u64, u64) {
    <b>let</b> (base, quote) = <a href="pool.md#0x0_pool">pool</a>.get_base_quote_types();
    <b>let</b> deep_quote_type = <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;DEEPQuoteAsset&gt;().into_string();
    <b>assert</b>!(self.reference_pools.contains(&deep_pool.key()), <a href="deep_reference_price.md#0x0_deep_reference_price_EIneligiblePool">EIneligiblePool</a>);
    <b>assert</b>!(base == deep_quote_type || quote == deep_quote_type, <a href="deep_reference_price.md#0x0_deep_reference_price_EIneligiblePool">EIneligiblePool</a>);

    <b>let</b> <a href="deep_price.md#0x0_deep_price">deep_price</a> = deep_pool.mid_price();
    <b>let</b> pool_price = <a href="pool.md#0x0_pool">pool</a>.mid_price();

    <b>if</b> (base == deep_quote_type) {
        (<a href="deep_price.md#0x0_deep_price">deep_price</a>, math::div(<a href="deep_price.md#0x0_deep_price">deep_price</a>, pool_price))
    } <b>else</b> {
        (math::div(<a href="deep_price.md#0x0_deep_price">deep_price</a>, pool_price), <a href="deep_price.md#0x0_deep_price">deep_price</a>)
    }
}
</code></pre>



</details>
