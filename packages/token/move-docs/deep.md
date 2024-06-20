
<a name="0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep"></a>

# Module `0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep`



-  [Struct `DEEP`](#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP)
-  [Resource `ProtectedTreasury`](#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury)
-  [Struct `TreasuryCapKey`](#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_TreasuryCapKey)
-  [Function `burn`](#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_burn)
-  [Function `total_supply`](#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_total_supply)
-  [Function `borrow_cap`](#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_borrow_cap)
-  [Function `borrow_cap_mut`](#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_borrow_cap_mut)
-  [Function `create_coin`](#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_create_coin)
-  [Function `init`](#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_init)


<pre><code><b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
<b>use</b> <a href="dependencies/sui-framework/coin.md#0x2_coin">0x2::coin</a>;
<b>use</b> <a href="dependencies/sui-framework/dynamic_object_field.md#0x2_dynamic_object_field">0x2::dynamic_object_field</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
<b>use</b> <a href="dependencies/sui-framework/transfer.md#0x2_transfer">0x2::transfer</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
<b>use</b> <a href="dependencies/sui-framework/url.md#0x2_url">0x2::url</a>;
</code></pre>



<a name="0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP"></a>

## Struct `DEEP`



<pre><code><b>struct</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a> <b>has</b> drop
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

<a name="0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury"></a>

## Resource `ProtectedTreasury`



<pre><code><b>struct</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury">ProtectedTreasury</a> <b>has</b> key
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

<a name="0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_TreasuryCapKey"></a>

## Struct `TreasuryCapKey`



<pre><code><b>struct</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_TreasuryCapKey">TreasuryCapKey</a> <b>has</b> <b>copy</b>, drop, store
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

<a name="0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_burn"></a>

## Function `burn`



<pre><code><b>public</b> <b>fun</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_burn">burn</a>(arg0: &<b>mut</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury">deep::ProtectedTreasury</a>, arg1: <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_burn">burn</a>(arg0: &<b>mut</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury">ProtectedTreasury</a>, arg1: sui::coin::Coin&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>&gt;) {
    sui::coin::burn&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>&gt;(<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_borrow_cap_mut">borrow_cap_mut</a>(arg0), arg1);
}
</code></pre>



</details>

<a name="0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_total_supply"></a>

## Function `total_supply`



<pre><code><b>public</b> <b>fun</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_total_supply">total_supply</a>(arg0: &<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury">deep::ProtectedTreasury</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_total_supply">total_supply</a>(arg0: &<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury">ProtectedTreasury</a>) : u64 {
    sui::coin::total_supply&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>&gt;(<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_borrow_cap">borrow_cap</a>(arg0))
}
</code></pre>



</details>

<a name="0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_borrow_cap"></a>

## Function `borrow_cap`



<pre><code><b>fun</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_borrow_cap">borrow_cap</a>(arg0: &<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury">deep::ProtectedTreasury</a>): &<a href="dependencies/sui-framework/coin.md#0x2_coin_TreasuryCap">coin::TreasuryCap</a>&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_borrow_cap">borrow_cap</a>(arg0: &<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury">ProtectedTreasury</a>): &sui::coin::TreasuryCap&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>&gt; {
    <b>let</b> v0 = <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_TreasuryCapKey">TreasuryCapKey</a> {};
    sui::dynamic_object_field::borrow&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_TreasuryCapKey">TreasuryCapKey</a>, sui::coin::TreasuryCap&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>&gt;&gt;(&arg0.id, v0)
}
</code></pre>



</details>

<a name="0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_borrow_cap_mut"></a>

## Function `borrow_cap_mut`



<pre><code><b>fun</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_borrow_cap_mut">borrow_cap_mut</a>(arg0: &<b>mut</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury">deep::ProtectedTreasury</a>): &<b>mut</b> <a href="dependencies/sui-framework/coin.md#0x2_coin_TreasuryCap">coin::TreasuryCap</a>&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_borrow_cap_mut">borrow_cap_mut</a>(arg0: &<b>mut</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury">ProtectedTreasury</a>) : &<b>mut</b> sui::coin::TreasuryCap&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>&gt; {
    <b>let</b> v0 = <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_TreasuryCapKey">TreasuryCapKey</a> {};
    sui::dynamic_object_field::borrow_mut&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_TreasuryCapKey">TreasuryCapKey</a>, sui::coin::TreasuryCap&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>&gt;&gt;(&<b>mut</b> arg0.id, v0)
}
</code></pre>



</details>

<a name="0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_create_coin"></a>

## Function `create_coin`



<pre><code><b>fun</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_create_coin">create_coin</a>(arg0: <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>, arg1: u64, arg2: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury">deep::ProtectedTreasury</a>, <a href="dependencies/sui-framework/coin.md#0x2_coin_Coin">coin::Coin</a>&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_create_coin">create_coin</a>(arg0: <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>, arg1: u64, arg2: &<b>mut</b> sui::tx_context::TxContext) : (<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury">ProtectedTreasury</a>, sui::coin::Coin&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>&gt;) {
    <b>let</b> (v0, v1) = sui::coin::create_currency&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>&gt;(
        arg0,
        6,
        b"<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>",
        b"DeepBook Token",
        b"The <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a> token secures the DeepBook protocol, the premier wholesale liquidity venue for on-chain trading.",
        std::option::some&lt;sui::url::Url&gt;(sui::url::new_unsafe_from_bytes(b"https://images.deepbook.tech/icon.svg")),
        arg2
    );
    <b>let</b> <b>mut</b> cap = v0;
    sui::transfer::public_freeze_object&lt;sui::coin::CoinMetadata&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>&gt;&gt;(v1);
    <b>let</b> <b>mut</b> protected_treasury = <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury">ProtectedTreasury</a> { id: sui::object::new(arg2) };

    <b>let</b> <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a> = sui::coin::mint&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>&gt;(&<b>mut</b> cap, arg1, arg2);
    sui::dynamic_object_field::add&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_TreasuryCapKey">TreasuryCapKey</a>, sui::coin::TreasuryCap&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>&gt;&gt;(&<b>mut</b> protected_treasury.id, <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_TreasuryCapKey">TreasuryCapKey</a> {}, cap);

    (protected_treasury, <a href="dependencies/sui-framework/coin.md#0x2_coin">coin</a>)
}
</code></pre>



</details>

<a name="0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_init"></a>

## Function `init`



<pre><code><b>fun</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_init">init</a>(arg0: <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">deep::DEEP</a>, arg1: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_init">init</a>(arg0: <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>, arg1: &<b>mut</b> TxContext) {
    <b>let</b> (v0, v1) = <a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_create_coin">create_coin</a>(arg0, 10000000000000000, arg1);
    sui::transfer::share_object&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_ProtectedTreasury">ProtectedTreasury</a>&gt;(v0);
    sui::transfer::public_transfer&lt;sui::coin::Coin&lt;<a href="deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep_DEEP">DEEP</a>&gt;&gt;(v1, sui::tx_context::sender(arg1));
}
</code></pre>



</details>
