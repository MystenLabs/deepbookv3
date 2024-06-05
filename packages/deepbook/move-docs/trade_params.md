
<a name="0x0_trade_params"></a>

# Module `0x0::trade_params`



-  [Struct `TradeParams`](#0x0_trade_params_TradeParams)
-  [Function `new`](#0x0_trade_params_new)
-  [Function `maker_fee`](#0x0_trade_params_maker_fee)
-  [Function `taker_fee`](#0x0_trade_params_taker_fee)
-  [Function `taker_fee_for_user`](#0x0_trade_params_taker_fee_for_user)
-  [Function `stake_required`](#0x0_trade_params_stake_required)


<pre><code></code></pre>



<a name="0x0_trade_params_TradeParams"></a>

## Struct `TradeParams`



<pre><code><b>struct</b> <a href="trade_params.md#0x0_trade_params_TradeParams">TradeParams</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>taker_fee: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>maker_fee: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>stake_required: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_trade_params_new"></a>

## Function `new`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="trade_params.md#0x0_trade_params_new">new</a>(taker_fee: u64, maker_fee: u64, stake_required: u64): <a href="trade_params.md#0x0_trade_params_TradeParams">trade_params::TradeParams</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="trade_params.md#0x0_trade_params_new">new</a>(
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
): <a href="trade_params.md#0x0_trade_params_TradeParams">TradeParams</a> {
    <a href="trade_params.md#0x0_trade_params_TradeParams">TradeParams</a> {
        taker_fee,
        maker_fee,
        stake_required,
    }
}
</code></pre>



</details>

<a name="0x0_trade_params_maker_fee"></a>

## Function `maker_fee`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="trade_params.md#0x0_trade_params_maker_fee">maker_fee</a>(<a href="trade_params.md#0x0_trade_params">trade_params</a>: &<a href="trade_params.md#0x0_trade_params_TradeParams">trade_params::TradeParams</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="trade_params.md#0x0_trade_params_maker_fee">maker_fee</a>(<a href="trade_params.md#0x0_trade_params">trade_params</a>: &<a href="trade_params.md#0x0_trade_params_TradeParams">TradeParams</a>): u64 {
    <a href="trade_params.md#0x0_trade_params">trade_params</a>.maker_fee
}
</code></pre>



</details>

<a name="0x0_trade_params_taker_fee"></a>

## Function `taker_fee`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="trade_params.md#0x0_trade_params_taker_fee">taker_fee</a>(<a href="trade_params.md#0x0_trade_params">trade_params</a>: &<a href="trade_params.md#0x0_trade_params_TradeParams">trade_params::TradeParams</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="trade_params.md#0x0_trade_params_taker_fee">taker_fee</a>(<a href="trade_params.md#0x0_trade_params">trade_params</a>: &<a href="trade_params.md#0x0_trade_params_TradeParams">TradeParams</a>): u64 {
    <a href="trade_params.md#0x0_trade_params">trade_params</a>.taker_fee
}
</code></pre>



</details>

<a name="0x0_trade_params_taker_fee_for_user"></a>

## Function `taker_fee_for_user`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="trade_params.md#0x0_trade_params_taker_fee_for_user">taker_fee_for_user</a>(self: &<a href="trade_params.md#0x0_trade_params_TradeParams">trade_params::TradeParams</a>, active_stake: u64, volume_in_deep: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="trade_params.md#0x0_trade_params_taker_fee_for_user">taker_fee_for_user</a>(self: &<a href="trade_params.md#0x0_trade_params_TradeParams">TradeParams</a>, active_stake: u64, volume_in_deep: u64): u64 {
    <b>if</b> (active_stake &gt;= self.stake_required && volume_in_deep &gt;= self.stake_required) {
        self.taker_fee / 2
    } <b>else</b> {
        self.taker_fee
    }
}
</code></pre>



</details>

<a name="0x0_trade_params_stake_required"></a>

## Function `stake_required`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="trade_params.md#0x0_trade_params_stake_required">stake_required</a>(<a href="trade_params.md#0x0_trade_params">trade_params</a>: &<a href="trade_params.md#0x0_trade_params_TradeParams">trade_params::TradeParams</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="trade_params.md#0x0_trade_params_stake_required">stake_required</a>(<a href="trade_params.md#0x0_trade_params">trade_params</a>: &<a href="trade_params.md#0x0_trade_params_TradeParams">TradeParams</a>): u64 {
    <a href="trade_params.md#0x0_trade_params">trade_params</a>.stake_required
}
</code></pre>



</details>
