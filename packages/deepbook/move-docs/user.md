
<a name="0x0_user"></a>

# Module `0x0::user`



-  [Struct `Balances`](#0x0_user_Balances)
-  [Struct `User`](#0x0_user_User)
-  [Function `empty`](#0x0_user_empty)
-  [Function `active_stake`](#0x0_user_active_stake)
-  [Function `maker_volume`](#0x0_user_maker_volume)
-  [Function `set_voted_proposal`](#0x0_user_set_voted_proposal)
-  [Function `add_settled_amounts`](#0x0_user_add_settled_amounts)
-  [Function `add_owed_amounts`](#0x0_user_add_owed_amounts)
-  [Function `settle`](#0x0_user_settle)
-  [Function `update`](#0x0_user_update)
-  [Function `add_rebates`](#0x0_user_add_rebates)
-  [Function `claim_rebates`](#0x0_user_claim_rebates)
-  [Function `add_order`](#0x0_user_add_order)
-  [Function `remove_order`](#0x0_user_remove_order)
-  [Function `add_stake`](#0x0_user_add_stake)
-  [Function `remove_stake`](#0x0_user_remove_stake)
-  [Function `open_orders`](#0x0_user_open_orders)
-  [Function `reset`](#0x0_user_reset)


<pre><code><b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
<b>use</b> <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set">0x2::vec_set</a>;
</code></pre>



<a name="0x0_user_Balances"></a>

## Struct `Balances`



<pre><code><b>struct</b> <a href="user.md#0x0_user_Balances">Balances</a> <b>has</b> <b>copy</b>, drop, store
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

<a name="0x0_user_User"></a>

## Struct `User`

User data that is updated every epoch.


<pre><code><b>struct</b> <a href="user.md#0x0_user_User">User</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>epoch: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>open_orders: <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set_VecSet">vec_set::VecSet</a>&lt;u128&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>maker_volume: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>active_stake: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>inactive_stake: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>voted_proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<b>address</b>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>unclaimed_rebates: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>settled_balances: <a href="user.md#0x0_user_Balances">user::Balances</a></code>
</dt>
<dd>

</dd>
<dt>
<code>owed_balances: <a href="user.md#0x0_user_Balances">user::Balances</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_user_empty"></a>

## Function `empty`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user_empty">empty</a>(epoch: u64): <a href="user.md#0x0_user_User">user::User</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user_empty">empty</a>(
    epoch: u64,
): <a href="user.md#0x0_user_User">User</a> {
    <a href="user.md#0x0_user_User">User</a> {
        epoch,
        open_orders: <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set_empty">vec_set::empty</a>(),
        maker_volume: 0,
        active_stake: 0,
        inactive_stake: 0,
        voted_proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(),
        unclaimed_rebates: 0,
        settled_balances: <a href="user.md#0x0_user_Balances">Balances</a> {
            base: 0,
            quote: 0,
            deep: 0,
        },
        owed_balances: <a href="user.md#0x0_user_Balances">Balances</a> {
            base: 0,
            quote: 0,
            deep: 0,
        },
    }
}
</code></pre>



</details>

<a name="0x0_user_active_stake"></a>

## Function `active_stake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user_active_stake">active_stake</a>(self: &<a href="user.md#0x0_user_User">user::User</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user_active_stake">active_stake</a>(
    self: &<a href="user.md#0x0_user_User">User</a>,
): u64 {
    self.active_stake
}
</code></pre>



</details>

<a name="0x0_user_maker_volume"></a>

## Function `maker_volume`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user_maker_volume">maker_volume</a>(self: &<a href="user.md#0x0_user_User">user::User</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user_maker_volume">maker_volume</a>(
    self: &<a href="user.md#0x0_user_User">User</a>,
): u64 {
    self.maker_volume
}
</code></pre>



</details>

<a name="0x0_user_set_voted_proposal"></a>

## Function `set_voted_proposal`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user_set_voted_proposal">set_voted_proposal</a>(self: &<b>mut</b> <a href="user.md#0x0_user_User">user::User</a>, proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<b>address</b>&gt;): <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<b>address</b>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user_set_voted_proposal">set_voted_proposal</a>(
    self: &<b>mut</b> <a href="user.md#0x0_user_User">User</a>,
    proposal: Option&lt;<b>address</b>&gt;
): Option&lt;<b>address</b>&gt; {
    <b>let</b> prev_proposal = self.voted_proposal;
    self.voted_proposal = proposal;

    prev_proposal
}
</code></pre>



</details>

<a name="0x0_user_add_settled_amounts"></a>

## Function `add_settled_amounts`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user_add_settled_amounts">add_settled_amounts</a>(self: &<b>mut</b> <a href="user.md#0x0_user_User">user::User</a>, base: u64, quote: u64, deep: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user_add_settled_amounts">add_settled_amounts</a>(
    self: &<b>mut</b> <a href="user.md#0x0_user_User">User</a>,
    base: u64,
    quote: u64,
    deep: u64,
) {
    self.settled_balances.base = self.settled_balances.base + base;
    self.settled_balances.quote = self.settled_balances.quote + quote;
    self.settled_balances.deep = self.settled_balances.deep + deep;
}
</code></pre>



</details>

<a name="0x0_user_add_owed_amounts"></a>

## Function `add_owed_amounts`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user_add_owed_amounts">add_owed_amounts</a>(self: &<b>mut</b> <a href="user.md#0x0_user_User">user::User</a>, base: u64, quote: u64, deep: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user_add_owed_amounts">add_owed_amounts</a>(
    self: &<b>mut</b> <a href="user.md#0x0_user_User">User</a>,
    base: u64,
    quote: u64,
    deep: u64,
) {
    self.owed_balances.base = self.owed_balances.base + base;
    self.owed_balances.quote = self.owed_balances.quote + quote;
    self.owed_balances.deep = self.owed_balances.deep + deep;
}
</code></pre>



</details>

<a name="0x0_user_settle"></a>

## Function `settle`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user_settle">settle</a>(self: &<b>mut</b> <a href="user.md#0x0_user_User">user::User</a>): (u64, u64, u64, u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user_settle">settle</a>(
    self: &<b>mut</b> <a href="user.md#0x0_user_User">User</a>,
): (u64, u64, u64, u64, u64, u64) {
    <b>let</b> (base_out, quote_out, deep_out) = self.settled_balances.<a href="user.md#0x0_user_reset">reset</a>();
    <b>let</b> (base_in, quote_in, deep_in) = self.owed_balances.<a href="user.md#0x0_user_reset">reset</a>();

    (base_out, quote_out, deep_out, base_in, quote_in, deep_in)
}
</code></pre>



</details>

<a name="0x0_user_update"></a>

## Function `update`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <b>update</b>(self: &<b>mut</b> <a href="user.md#0x0_user_User">user::User</a>, epoch: u64): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <b>update</b>(
    self: &<b>mut</b> <a href="user.md#0x0_user_User">User</a>,
    epoch: u64,
): (u64, u64, u64) {
    <b>if</b> (self.epoch == epoch) <b>return</b> (0, 0, 0);

    <b>let</b> prev_epoch = self.epoch;
    <b>let</b> maker_volume = self.maker_volume;
    <b>let</b> active_stake = self.active_stake;

    self.epoch = epoch;
    self.maker_volume = 0;
    self.active_stake = self.active_stake + self.inactive_stake;
    self.inactive_stake = 0;
    self.voted_proposal = <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>();

    (prev_epoch, maker_volume, active_stake)
}
</code></pre>



</details>

<a name="0x0_user_add_rebates"></a>

## Function `add_rebates`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user_add_rebates">add_rebates</a>(self: &<b>mut</b> <a href="user.md#0x0_user_User">user::User</a>, rebates: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user_add_rebates">add_rebates</a>(
    self: &<b>mut</b> <a href="user.md#0x0_user_User">User</a>,
    rebates: u64,
) {
    self.unclaimed_rebates = self.unclaimed_rebates + rebates;
}
</code></pre>



</details>

<a name="0x0_user_claim_rebates"></a>

## Function `claim_rebates`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user_claim_rebates">claim_rebates</a>(self: &<b>mut</b> <a href="user.md#0x0_user_User">user::User</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user_claim_rebates">claim_rebates</a>(
    self: &<b>mut</b> <a href="user.md#0x0_user_User">User</a>,
) {
    self.settled_balances.deep = self.settled_balances.deep + self.unclaimed_rebates;
    self.unclaimed_rebates = 0;
}
</code></pre>



</details>

<a name="0x0_user_add_order"></a>

## Function `add_order`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user_add_order">add_order</a>(self: &<b>mut</b> <a href="user.md#0x0_user_User">user::User</a>, order_id: u128)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user_add_order">add_order</a>(
    self: &<b>mut</b> <a href="user.md#0x0_user_User">User</a>,
    order_id: u128,
) {
    self.open_orders.insert(order_id);
}
</code></pre>



</details>

<a name="0x0_user_remove_order"></a>

## Function `remove_order`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user_remove_order">remove_order</a>(self: &<b>mut</b> <a href="user.md#0x0_user_User">user::User</a>, order_id: u128)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user_remove_order">remove_order</a>(
    self: &<b>mut</b> <a href="user.md#0x0_user_User">User</a>,
    order_id: u128,
) {
    self.open_orders.remove(&order_id)
}
</code></pre>



</details>

<a name="0x0_user_add_stake"></a>

## Function `add_stake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user_add_stake">add_stake</a>(self: &<b>mut</b> <a href="user.md#0x0_user_User">user::User</a>, stake: u64): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user_add_stake">add_stake</a>(
    self: &<b>mut</b> <a href="user.md#0x0_user_User">User</a>,
    stake: u64,
): (u64, u64) {
    <b>let</b> stake_before = self.active_stake + self.inactive_stake;
    self.inactive_stake = self.inactive_stake + stake;
    self.owed_balances.deep = self.owed_balances.deep + stake;

    (stake_before, stake_before + self.inactive_stake)
}
</code></pre>



</details>

<a name="0x0_user_remove_stake"></a>

## Function `remove_stake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user_remove_stake">remove_stake</a>(self: &<b>mut</b> <a href="user.md#0x0_user_User">user::User</a>): (u64, <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<b>address</b>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user_remove_stake">remove_stake</a>(
    self: &<b>mut</b> <a href="user.md#0x0_user_User">User</a>,
): (u64, Option&lt;<b>address</b>&gt;) {
    <b>let</b> stake_before = self.active_stake + self.inactive_stake;
    <b>let</b> voted_proposal = self.voted_proposal;
    self.active_stake = 0;
    self.inactive_stake = 0;
    self.voted_proposal = <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>();
    self.settled_balances.deep = self.settled_balances.deep + stake_before;

    (stake_before, voted_proposal)
}
</code></pre>



</details>

<a name="0x0_user_open_orders"></a>

## Function `open_orders`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user_open_orders">open_orders</a>(self: &<a href="user.md#0x0_user_User">user::User</a>): <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set_VecSet">vec_set::VecSet</a>&lt;u128&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user_open_orders">open_orders</a>(
    self: &<a href="user.md#0x0_user_User">User</a>,
): VecSet&lt;u128&gt; {
    self.open_orders
}
</code></pre>



</details>

<a name="0x0_user_reset"></a>

## Function `reset`



<pre><code><b>fun</b> <a href="user.md#0x0_user_reset">reset</a>(balances: &<b>mut</b> <a href="user.md#0x0_user_Balances">user::Balances</a>): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="user.md#0x0_user_reset">reset</a>(balances: &<b>mut</b> <a href="user.md#0x0_user_Balances">Balances</a>): (u64, u64, u64) {
    <b>let</b> base = balances.base;
    <b>let</b> quote = balances.quote;
    <b>let</b> deep = balances.deep;
    balances.base = 0;
    balances.quote = 0;
    balances.deep = 0;

    (base, quote, deep)
}
</code></pre>



</details>
