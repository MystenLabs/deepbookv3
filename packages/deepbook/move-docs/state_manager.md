
<a name="0x0_state_manager"></a>

# Module `0x0::state_manager`

This module manages pool volumes and fees as well as the individual user volume and orders.
Functions that mutate the state manager will refresh the Fees and Volumes to the current epoch.
Functions that mutate the invdividual user will refresh the user's data, calculating the
rebates and burns for the previous epoch.
It is guaranteed that the user's will not be refreshed before the state is refreshed.


-  [Struct `TradeParams`](#0x0_state_manager_TradeParams)
-  [Struct `Volumes`](#0x0_state_manager_Volumes)
-  [Struct `User`](#0x0_state_manager_User)
-  [Struct `StateManager`](#0x0_state_manager_StateManager)
-  [Constants](#@Constants_0)
-  [Function `new_trade_params`](#0x0_state_manager_new_trade_params)
-  [Function `new`](#0x0_state_manager_new)
-  [Function `set_next_trade_params`](#0x0_state_manager_set_next_trade_params)
-  [Function `set_fees`](#0x0_state_manager_set_fees)
-  [Function `fees_for_user`](#0x0_state_manager_fees_for_user)
-  [Function `stake_required`](#0x0_state_manager_stake_required)
-  [Function `reset_burn_balance`](#0x0_state_manager_reset_burn_balance)
-  [Function `user_stake`](#0x0_state_manager_user_stake)
-  [Function `increase_user_stake`](#0x0_state_manager_increase_user_stake)
-  [Function `remove_user_stake`](#0x0_state_manager_remove_user_stake)
-  [Function `set_user_voted_proposal`](#0x0_state_manager_set_user_voted_proposal)
-  [Function `reset_user_rebates`](#0x0_state_manager_reset_user_rebates)
-  [Function `user_open_orders`](#0x0_state_manager_user_open_orders)
-  [Function `add_user_open_order`](#0x0_state_manager_add_user_open_order)
-  [Function `remove_user_open_order`](#0x0_state_manager_remove_user_open_order)
-  [Function `process_fill`](#0x0_state_manager_process_fill)
-  [Function `add_settled_amounts`](#0x0_state_manager_add_settled_amounts)
-  [Function `add_owed_amounts`](#0x0_state_manager_add_owed_amounts)
-  [Function `settle_user`](#0x0_state_manager_settle_user)
-  [Function `update`](#0x0_state_manager_update)
-  [Function `update_user`](#0x0_state_manager_update_user)
-  [Function `add_new_user`](#0x0_state_manager_add_new_user)
-  [Function `increment_users_with_rebates`](#0x0_state_manager_increment_users_with_rebates)
-  [Function `decrement_users_with_rebates`](#0x0_state_manager_decrement_users_with_rebates)
-  [Function `calculate_rebate_and_burn_amounts`](#0x0_state_manager_calculate_rebate_and_burn_amounts)


<pre><code><b>use</b> <a href="governance.md#0x0_governance">0x0::governance</a>;
<b>use</b> <a href="order.md#0x0_order">0x0::order</a>;
<b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
<b>use</b> <a href="dependencies/sui-framework/table.md#0x2_table">0x2::table</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
<b>use</b> <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set">0x2::vec_set</a>;
</code></pre>



<a name="0x0_state_manager_TradeParams"></a>

## Struct `TradeParams`

Parameters that can be updated by governance.


<pre><code><b>struct</b> <a href="state_manager.md#0x0_state_manager_TradeParams">TradeParams</a> <b>has</b> <b>copy</b>, drop, store
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

<a name="0x0_state_manager_Volumes"></a>

## Struct `Volumes`

Overall volumes for the current epoch. Used to calculate rebates and burns.


<pre><code><b>struct</b> <a href="state_manager.md#0x0_state_manager_Volumes">Volumes</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>total_volume: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>total_staked_volume: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>total_fees_collected: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>users_with_rebates: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_state_manager_User"></a>

## Struct `User`

User data that is updated every epoch.


<pre><code><b>struct</b> <a href="state_manager.md#0x0_state_manager_User">User</a> <b>has</b> <b>copy</b>, drop, store
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
<code>old_stake: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>new_stake: u64</code>
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
<code>settled_base_amount: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>settled_quote_amount: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>settled_deep_amount: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>owed_base_amount: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>owed_quote_amount: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>owed_deep_amount: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_state_manager_StateManager"></a>

## Struct `StateManager`



<pre><code><b>struct</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a> <b>has</b> store
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
<code>trade_params: <a href="state_manager.md#0x0_state_manager_TradeParams">state_manager::TradeParams</a></code>
</dt>
<dd>

</dd>
<dt>
<code>next_trade_params: <a href="state_manager.md#0x0_state_manager_TradeParams">state_manager::TradeParams</a></code>
</dt>
<dd>

</dd>
<dt>
<code>volumes: <a href="state_manager.md#0x0_state_manager_Volumes">state_manager::Volumes</a></code>
</dt>
<dd>

</dd>
<dt>
<code>historic_volumes: <a href="dependencies/sui-framework/table.md#0x2_table_Table">table::Table</a>&lt;u64, <a href="state_manager.md#0x0_state_manager_Volumes">state_manager::Volumes</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>users: <a href="dependencies/sui-framework/table.md#0x2_table_Table">table::Table</a>&lt;<b>address</b>, <a href="state_manager.md#0x0_state_manager_User">state_manager::User</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>balance_to_burn: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_state_manager_EHistoricVolumesNotFound"></a>



<pre><code><b>const</b> <a href="state_manager.md#0x0_state_manager_EHistoricVolumesNotFound">EHistoricVolumesNotFound</a>: u64 = 2;
</code></pre>



<a name="0x0_state_manager_EUserNotFound"></a>



<pre><code><b>const</b> <a href="state_manager.md#0x0_state_manager_EUserNotFound">EUserNotFound</a>: u64 = 1;
</code></pre>



<a name="0x0_state_manager_new_trade_params"></a>

## Function `new_trade_params`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_new_trade_params">new_trade_params</a>(taker_fee: u64, maker_fee: u64, stake_required: u64): <a href="state_manager.md#0x0_state_manager_TradeParams">state_manager::TradeParams</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_new_trade_params">new_trade_params</a>(
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
): <a href="state_manager.md#0x0_state_manager_TradeParams">TradeParams</a> {
    <a href="state_manager.md#0x0_state_manager_TradeParams">TradeParams</a> {
        taker_fee,
        maker_fee,
        stake_required,
    }
}
</code></pre>



</details>

<a name="0x0_state_manager_new"></a>

## Function `new`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_new">new</a>(taker_fee: u64, maker_fee: u64, stake_required: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_new">new</a>(
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
    ctx: &<b>mut</b> TxContext,
): <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a> {
    <b>let</b> trade_params = <a href="state_manager.md#0x0_state_manager_new_trade_params">new_trade_params</a>(taker_fee, maker_fee, stake_required);
    <b>let</b> next_trade_params = <a href="state_manager.md#0x0_state_manager_new_trade_params">new_trade_params</a>(taker_fee, maker_fee, stake_required);
    <b>let</b> volumes = <a href="state_manager.md#0x0_state_manager_Volumes">Volumes</a> {
        total_volume: 0,
        total_staked_volume: 0,
        total_fees_collected: 0,
        users_with_rebates: 0,
    };
    <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a> {
        epoch: ctx.epoch(),
        trade_params,
        next_trade_params,
        volumes,
        historic_volumes: <a href="dependencies/sui-framework/table.md#0x2_table_new">table::new</a>(ctx),
        users: <a href="dependencies/sui-framework/table.md#0x2_table_new">table::new</a>(ctx),
        balance_to_burn: 0,
    }
}
</code></pre>



</details>

<a name="0x0_state_manager_set_next_trade_params"></a>

## Function `set_next_trade_params`

Set the fee parameters for the next epoch. Pushed by governance.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_set_next_trade_params">set_next_trade_params</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_set_next_trade_params">set_next_trade_params</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    proposal: Option&lt;Proposal&gt;,
) {
    <b>if</b> (proposal.is_none()) <b>return</b>;
    <b>let</b> (taker, maker, stake) = proposal.borrow().params();
    self.next_trade_params = <a href="state_manager.md#0x0_state_manager_new_trade_params">new_trade_params</a>(taker, maker, stake);
}
</code></pre>



</details>

<a name="0x0_state_manager_set_fees"></a>

## Function `set_fees`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_set_fees">set_fees</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, taker_fee: u64, maker_fee: u64, epoch: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_set_fees">set_fees</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    taker_fee: u64,
    maker_fee: u64,
    epoch: u64,
) {
    self.<b>update</b>(epoch);
    self.next_trade_params.taker_fee = taker_fee;
    self.next_trade_params.maker_fee = maker_fee;
}
</code></pre>



</details>

<a name="0x0_state_manager_fees_for_user"></a>

## Function `fees_for_user`

Taker fee for a user. If the user has enough stake and has traded a certain amount of volume,
the taker fee is halved.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_fees_for_user">fees_for_user</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_fees_for_user">fees_for_user</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    user: <b>address</b>,
): (u64, u64) {
    <b>let</b> user = <a href="state_manager.md#0x0_state_manager_update_user">update_user</a>(self, user);
    // TODO: user <b>has</b> <b>to</b> trade a certain amount of volume first
    <b>let</b> taker_fee = <b>if</b> (user.old_stake &gt;= self.trade_params.stake_required) {
        self.trade_params.taker_fee / 2
    } <b>else</b> {
        self.trade_params.taker_fee
    };

    (self.trade_params.maker_fee, taker_fee)
}
</code></pre>



</details>

<a name="0x0_state_manager_stake_required"></a>

## Function `stake_required`

Get the total maker volume for the current epoch.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_stake_required">stake_required</a>(self: &<a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, epoch: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_stake_required">stake_required</a>(self: &<a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>, epoch: u64): u64 {
    <b>if</b> (self.epoch == epoch) {
        self.trade_params.stake_required
    } <b>else</b> {
        self.next_trade_params.stake_required
    }
}
</code></pre>



</details>

<a name="0x0_state_manager_reset_burn_balance"></a>

## Function `reset_burn_balance`

Reset the burn balance to 0, return the amount.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_reset_burn_balance">reset_burn_balance</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_reset_burn_balance">reset_burn_balance</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>): u64 {
    <b>let</b> amount = self.balance_to_burn;
    self.balance_to_burn = 0;

    amount
}
</code></pre>



</details>

<a name="0x0_state_manager_user_stake"></a>

## Function `user_stake`

Get the users old_stake and new_stake, where old_stake is the amount staked before
the current epoch and new_stake is the amount staked in the current epoch.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_user_stake">user_stake</a>(self: &<a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>, epoch: u64): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_user_stake">user_stake</a>(
    self: &<a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    user: <b>address</b>,
    epoch: u64
): (u64, u64) {
    <b>if</b> (!self.users.contains(user)) <b>return</b> (0, 0);

    <b>let</b> user = self.users[user];
    <b>if</b> (user.epoch == epoch) {
        (user.old_stake, user.new_stake)
    } <b>else</b> {
        (user.old_stake + user.new_stake, 0)
    }
}
</code></pre>



</details>

<a name="0x0_state_manager_increase_user_stake"></a>

## Function `increase_user_stake`

Increase user stake. Return the user's total stake.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_increase_user_stake">increase_user_stake</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>, amount: u64, epoch: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_increase_user_stake">increase_user_stake</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    user: <b>address</b>,
    amount: u64,
    epoch: u64,
): u64 {
    self.<b>update</b>(epoch);
    <b>let</b> user = <a href="state_manager.md#0x0_state_manager_update_user">update_user</a>(self, user);
    user.new_stake = user.new_stake + amount;

    user.old_stake + user.new_stake
}
</code></pre>



</details>

<a name="0x0_state_manager_remove_user_stake"></a>

## Function `remove_user_stake`

Remove user stake. Return the user's total stake.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_remove_user_stake">remove_user_stake</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>, epoch: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_remove_user_stake">remove_user_stake</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    user: <b>address</b>,
    epoch: u64,
): u64 {
    self.<b>update</b>(epoch);
    <b>let</b> user = <a href="state_manager.md#0x0_state_manager_update_user">update_user</a>(self, user);
    <b>let</b> (old_stake, new_stake) = (user.old_stake, user.new_stake);
    user.old_stake = 0;
    user.new_stake = 0;

    old_stake + new_stake
}
</code></pre>



</details>

<a name="0x0_state_manager_set_user_voted_proposal"></a>

## Function `set_user_voted_proposal`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_set_user_voted_proposal">set_user_voted_proposal</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>, proposal_id: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<b>address</b>&gt;, epoch: u64): <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<b>address</b>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_set_user_voted_proposal">set_user_voted_proposal</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    user: <b>address</b>,
    proposal_id: Option&lt;<b>address</b>&gt;,
    epoch: u64,
): Option&lt;<b>address</b>&gt; {
    self.<b>update</b>(epoch);
    <b>let</b> user = <a href="state_manager.md#0x0_state_manager_update_user">update_user</a>(self, user);
    <b>let</b> cur_proposal = user.voted_proposal;
    user.voted_proposal = proposal_id;

    cur_proposal
}
</code></pre>



</details>

<a name="0x0_state_manager_reset_user_rebates"></a>

## Function `reset_user_rebates`

Set rebates for user to 0. Return the new unclaimed rebates.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_reset_user_rebates">reset_user_rebates</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>, epoch: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_reset_user_rebates">reset_user_rebates</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    user: <b>address</b>,
    epoch: u64,
) {
    self.<b>update</b>(epoch);
    <b>let</b> user = <a href="state_manager.md#0x0_state_manager_update_user">update_user</a>(self, user);
    user.settled_deep_amount = user.settled_deep_amount + user.unclaimed_rebates;
    user.unclaimed_rebates = 0;
}
</code></pre>



</details>

<a name="0x0_state_manager_user_open_orders"></a>

## Function `user_open_orders`

All of the user's open orders.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_user_open_orders">user_open_orders</a>(self: &<a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>): <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set_VecSet">vec_set::VecSet</a>&lt;u128&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_user_open_orders">user_open_orders</a>(
    self: &<a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    user: <b>address</b>,
): VecSet&lt;u128&gt; {
    <b>if</b> (!self.users.contains(user)) <b>return</b> <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set_empty">vec_set::empty</a>();

    self.users[user].open_orders
}
</code></pre>



</details>

<a name="0x0_state_manager_add_user_open_order"></a>

## Function `add_user_open_order`

Add an open order to the user.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_add_user_open_order">add_user_open_order</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>, order_id: u128)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_add_user_open_order">add_user_open_order</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    user: <b>address</b>,
    order_id: u128,
) {
    <b>let</b> user = <a href="state_manager.md#0x0_state_manager_update_user">update_user</a>(self, user);
    user.open_orders.insert(order_id);
}
</code></pre>



</details>

<a name="0x0_state_manager_remove_user_open_order"></a>

## Function `remove_user_open_order`

Remove an open order from the user.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_remove_user_open_order">remove_user_open_order</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>, order_id: u128)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_remove_user_open_order">remove_user_open_order</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    user: <b>address</b>,
    order_id: u128,
) {
    <b>assert</b>!(self.users.contains(user), <a href="state_manager.md#0x0_state_manager_EUserNotFound">EUserNotFound</a>);

    <b>let</b> user = <a href="state_manager.md#0x0_state_manager_update_user">update_user</a>(self, user);
    user.open_orders.remove(&order_id);
}
</code></pre>



</details>

<a name="0x0_state_manager_process_fill"></a>

## Function `process_fill`

Process a fill. Update the user and total volume and any settled amounts.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_process_fill">process_fill</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, fill: &<a href="order.md#0x0_order_Fill">order::Fill</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_process_fill">process_fill</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    fill: &Fill,
) {
    <b>let</b> (order_id, owner, expired, complete) = fill.fill_status();
    <b>let</b> (base, quote, deep) = fill.settled_quantities();
    <a href="state_manager.md#0x0_state_manager_update_user">update_user</a>(self, owner);

    <b>if</b> (complete) {
        <a href="state_manager.md#0x0_state_manager_increment_users_with_rebates">increment_users_with_rebates</a>(self, owner);
        <b>let</b> user = &self.users[owner];
        <b>if</b> (user.old_stake &gt;= self.trade_params.stake_required) {
            self.volumes.total_staked_volume = self.volumes.total_staked_volume + base;
        };
        self.volumes.total_volume = self.volumes.total_volume + base;
    };

    <b>let</b> user = &<b>mut</b> self.users[owner];
    <b>if</b> (expired || complete) {
        user.open_orders.remove(&order_id);
    };

    self.<a href="state_manager.md#0x0_state_manager_add_settled_amounts">add_settled_amounts</a>(owner, base, quote, deep);
}
</code></pre>



</details>

<a name="0x0_state_manager_add_settled_amounts"></a>

## Function `add_settled_amounts`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_add_settled_amounts">add_settled_amounts</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>, base: u64, quote: u64, deep: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_add_settled_amounts">add_settled_amounts</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    user: <b>address</b>,
    base: u64,
    quote: u64,
    deep: u64,
) {
    <b>let</b> user = <a href="state_manager.md#0x0_state_manager_update_user">update_user</a>(self, user);
    user.settled_base_amount = user.settled_base_amount + base;
    user.settled_quote_amount = user.settled_quote_amount + quote;
    user.settled_deep_amount = user.settled_deep_amount + deep;
}
</code></pre>



</details>

<a name="0x0_state_manager_add_owed_amounts"></a>

## Function `add_owed_amounts`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_add_owed_amounts">add_owed_amounts</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>, base: u64, quote: u64, deep: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_add_owed_amounts">add_owed_amounts</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    user: <b>address</b>,
    base: u64,
    quote: u64,
    deep: u64,
) {
    <b>let</b> user = <a href="state_manager.md#0x0_state_manager_update_user">update_user</a>(self, user);
    user.owed_base_amount = user.owed_base_amount + base;
    user.owed_quote_amount = user.owed_quote_amount + quote;
    user.owed_deep_amount = user.owed_deep_amount + deep;
}
</code></pre>



</details>

<a name="0x0_state_manager_settle_user"></a>

## Function `settle_user`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_settle_user">settle_user</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>, epoch: u64): (u64, u64, u64, u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state_manager.md#0x0_state_manager_settle_user">settle_user</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    user: <b>address</b>,
    epoch: u64,
): (u64, u64, u64, u64, u64, u64) {
    self.<b>update</b>(epoch);
    <b>let</b> user = <a href="state_manager.md#0x0_state_manager_update_user">update_user</a>(self, user);
    <b>let</b> base_out = user.settled_base_amount;
    <b>let</b> quote_out = user.settled_quote_amount;
    <b>let</b> deep_out = user.settled_deep_amount;
    <b>let</b> base_in = user.owed_base_amount;
    <b>let</b> quote_in = user.owed_quote_amount;
    <b>let</b> deep_in = user.owed_deep_amount;
    user.settled_base_amount = 0;
    user.settled_quote_amount = 0;
    user.settled_deep_amount = 0;
    user.owed_base_amount = 0;
    user.owed_quote_amount = 0;
    user.owed_deep_amount = 0;

    (base_out, quote_out, deep_out, base_in, quote_in, deep_in)
}
</code></pre>



</details>

<a name="0x0_state_manager_update"></a>

## Function `update`

Update the state manager to the current epoch.


<pre><code><b>fun</b> <b>update</b>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, epoch: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <b>update</b>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    epoch: u64,
) {
    <b>if</b> (self.epoch == epoch) <b>return</b>;
    <b>if</b> (self.volumes.users_with_rebates &gt; 0) {
        self.historic_volumes.add(self.epoch, self.volumes);
    };
    self.trade_params = self.next_trade_params;
    self.epoch = epoch;
}
</code></pre>



</details>

<a name="0x0_state_manager_update_user"></a>

## Function `update_user`

Add new user or refresh an existing user.


<pre><code><b>fun</b> <a href="state_manager.md#0x0_state_manager_update_user">update_user</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>): &<b>mut</b> <a href="state_manager.md#0x0_state_manager_User">state_manager::User</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="state_manager.md#0x0_state_manager_update_user">update_user</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    user: <b>address</b>,
): &<b>mut</b> <a href="state_manager.md#0x0_state_manager_User">User</a> {
    <b>let</b> epoch = self.epoch;
    <a href="state_manager.md#0x0_state_manager_add_new_user">add_new_user</a>(self, user, epoch);
    self.<a href="state_manager.md#0x0_state_manager_decrement_users_with_rebates">decrement_users_with_rebates</a>(user, epoch);

    <b>let</b> user = &<b>mut</b> self.users[user];
    <b>if</b> (user.epoch == epoch) <b>return</b> user;
    <b>let</b> (rebates, burns) = <a href="state_manager.md#0x0_state_manager_calculate_rebate_and_burn_amounts">calculate_rebate_and_burn_amounts</a>(user);
    user.epoch = epoch;
    user.maker_volume = 0;
    user.old_stake = user.old_stake + user.new_stake;
    user.new_stake = 0;
    user.unclaimed_rebates = user.unclaimed_rebates + rebates;
    self.balance_to_burn = self.balance_to_burn + burns;
    user.voted_proposal = <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>();

    user
}
</code></pre>



</details>

<a name="0x0_state_manager_add_new_user"></a>

## Function `add_new_user`



<pre><code><b>fun</b> <a href="state_manager.md#0x0_state_manager_add_new_user">add_new_user</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>, epoch: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="state_manager.md#0x0_state_manager_add_new_user">add_new_user</a>(
    self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>,
    user: <b>address</b>,
    epoch: u64,
) {
    <b>if</b> (!self.users.contains(user)) {
        self.users.add(user, <a href="state_manager.md#0x0_state_manager_User">User</a> {
            epoch,
            open_orders: <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set_empty">vec_set::empty</a>(),
            maker_volume: 0,
            old_stake: 0,
            new_stake: 0,
            voted_proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(),
            unclaimed_rebates: 0,
            settled_base_amount: 0,
            settled_quote_amount: 0,
            settled_deep_amount: 0,
            owed_base_amount: 0,
            owed_quote_amount: 0,
            owed_deep_amount: 0,
        });
    };
}
</code></pre>



</details>

<a name="0x0_state_manager_increment_users_with_rebates"></a>

## Function `increment_users_with_rebates`

Increment the number of users with rebates for this epoch.
Called when a staked user generates their first volume for this epoch.
This user will be eligible for rebates, so historic records of this epoch
must be maintained until the user calculates their rebates.


<pre><code><b>fun</b> <a href="state_manager.md#0x0_state_manager_increment_users_with_rebates">increment_users_with_rebates</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="state_manager.md#0x0_state_manager_increment_users_with_rebates">increment_users_with_rebates</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>, user: <b>address</b>) {
    <b>let</b> user = self.users[user];
    <b>if</b> (user.maker_volume == 0 && user.old_stake &gt;= self.trade_params.stake_required) {
        self.volumes.users_with_rebates = self.volumes.users_with_rebates + 1;
    }
}
</code></pre>



</details>

<a name="0x0_state_manager_decrement_users_with_rebates"></a>

## Function `decrement_users_with_rebates`

Decrement the number of users with rebates for the given epoch.
Called when a staked user calculates their rebates for a historic epoch.
If the number of users with rebates drops to 0, the historic volumes for that epoch
can be removed.


<pre><code><b>fun</b> <a href="state_manager.md#0x0_state_manager_decrement_users_with_rebates">decrement_users_with_rebates</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">state_manager::StateManager</a>, user: <b>address</b>, epoch: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="state_manager.md#0x0_state_manager_decrement_users_with_rebates">decrement_users_with_rebates</a>(self: &<b>mut</b> <a href="state_manager.md#0x0_state_manager_StateManager">StateManager</a>, user: <b>address</b>, epoch: u64) {
    <b>let</b> user = self.users[user];
    <b>if</b> (user.epoch == epoch || user.maker_volume == 0 || user.old_stake &lt; self.trade_params.stake_required) {
        <b>return</b>
    };
    <b>assert</b>!(self.historic_volumes.contains(epoch), <a href="state_manager.md#0x0_state_manager_EHistoricVolumesNotFound">EHistoricVolumesNotFound</a>);
    <b>let</b> volumes = &<b>mut</b> self.historic_volumes[epoch];
    volumes.users_with_rebates = volumes.users_with_rebates - 1;
    <b>if</b> (volumes.users_with_rebates == 0) {
        self.historic_volumes.remove(epoch);
    }
}
</code></pre>



</details>

<a name="0x0_state_manager_calculate_rebate_and_burn_amounts"></a>

## Function `calculate_rebate_and_burn_amounts`

Given the epoch's volume data and the user's volume data,
calculate the rebate and burn amounts.


<pre><code><b>fun</b> <a href="state_manager.md#0x0_state_manager_calculate_rebate_and_burn_amounts">calculate_rebate_and_burn_amounts</a>(_user: &<a href="state_manager.md#0x0_state_manager_User">state_manager::User</a>): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="state_manager.md#0x0_state_manager_calculate_rebate_and_burn_amounts">calculate_rebate_and_burn_amounts</a>(_user: &<a href="state_manager.md#0x0_state_manager_User">User</a>): (u64, u64) {
    // calculate rebates from the current <a href="state_manager.md#0x0_state_manager_User">User</a> data
    (0, 0)
}
</code></pre>



</details>
