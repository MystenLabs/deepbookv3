
<a name="0x0_registry"></a>

# Module `0x0::registry`



-  [Struct `REGISTRY`](#0x0_registry_REGISTRY)
-  [Resource `DeepbookAdminCap`](#0x0_registry_DeepbookAdminCap)
-  [Resource `Registry`](#0x0_registry_Registry)
-  [Struct `PoolKey`](#0x0_registry_PoolKey)
-  [Constants](#@Constants_0)
-  [Function `register_pool`](#0x0_registry_register_pool)
-  [Function `init`](#0x0_registry_init)


<pre><code><b>use</b> <a href="dependencies/move-stdlib/type_name.md#0x1_type_name">0x1::type_name</a>;
<b>use</b> <a href="dependencies/sui-framework/bag.md#0x2_bag">0x2::bag</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
<b>use</b> <a href="dependencies/sui-framework/transfer.md#0x2_transfer">0x2::transfer</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
</code></pre>



<a name="0x0_registry_REGISTRY"></a>

## Struct `REGISTRY`



<pre><code><b>struct</b> <a href="registry.md#0x0_registry_REGISTRY">REGISTRY</a> <b>has</b> drop
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>dummy_field: bool</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_registry_DeepbookAdminCap"></a>

## Resource `DeepbookAdminCap`

DeepbookAdminCap is used to call admin functions.


<pre><code><b>struct</b> <a href="registry.md#0x0_registry_DeepbookAdminCap">DeepbookAdminCap</a> <b>has</b> store, key
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>id: <a href="dependencies/sui-framework/object.md#0x2_object_UID">object::UID</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_registry_Registry"></a>

## Resource `Registry`



<pre><code><b>struct</b> <a href="registry.md#0x0_registry_Registry">Registry</a> <b>has</b> store, key
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
<code>pools: <a href="dependencies/sui-framework/bag.md#0x2_bag_Bag">bag::Bag</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_registry_PoolKey"></a>

## Struct `PoolKey`



<pre><code><b>struct</b> <a href="registry.md#0x0_registry_PoolKey">PoolKey</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>base: <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_TypeName">type_name::TypeName</a></code>
</dt>
<dd>

</dd>
<dt>
<code>quote: <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_TypeName">type_name::TypeName</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_registry_EPoolAlreadyExists"></a>



<pre><code><b>const</b> <a href="registry.md#0x0_registry_EPoolAlreadyExists">EPoolAlreadyExists</a>: u64 = 1;
</code></pre>



<a name="0x0_registry_register_pool"></a>

## Function `register_pool`

Register a new pool in the registry.
Asserts if (Base, Quote) pool already exists or (Quote, Base) pool already exists.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="registry.md#0x0_registry_register_pool">register_pool</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="registry.md#0x0_registry_Registry">registry::Registry</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="registry.md#0x0_registry_register_pool">register_pool</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="registry.md#0x0_registry_Registry">Registry</a>,
) {
    <b>let</b> key = <a href="registry.md#0x0_registry_PoolKey">PoolKey</a> {
        base: <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;QuoteAsset&gt;(),
        quote: <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;BaseAsset&gt;(),
    };
    <b>assert</b>!(!self.pools.contains(key), <a href="registry.md#0x0_registry_EPoolAlreadyExists">EPoolAlreadyExists</a>);

    <b>let</b> key = <a href="registry.md#0x0_registry_PoolKey">PoolKey</a> {
        base: <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;BaseAsset&gt;(),
        quote: <a href="dependencies/move-stdlib/type_name.md#0x1_type_name_get">type_name::get</a>&lt;QuoteAsset&gt;(),
    };
    <b>assert</b>!(!self.pools.contains(key), <a href="registry.md#0x0_registry_EPoolAlreadyExists">EPoolAlreadyExists</a>);

    self.pools.add(key, <b>true</b>);
}
</code></pre>



</details>

<a name="0x0_registry_init"></a>

## Function `init`



<pre><code><b>fun</b> <a href="registry.md#0x0_registry_init">init</a>(_: <a href="registry.md#0x0_registry_REGISTRY">registry::REGISTRY</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="registry.md#0x0_registry_init">init</a>(_: <a href="registry.md#0x0_registry_REGISTRY">REGISTRY</a>, ctx: &<b>mut</b> TxContext) {
    <b>let</b> <a href="registry.md#0x0_registry">registry</a> = <a href="registry.md#0x0_registry_Registry">Registry</a> {
        id: <a href="dependencies/sui-framework/object.md#0x2_object_new">object::new</a>(ctx),
        pools: <a href="dependencies/sui-framework/bag.md#0x2_bag_new">bag::new</a>(ctx),
    };
    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_share_object">transfer::share_object</a>(<a href="registry.md#0x0_registry">registry</a>);
    <b>let</b> admin = <a href="registry.md#0x0_registry_DeepbookAdminCap">DeepbookAdminCap</a> {
        id: <a href="dependencies/sui-framework/object.md#0x2_object_new">object::new</a>(ctx),
    };
    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_public_transfer">transfer::public_transfer</a>(admin, ctx.sender());
}
</code></pre>



</details>
