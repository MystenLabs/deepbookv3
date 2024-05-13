
<a name="0x0_state"></a>

# Module `0x0::state`



-  [Struct `State`](#0x0_state_State)
-  [Constants](#@Constants_0)
-  [Function `empty`](#0x0_state_empty)
-  [Function `process_create`](#0x0_state_process_create)
-  [Function `process_cancel`](#0x0_state_process_cancel)
-  [Function `process_modify`](#0x0_state_process_modify)
-  [Function `process_stake`](#0x0_state_process_stake)
-  [Function `process_unstake`](#0x0_state_process_unstake)
-  [Function `process_proposal`](#0x0_state_process_proposal)
-  [Function `process_vote`](#0x0_state_process_vote)
-  [Function `deep_price`](#0x0_state_deep_price)
-  [Function `governance`](#0x0_state_governance)
-  [Function `governance_mut`](#0x0_state_governance_mut)
-  [Function `user`](#0x0_state_user)
-  [Function `user_mut`](#0x0_state_user_mut)
-  [Function `update_user`](#0x0_state_update_user)
-  [Function `add_new_user`](#0x0_state_add_new_user)


<pre><code><b>use</b> <a href="deep_price.md#0x0_deep_price">0x0::deep_price</a>;
<b>use</b> <a href="governance.md#0x0_governance">0x0::governance</a>;
<b>use</b> <a href="history.md#0x0_history">0x0::history</a>;
<b>use</b> <a href="order.md#0x0_order">0x0::order</a>;
<b>use</b> <a href="order_info.md#0x0_order_info">0x0::order_info</a>;
<b>use</b> <a href="user.md#0x0_user">0x0::user</a>;
<b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
<b>use</b> <a href="dependencies/sui-framework/table.md#0x2_table">0x2::table</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
</code></pre>



<a name="0x0_state_State"></a>

## Struct `State`



<pre><code><b>struct</b> <a href="state.md#0x0_state_State">State</a> <b>has</b> store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>users: <a href="dependencies/sui-framework/table.md#0x2_table_Table">table::Table</a>&lt;<b>address</b>, <a href="user.md#0x0_user_User">user::User</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code><a href="history.md#0x0_history">history</a>: <a href="history.md#0x0_history_History">history::History</a></code>
</dt>
<dd>

</dd>
<dt>
<code><a href="governance.md#0x0_governance">governance</a>: <a href="governance.md#0x0_governance_Governance">governance::Governance</a></code>
</dt>
<dd>

</dd>
<dt>
<code><a href="deep_price.md#0x0_deep_price">deep_price</a>: <a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_state_ENotEnoughStake"></a>



<pre><code><b>const</b> <a href="state.md#0x0_state_ENotEnoughStake">ENotEnoughStake</a>: u64 = 2;
</code></pre>



<a name="0x0_state_STAKE_REQUIRED_TO_PARTICIPATE"></a>



<pre><code><b>const</b> <a href="state.md#0x0_state_STAKE_REQUIRED_TO_PARTICIPATE">STAKE_REQUIRED_TO_PARTICIPATE</a>: u64 = 100;
</code></pre>



<a name="0x0_state_empty"></a>

## Function `empty`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_empty">empty</a>(ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="state.md#0x0_state_State">state::State</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_empty">empty</a>(ctx: &<b>mut</b> TxContext): <a href="state.md#0x0_state_State">State</a> {
    <a href="state.md#0x0_state_State">State</a> {
        <a href="history.md#0x0_history">history</a>: <a href="history.md#0x0_history_empty">history::empty</a>(ctx),
        <a href="governance.md#0x0_governance">governance</a>: <a href="governance.md#0x0_governance_empty">governance::empty</a>(ctx.epoch()),
        users: <a href="dependencies/sui-framework/table.md#0x2_table_new">table::new</a>(ctx),
        <a href="deep_price.md#0x0_deep_price">deep_price</a>: <a href="deep_price.md#0x0_deep_price_empty">deep_price::empty</a>(),
    }
}
</code></pre>



</details>

<a name="0x0_state_process_create"></a>

## Function `process_create`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_create">process_create</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="order_info.md#0x0_order_info">order_info</a>: &<a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_create">process_create</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="order_info.md#0x0_order_info">order_info</a>: &OrderInfo,
    ctx: &TxContext,
) {
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(ctx);
    <b>let</b> fills = <a href="order_info.md#0x0_order_info">order_info</a>.fills();
    <b>let</b> <b>mut</b> i = 0;
    <b>while</b> (i &lt; fills.length()) {
        <b>let</b> fill = &fills[i];
        <b>let</b> (order_id, owner, expired, completed) = fill.fill_status();
        <b>let</b> (base, quote, deep) = fill.settled_quantities();
        <b>let</b> volume = fill.volume();
        self.<a href="state.md#0x0_state_update_user">update_user</a>(owner, ctx.epoch());

        <b>let</b> <a href="user.md#0x0_user">user</a> = &<b>mut</b> self.users[owner];
        <a href="user.md#0x0_user">user</a>.add_settled_amounts(base, quote, deep);
        <a href="user.md#0x0_user">user</a>.increase_maker_volume(volume);
        <b>if</b> (expired || completed) {
            <a href="user.md#0x0_user">user</a>.remove_order(order_id);
        };

        self.<a href="history.md#0x0_history">history</a>.add_volume(volume, <a href="user.md#0x0_user">user</a>.active_stake(), <a href="user.md#0x0_user">user</a>.maker_volume() == volume);

        i = i + 1;
    };

    self.<a href="state.md#0x0_state_update_user">update_user</a>(<a href="order_info.md#0x0_order_info">order_info</a>.owner(), ctx.epoch());
    <b>let</b> <a href="user.md#0x0_user">user</a> = &<b>mut</b> self.users[<a href="order_info.md#0x0_order_info">order_info</a>.owner()];
    <a href="user.md#0x0_user">user</a>.add_order(<a href="order_info.md#0x0_order_info">order_info</a>.order_id());
    <a href="user.md#0x0_user">user</a>.increase_taker_volume(<a href="order_info.md#0x0_order_info">order_info</a>.executed_quantity());
}
</code></pre>



</details>

<a name="0x0_state_process_cancel"></a>

## Function `process_cancel`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_cancel">process_cancel</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="order.md#0x0_order">order</a>: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, order_id: u128, owner: <b>address</b>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_cancel">process_cancel</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="order.md#0x0_order">order</a>: &<b>mut</b> Order,
    order_id: u128,
    owner: <b>address</b>,
    ctx: &TxContext,
) {
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(ctx);
    <a href="order.md#0x0_order">order</a>.set_canceled();
    self.<a href="state.md#0x0_state_update_user">update_user</a>(owner, ctx.epoch());

    <b>let</b> <a href="user.md#0x0_user">user</a> = &<b>mut</b> self.users[owner];
    <b>let</b> cancel_quantity = <a href="order.md#0x0_order">order</a>.quantity();
    <b>let</b> (base_quantity, quote_quantity, deep_quantity) = <a href="order.md#0x0_order">order</a>.cancel_amounts(
        cancel_quantity,
        <b>false</b>,
    );
    <a href="user.md#0x0_user">user</a>.remove_order(order_id);
    <a href="user.md#0x0_user">user</a>.add_settled_amounts(base_quantity, quote_quantity, deep_quantity);
}
</code></pre>



</details>

<a name="0x0_state_process_modify"></a>

## Function `process_modify`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_modify">process_modify</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, owner: <b>address</b>, base_quantity: u64, quote_quantity: u64, deep_quantity: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_modify">process_modify</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    owner: <b>address</b>,
    base_quantity: u64,
    quote_quantity: u64,
    deep_quantity: u64,
    ctx: &TxContext,
) {
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(ctx);
    self.<a href="state.md#0x0_state_update_user">update_user</a>(owner, ctx.epoch());

    self.users[owner].add_settled_amounts(base_quantity, quote_quantity, deep_quantity);
}
</code></pre>



</details>

<a name="0x0_state_process_stake"></a>

## Function `process_stake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_stake">process_stake</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, owner: <b>address</b>, new_stake: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_stake">process_stake</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    owner: <b>address</b>,
    new_stake: u64,
    ctx: &TxContext,
) {
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(ctx);
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="state.md#0x0_state_update_user">update_user</a>(owner, ctx.epoch());

    <b>let</b> (stake_before, stake_after) = self.users[owner].add_stake(new_stake);
    self.<a href="governance.md#0x0_governance">governance</a>.adjust_voting_power(stake_before, stake_after);
}
</code></pre>



</details>

<a name="0x0_state_process_unstake"></a>

## Function `process_unstake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_unstake">process_unstake</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, owner: <b>address</b>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_unstake">process_unstake</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    owner: <b>address</b>,
    ctx: &TxContext,
) {
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(ctx);
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="state.md#0x0_state_update_user">update_user</a>(owner, ctx.epoch());

    <b>let</b> <a href="user.md#0x0_user">user</a> = &<b>mut</b> self.users[owner];
    <b>let</b> (total_stake, voted_proposal) = <a href="user.md#0x0_user">user</a>.remove_stake();
    self.<a href="governance.md#0x0_governance">governance</a>.adjust_voting_power(total_stake, 0);
    self.<a href="governance.md#0x0_governance">governance</a>.adjust_vote(voted_proposal, <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(), total_stake);
}
</code></pre>



</details>

<a name="0x0_state_process_proposal"></a>

## Function `process_proposal`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_proposal">process_proposal</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="user.md#0x0_user">user</a>: <b>address</b>, taker_fee: u64, maker_fee: u64, stake_required: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_proposal">process_proposal</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="user.md#0x0_user">user</a>: <b>address</b>,
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
    ctx: &TxContext,
) {
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(ctx);
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="state.md#0x0_state_update_user">update_user</a>(<a href="user.md#0x0_user">user</a>, ctx.epoch());

    <b>let</b> stake = self.users[<a href="user.md#0x0_user">user</a>].active_stake();
    <b>assert</b>!(stake &gt;= <a href="state.md#0x0_state_STAKE_REQUIRED_TO_PARTICIPATE">STAKE_REQUIRED_TO_PARTICIPATE</a>, <a href="state.md#0x0_state_ENotEnoughStake">ENotEnoughStake</a>);

    self.<a href="governance.md#0x0_governance">governance</a>.add_proposal(taker_fee, maker_fee, stake_required, stake, <a href="user.md#0x0_user">user</a>);
    self.<a href="state.md#0x0_state_process_vote">process_vote</a>(<a href="user.md#0x0_user">user</a>, <a href="user.md#0x0_user">user</a>, ctx);
}
</code></pre>



</details>

<a name="0x0_state_process_vote"></a>

## Function `process_vote`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_vote">process_vote</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="user.md#0x0_user">user</a>: <b>address</b>, proposal_id: <b>address</b>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_vote">process_vote</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="user.md#0x0_user">user</a>: <b>address</b>,
    proposal_id: <b>address</b>,
    ctx: &TxContext,
) {
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(ctx);
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="state.md#0x0_state_update_user">update_user</a>(<a href="user.md#0x0_user">user</a>, ctx.epoch());

    <b>let</b> <a href="user.md#0x0_user">user</a> = &<b>mut</b> self.users[<a href="user.md#0x0_user">user</a>];
    <b>assert</b>!(<a href="user.md#0x0_user">user</a>.active_stake() &gt;= <a href="state.md#0x0_state_STAKE_REQUIRED_TO_PARTICIPATE">STAKE_REQUIRED_TO_PARTICIPATE</a>, <a href="state.md#0x0_state_ENotEnoughStake">ENotEnoughStake</a>);

    <b>let</b> prev_proposal = <a href="user.md#0x0_user">user</a>.set_voted_proposal(<a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(proposal_id));
    self.<a href="governance.md#0x0_governance">governance</a>.adjust_vote(
        prev_proposal,
        <a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(proposal_id),
        <a href="user.md#0x0_user">user</a>.active_stake(),
    );
}
</code></pre>



</details>

<a name="0x0_state_deep_price"></a>

## Function `deep_price`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="deep_price.md#0x0_deep_price">deep_price</a>(self: &<a href="state.md#0x0_state_State">state::State</a>): &<a href="deep_price.md#0x0_deep_price_DeepPrice">deep_price::DeepPrice</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="deep_price.md#0x0_deep_price">deep_price</a>(
    self: &<a href="state.md#0x0_state_State">State</a>,
): &DeepPrice {
    &self.<a href="deep_price.md#0x0_deep_price">deep_price</a>
}
</code></pre>



</details>

<a name="0x0_state_governance"></a>

## Function `governance`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance">governance</a>(self: &<a href="state.md#0x0_state_State">state::State</a>): &<a href="governance.md#0x0_governance_Governance">governance::Governance</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="governance.md#0x0_governance">governance</a>(
    self: &<a href="state.md#0x0_state_State">State</a>,
): &Governance {
    &self.<a href="governance.md#0x0_governance">governance</a>
}
</code></pre>



</details>

<a name="0x0_state_governance_mut"></a>

## Function `governance_mut`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_governance_mut">governance_mut</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_governance_mut">governance_mut</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    ctx: &TxContext,
): &<b>mut</b> Governance {
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);

    &<b>mut</b> self.<a href="governance.md#0x0_governance">governance</a>
}
</code></pre>



</details>

<a name="0x0_state_user"></a>

## Function `user`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="user.md#0x0_user">user</a>(self: &<a href="state.md#0x0_state_State">state::State</a>, <a href="user.md#0x0_user">user</a>: <b>address</b>): &<a href="user.md#0x0_user_User">user::User</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="user.md#0x0_user">user</a>(
    self: &<a href="state.md#0x0_state_State">State</a>,
    <a href="user.md#0x0_user">user</a>: <b>address</b>,
): &User {
    &self.users[<a href="user.md#0x0_user">user</a>]
}
</code></pre>



</details>

<a name="0x0_state_user_mut"></a>

## Function `user_mut`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_user_mut">user_mut</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="user.md#0x0_user">user</a>: <b>address</b>, epoch: u64): &<b>mut</b> <a href="user.md#0x0_user_User">user::User</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_user_mut">user_mut</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="user.md#0x0_user">user</a>: <b>address</b>,
    epoch: u64,
): &<b>mut</b> User {
    self.<a href="state.md#0x0_state_update_user">update_user</a>(<a href="user.md#0x0_user">user</a>, epoch);

    &<b>mut</b> self.users[<a href="user.md#0x0_user">user</a>]
}
</code></pre>



</details>

<a name="0x0_state_update_user"></a>

## Function `update_user`



<pre><code><b>fun</b> <a href="state.md#0x0_state_update_user">update_user</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="user.md#0x0_user">user</a>: <b>address</b>, epoch: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="state.md#0x0_state_update_user">update_user</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="user.md#0x0_user">user</a>: <b>address</b>,
    epoch: u64,
) {
    <a href="state.md#0x0_state_add_new_user">add_new_user</a>(self, <a href="user.md#0x0_user">user</a>, epoch);
    <b>let</b> <a href="user.md#0x0_user">user</a> = &<b>mut</b> self.users[<a href="user.md#0x0_user">user</a>];
    <b>let</b> (prev_epoch, maker_volume, active_stake) = <a href="user.md#0x0_user">user</a>.<b>update</b>(epoch);
    <b>let</b> rebates = self.<a href="history.md#0x0_history">history</a>.calculate_rebate_amount(prev_epoch, maker_volume, active_stake);
    <a href="user.md#0x0_user">user</a>.add_rebates(rebates);
}
</code></pre>



</details>

<a name="0x0_state_add_new_user"></a>

## Function `add_new_user`



<pre><code><b>fun</b> <a href="state.md#0x0_state_add_new_user">add_new_user</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="user.md#0x0_user">user</a>: <b>address</b>, epoch: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="state.md#0x0_state_add_new_user">add_new_user</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="user.md#0x0_user">user</a>: <b>address</b>,
    epoch: u64,
) {
    <b>if</b> (!self.users.contains(<a href="user.md#0x0_user">user</a>)) {
        self.users.add(<a href="user.md#0x0_user">user</a>, <a href="user.md#0x0_user_empty">user::empty</a>(epoch));
    };
}
</code></pre>



</details>
