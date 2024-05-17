
<a name="0x0_balances"></a>

# Module `0x0::balances`



-  [Struct `Balances`](#0x0_balances_Balances)
-  [Function `empty`](#0x0_balances_empty)
-  [Function `new`](#0x0_balances_new)
-  [Function `reset`](#0x0_balances_reset)
-  [Function `add_balances`](#0x0_balances_add_balances)
-  [Function `add_base`](#0x0_balances_add_base)
-  [Function `add_quote`](#0x0_balances_add_quote)
-  [Function `add_deep`](#0x0_balances_add_deep)
-  [Function `base`](#0x0_balances_base)
-  [Function `quote`](#0x0_balances_quote)
-  [Function `deep`](#0x0_balances_deep)


<pre><code></code></pre>



<a name="0x0_balances_Balances"></a>

## Struct `Balances`



<pre><code><b>struct</b> <a href="balances.md#0x0_balances_Balances">Balances</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>base: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>quote: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>deep: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_balances_empty"></a>

## Function `empty`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balances.md#0x0_balances_empty">empty</a>(): <a href="balances.md#0x0_balances_Balances">balances::Balances</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balances.md#0x0_balances_empty">empty</a>(): <a href="balances.md#0x0_balances_Balances">Balances</a> {
    <a href="balances.md#0x0_balances_Balances">Balances</a> {
        base: 0,
        quote: 0,
        deep: 0,
    }
}
</code></pre>



</details>

<a name="0x0_balances_new"></a>

## Function `new`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balances.md#0x0_balances_new">new</a>(base: u64, quote: u64, deep: u64): <a href="balances.md#0x0_balances_Balances">balances::Balances</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balances.md#0x0_balances_new">new</a>(base: u64, quote: u64, deep: u64): <a href="balances.md#0x0_balances_Balances">Balances</a> {
    <a href="balances.md#0x0_balances_Balances">Balances</a> {
        base: base,
        quote: quote,
        deep: deep,
    }
}
</code></pre>



</details>

<a name="0x0_balances_reset"></a>

## Function `reset`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balances.md#0x0_balances_reset">reset</a>(<a href="balances.md#0x0_balances">balances</a>: &<b>mut</b> <a href="balances.md#0x0_balances_Balances">balances::Balances</a>): <a href="balances.md#0x0_balances_Balances">balances::Balances</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balances.md#0x0_balances_reset">reset</a>(<a href="balances.md#0x0_balances">balances</a>: &<b>mut</b> <a href="balances.md#0x0_balances_Balances">Balances</a>): <a href="balances.md#0x0_balances_Balances">Balances</a> {
    <b>let</b> <b>old</b> = *<a href="balances.md#0x0_balances">balances</a>;
    <a href="balances.md#0x0_balances">balances</a>.base = 0;
    <a href="balances.md#0x0_balances">balances</a>.quote = 0;
    <a href="balances.md#0x0_balances">balances</a>.deep = 0;

    <b>old</b>
}
</code></pre>



</details>

<a name="0x0_balances_add_balances"></a>

## Function `add_balances`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balances.md#0x0_balances_add_balances">add_balances</a>(<a href="balances.md#0x0_balances">balances</a>: &<b>mut</b> <a href="balances.md#0x0_balances_Balances">balances::Balances</a>, other: <a href="balances.md#0x0_balances_Balances">balances::Balances</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balances.md#0x0_balances_add_balances">add_balances</a>(<a href="balances.md#0x0_balances">balances</a>: &<b>mut</b> <a href="balances.md#0x0_balances_Balances">Balances</a>, other: <a href="balances.md#0x0_balances_Balances">Balances</a>) {
    <a href="balances.md#0x0_balances">balances</a>.base = <a href="balances.md#0x0_balances">balances</a>.base + other.base;
    <a href="balances.md#0x0_balances">balances</a>.quote = <a href="balances.md#0x0_balances">balances</a>.quote + other.quote;
    <a href="balances.md#0x0_balances">balances</a>.deep = <a href="balances.md#0x0_balances">balances</a>.deep + other.deep;
}
</code></pre>



</details>

<a name="0x0_balances_add_base"></a>

## Function `add_base`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balances.md#0x0_balances_add_base">add_base</a>(<a href="balances.md#0x0_balances">balances</a>: &<b>mut</b> <a href="balances.md#0x0_balances_Balances">balances::Balances</a>, base: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balances.md#0x0_balances_add_base">add_base</a>(<a href="balances.md#0x0_balances">balances</a>: &<b>mut</b> <a href="balances.md#0x0_balances_Balances">Balances</a>, base: u64) {
    <a href="balances.md#0x0_balances">balances</a>.base = <a href="balances.md#0x0_balances">balances</a>.base + base;
}
</code></pre>



</details>

<a name="0x0_balances_add_quote"></a>

## Function `add_quote`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balances.md#0x0_balances_add_quote">add_quote</a>(<a href="balances.md#0x0_balances">balances</a>: &<b>mut</b> <a href="balances.md#0x0_balances_Balances">balances::Balances</a>, quote: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balances.md#0x0_balances_add_quote">add_quote</a>(<a href="balances.md#0x0_balances">balances</a>: &<b>mut</b> <a href="balances.md#0x0_balances_Balances">Balances</a>, quote: u64) {
    <a href="balances.md#0x0_balances">balances</a>.quote = <a href="balances.md#0x0_balances">balances</a>.quote + quote;
}
</code></pre>



</details>

<a name="0x0_balances_add_deep"></a>

## Function `add_deep`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balances.md#0x0_balances_add_deep">add_deep</a>(<a href="balances.md#0x0_balances">balances</a>: &<b>mut</b> <a href="balances.md#0x0_balances_Balances">balances::Balances</a>, deep: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balances.md#0x0_balances_add_deep">add_deep</a>(<a href="balances.md#0x0_balances">balances</a>: &<b>mut</b> <a href="balances.md#0x0_balances_Balances">Balances</a>, deep: u64) {
    <a href="balances.md#0x0_balances">balances</a>.deep = <a href="balances.md#0x0_balances">balances</a>.deep + deep;
}
</code></pre>



</details>

<a name="0x0_balances_base"></a>

## Function `base`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balances.md#0x0_balances_base">base</a>(<a href="balances.md#0x0_balances">balances</a>: &<a href="balances.md#0x0_balances_Balances">balances::Balances</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balances.md#0x0_balances_base">base</a>(<a href="balances.md#0x0_balances">balances</a>: &<a href="balances.md#0x0_balances_Balances">Balances</a>): u64 {
    <a href="balances.md#0x0_balances">balances</a>.base
}
</code></pre>



</details>

<a name="0x0_balances_quote"></a>

## Function `quote`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balances.md#0x0_balances_quote">quote</a>(<a href="balances.md#0x0_balances">balances</a>: &<a href="balances.md#0x0_balances_Balances">balances::Balances</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balances.md#0x0_balances_quote">quote</a>(<a href="balances.md#0x0_balances">balances</a>: &<a href="balances.md#0x0_balances_Balances">Balances</a>): u64 {
    <a href="balances.md#0x0_balances">balances</a>.quote
}
</code></pre>



</details>

<a name="0x0_balances_deep"></a>

## Function `deep`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="balances.md#0x0_balances_deep">deep</a>(<a href="balances.md#0x0_balances">balances</a>: &<a href="balances.md#0x0_balances_Balances">balances::Balances</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="balances.md#0x0_balances_deep">deep</a>(<a href="balances.md#0x0_balances">balances</a>: &<a href="balances.md#0x0_balances_Balances">Balances</a>): u64 {
    <a href="balances.md#0x0_balances">balances</a>.deep
}
</code></pre>



</details>
