
<a name="0x0_account"></a>

# Module `0x0::account`

Account module manages the account data for each user.


-  [Struct `Account`](#0x0_account_Account)
-  [Function `empty`](#0x0_account_empty)
-  [Function `active_stake`](#0x0_account_active_stake)
-  [Function `inactive_stake`](#0x0_account_inactive_stake)
-  [Function `total_volume`](#0x0_account_total_volume)
-  [Function `voted_proposal`](#0x0_account_voted_proposal)
-  [Function `open_orders`](#0x0_account_open_orders)
-  [Function `update`](#0x0_account_update)
-  [Function `process_maker_fill`](#0x0_account_process_maker_fill)
-  [Function `add_taker_volume`](#0x0_account_add_taker_volume)
-  [Function `set_voted_proposal`](#0x0_account_set_voted_proposal)
-  [Function `add_settled_balances`](#0x0_account_add_settled_balances)
-  [Function `add_owed_balances`](#0x0_account_add_owed_balances)
-  [Function `settle`](#0x0_account_settle)
-  [Function `add_rebates`](#0x0_account_add_rebates)
-  [Function `claim_rebates`](#0x0_account_claim_rebates)
-  [Function `add_order`](#0x0_account_add_order)
-  [Function `remove_order`](#0x0_account_remove_order)
-  [Function `add_stake`](#0x0_account_add_stake)
-  [Function `remove_stake`](#0x0_account_remove_stake)


<pre><code><b>use</b> <a href="balances.md#0x0_balances">0x0::balances</a>;
<b>use</b> <a href="fill.md#0x0_fill">0x0::fill</a>;
<b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
<b>use</b> <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set">0x2::vec_set</a>;
</code></pre>



<a name="0x0_account_Account"></a>

## Struct `Account`

Account data that is updated every epoch.
One Account struct per BalanceManager object.


<pre><code><b>struct</b> <a href="account.md#0x0_account_Account">Account</a> <b>has</b> <b>copy</b>, drop, store
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
<code>taker_volume: u64</code>
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
<code>voted_proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>unclaimed_rebates: <a href="balances.md#0x0_balances_Balances">balances::Balances</a></code>
</dt>
<dd>

</dd>
<dt>
<code>settled_balances: <a href="balances.md#0x0_balances_Balances">balances::Balances</a></code>
</dt>
<dd>

</dd>
<dt>
<code>owed_balances: <a href="balances.md#0x0_balances_Balances">balances::Balances</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_account_empty"></a>

## Function `empty`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_empty">empty</a>(ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="account.md#0x0_account_Account">account::Account</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_empty">empty</a>(
    ctx: &TxContext,
): <a href="account.md#0x0_account_Account">Account</a> {
    <a href="account.md#0x0_account_Account">Account</a> {
        epoch: ctx.epoch(),
        open_orders: <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set_empty">vec_set::empty</a>(),
        taker_volume: 0,
        maker_volume: 0,
        active_stake: 0,
        inactive_stake: 0,
        voted_proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(),
        unclaimed_rebates: <a href="balances.md#0x0_balances_empty">balances::empty</a>(),
        settled_balances: <a href="balances.md#0x0_balances_empty">balances::empty</a>(),
        owed_balances: <a href="balances.md#0x0_balances_empty">balances::empty</a>(),
    }
}
</code></pre>



</details>

<a name="0x0_account_active_stake"></a>

## Function `active_stake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_active_stake">active_stake</a>(self: &<a href="account.md#0x0_account_Account">account::Account</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_active_stake">active_stake</a>(self: &<a href="account.md#0x0_account_Account">Account</a>): u64 {
    self.active_stake
}
</code></pre>



</details>

<a name="0x0_account_inactive_stake"></a>

## Function `inactive_stake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_inactive_stake">inactive_stake</a>(self: &<a href="account.md#0x0_account_Account">account::Account</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_inactive_stake">inactive_stake</a>(self: &<a href="account.md#0x0_account_Account">Account</a>): u64 {
    self.inactive_stake
}
</code></pre>



</details>

<a name="0x0_account_total_volume"></a>

## Function `total_volume`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_total_volume">total_volume</a>(self: &<a href="account.md#0x0_account_Account">account::Account</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_total_volume">total_volume</a>(self: &<a href="account.md#0x0_account_Account">Account</a>): u64 {
    self.taker_volume + self.maker_volume
}
</code></pre>



</details>

<a name="0x0_account_voted_proposal"></a>

## Function `voted_proposal`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_voted_proposal">voted_proposal</a>(self: &<a href="account.md#0x0_account_Account">account::Account</a>): <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_voted_proposal">voted_proposal</a>(self: &<a href="account.md#0x0_account_Account">Account</a>): Option&lt;ID&gt; {
    self.voted_proposal
}
</code></pre>



</details>

<a name="0x0_account_open_orders"></a>

## Function `open_orders`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_open_orders">open_orders</a>(self: &<a href="account.md#0x0_account_Account">account::Account</a>): <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set_VecSet">vec_set::VecSet</a>&lt;u128&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_open_orders">open_orders</a>(self: &<a href="account.md#0x0_account_Account">Account</a>): VecSet&lt;u128&gt; {
    self.open_orders
}
</code></pre>



</details>

<a name="0x0_account_update"></a>

## Function `update`

Update the account data for the new epoch.
Returns the previous epoch, maker volume, and active stake.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <b>update</b>(self: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <b>update</b>(
    self: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
    ctx: &TxContext,
): (u64, u64, u64) {
    <b>if</b> (self.epoch == ctx.epoch()) <b>return</b> (0, 0, 0);

    <b>let</b> prev_epoch = self.epoch;
    <b>let</b> prev_maker_volume = self.maker_volume;
    <b>let</b> prev_active_stake = self.active_stake;

    self.epoch = ctx.epoch();
    self.maker_volume = 0;
    self.taker_volume = 0;
    self.active_stake = self.active_stake + self.inactive_stake;
    self.inactive_stake = 0;
    self.voted_proposal = <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>();

    (prev_epoch, prev_maker_volume, prev_active_stake)
}
</code></pre>



</details>

<a name="0x0_account_process_maker_fill"></a>

## Function `process_maker_fill`

Given a fill, update the account balances and volumes as the maker.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_process_maker_fill">process_maker_fill</a>(self: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, <a href="fill.md#0x0_fill">fill</a>: &<a href="fill.md#0x0_fill_Fill">fill::Fill</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_process_maker_fill">process_maker_fill</a>(
    self: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
    <a href="fill.md#0x0_fill">fill</a>: &Fill,
) {
    <b>let</b> settled_balances = <a href="fill.md#0x0_fill">fill</a>.get_settled_maker_quantities();
    self.settled_balances.add_balances(settled_balances);
    <b>if</b> (!<a href="fill.md#0x0_fill">fill</a>.expired()) {
        self.maker_volume = self.maker_volume + <a href="fill.md#0x0_fill">fill</a>.base_quantity();
    };
    <b>if</b> (<a href="fill.md#0x0_fill">fill</a>.expired() || <a href="fill.md#0x0_fill">fill</a>.completed()) {
        self.open_orders.remove(&<a href="fill.md#0x0_fill">fill</a>.order_id());
    }
}
</code></pre>



</details>

<a name="0x0_account_add_taker_volume"></a>

## Function `add_taker_volume`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_add_taker_volume">add_taker_volume</a>(self: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, volume: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_add_taker_volume">add_taker_volume</a>(
    self: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
    volume: u64,
) {
    self.taker_volume = self.taker_volume + volume;
}
</code></pre>



</details>

<a name="0x0_account_set_voted_proposal"></a>

## Function `set_voted_proposal`

Set the voted proposal for the account and return the
previous proposal.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_set_voted_proposal">set_voted_proposal</a>(self: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>&gt;): <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_set_voted_proposal">set_voted_proposal</a>(
    self: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
    proposal: Option&lt;ID&gt;
): Option&lt;ID&gt; {
    <b>let</b> prev_proposal = self.voted_proposal;
    self.voted_proposal = proposal;

    prev_proposal
}
</code></pre>



</details>

<a name="0x0_account_add_settled_balances"></a>

## Function `add_settled_balances`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_add_settled_balances">add_settled_balances</a>(self: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, <a href="balances.md#0x0_balances">balances</a>: <a href="balances.md#0x0_balances_Balances">balances::Balances</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_add_settled_balances">add_settled_balances</a>(
    self: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
    <a href="balances.md#0x0_balances">balances</a>: Balances,
) {
    self.settled_balances.add_balances(<a href="balances.md#0x0_balances">balances</a>);
}
</code></pre>



</details>

<a name="0x0_account_add_owed_balances"></a>

## Function `add_owed_balances`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_add_owed_balances">add_owed_balances</a>(self: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, <a href="balances.md#0x0_balances">balances</a>: <a href="balances.md#0x0_balances_Balances">balances::Balances</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_add_owed_balances">add_owed_balances</a>(
    self: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
    <a href="balances.md#0x0_balances">balances</a>: Balances,
) {
    self.owed_balances.add_balances(<a href="balances.md#0x0_balances">balances</a>);
}
</code></pre>



</details>

<a name="0x0_account_settle"></a>

## Function `settle`

Settle the account balances.
Returns the settled and owed balances by this account.
Vault uses these values to perform any necessary transfers.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_settle">settle</a>(self: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>): (<a href="balances.md#0x0_balances_Balances">balances::Balances</a>, <a href="balances.md#0x0_balances_Balances">balances::Balances</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_settle">settle</a>(
    self: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
): (Balances, Balances) {
    <b>let</b> settled = self.settled_balances.reset();
    <b>let</b> owed = self.owed_balances.reset();

    (settled, owed)
}
</code></pre>



</details>

<a name="0x0_account_add_rebates"></a>

## Function `add_rebates`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_add_rebates">add_rebates</a>(self: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, rebates: <a href="balances.md#0x0_balances_Balances">balances::Balances</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_add_rebates">add_rebates</a>(
    self: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
    rebates: Balances,
) {
    self.unclaimed_rebates.add_balances(rebates);
}
</code></pre>



</details>

<a name="0x0_account_claim_rebates"></a>

## Function `claim_rebates`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_claim_rebates">claim_rebates</a>(self: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_claim_rebates">claim_rebates</a>(
    self: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
) {
    self.settled_balances.add_balances(self.unclaimed_rebates);
    self.unclaimed_rebates.reset();
}
</code></pre>



</details>

<a name="0x0_account_add_order"></a>

## Function `add_order`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_add_order">add_order</a>(self: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, order_id: u128)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_add_order">add_order</a>(
    self: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
    order_id: u128,
) {
    self.open_orders.insert(order_id);
}
</code></pre>



</details>

<a name="0x0_account_remove_order"></a>

## Function `remove_order`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_remove_order">remove_order</a>(self: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, order_id: u128)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_remove_order">remove_order</a>(
    self: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
    order_id: u128,
) {
    self.open_orders.remove(&order_id)
}
</code></pre>



</details>

<a name="0x0_account_add_stake"></a>

## Function `add_stake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_add_stake">add_stake</a>(self: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, stake: u64): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_add_stake">add_stake</a>(
    self: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
    stake: u64,
): (u64, u64) {
    <b>let</b> stake_before = self.active_stake + self.inactive_stake;
    self.inactive_stake = self.inactive_stake + stake;
    self.owed_balances.add_deep(stake);

    (stake_before, self.active_stake + self.inactive_stake)
}
</code></pre>



</details>

<a name="0x0_account_remove_stake"></a>

## Function `remove_stake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account_remove_stake">remove_stake</a>(self: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account_remove_stake">remove_stake</a>(
    self: &<b>mut</b> <a href="account.md#0x0_account_Account">Account</a>,
) {
    <b>let</b> stake_before = self.active_stake + self.inactive_stake;
    self.active_stake = 0;
    self.inactive_stake = 0;
    self.voted_proposal = <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>();
    self.settled_balances.add_deep(stake_before);
}
</code></pre>



</details>
