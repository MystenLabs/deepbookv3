
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
-  [Function `account`](#0x0_state_account)
-  [Function `account_mut`](#0x0_state_account_mut)
-  [Function `update_account`](#0x0_state_update_account)
-  [Function `add_new_account`](#0x0_state_add_new_account)


<pre><code><b>use</b> <a href="account_data.md#0x0_account_data">0x0::account_data</a>;
<b>use</b> <a href="deep_price.md#0x0_deep_price">0x0::deep_price</a>;
<b>use</b> <a href="governance.md#0x0_governance">0x0::governance</a>;
<b>use</b> <a href="history.md#0x0_history">0x0::history</a>;
<b>use</b> <a href="order.md#0x0_order">0x0::order</a>;
<b>use</b> <a href="order_info.md#0x0_order_info">0x0::order_info</a>;
<b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
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
<code>accounts: <a href="dependencies/sui-framework/table.md#0x2_table_Table">table::Table</a>&lt;<a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, <a href="account_data.md#0x0_account_data_AccountData">account_data::AccountData</a>&gt;</code>
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
        accounts: <a href="dependencies/sui-framework/table.md#0x2_table_new">table::new</a>(ctx),
        <a href="deep_price.md#0x0_deep_price">deep_price</a>: <a href="deep_price.md#0x0_deep_price_empty">deep_price::empty</a>(),
    }
}
</code></pre>



</details>

<a name="0x0_state_process_create"></a>

## Function `process_create`

Process order fills.
Update all maker settled balances and volumes.
Update taker settled balances and volumes.


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
        <b>let</b> (order_id, maker, expired, completed) = fill.fill_status();
        <b>let</b> (base, quote, deep) = fill.settled_quantities();
        <b>let</b> volume = fill.volume();
        self.<a href="state.md#0x0_state_update_account">update_account</a>(maker, ctx.epoch());

        <b>let</b> <a href="account_data.md#0x0_account_data">account_data</a> = &<b>mut</b> self.accounts[maker];
        <a href="account_data.md#0x0_account_data">account_data</a>.add_settled_amounts(base, quote, deep);
        <a href="account_data.md#0x0_account_data">account_data</a>.increase_maker_volume(volume);
        <b>if</b> (expired || completed) {
            <a href="account_data.md#0x0_account_data">account_data</a>.remove_order(order_id);
        };

        self.<a href="history.md#0x0_history">history</a>.add_volume(volume, <a href="account_data.md#0x0_account_data">account_data</a>.active_stake(), <a href="account_data.md#0x0_account_data">account_data</a>.maker_volume() == volume);

        i = i + 1;
    };

    self.<a href="state.md#0x0_state_update_account">update_account</a>(<a href="order_info.md#0x0_order_info">order_info</a>.account_id(), ctx.epoch());
    <b>let</b> <a href="account_data.md#0x0_account_data">account_data</a> = &<b>mut</b> self.accounts[<a href="order_info.md#0x0_order_info">order_info</a>.account_id()];
    <a href="account_data.md#0x0_account_data">account_data</a>.add_order(<a href="order_info.md#0x0_order_info">order_info</a>.order_id());
    <a href="account_data.md#0x0_account_data">account_data</a>.increase_taker_volume(<a href="order_info.md#0x0_order_info">order_info</a>.executed_quantity());
}
</code></pre>



</details>

<a name="0x0_state_process_cancel"></a>

## Function `process_cancel`

Update account settled balances and volumes.
Remove order from account orders.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_cancel">process_cancel</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="order.md#0x0_order">order</a>: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, order_id: u128, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_cancel">process_cancel</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="order.md#0x0_order">order</a>: &<b>mut</b> Order,
    order_id: u128,
    account_id: ID,
    ctx: &TxContext,
) {
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(ctx);
    <a href="order.md#0x0_order">order</a>.set_canceled();
    self.<a href="state.md#0x0_state_update_account">update_account</a>(account_id, ctx.epoch());

    <b>let</b> <a href="account_data.md#0x0_account_data">account_data</a> = &<b>mut</b> self.accounts[account_id];
    <b>let</b> cancel_quantity = <a href="order.md#0x0_order">order</a>.quantity();
    <b>let</b> (base_quantity, quote_quantity, deep_quantity) = <a href="order.md#0x0_order">order</a>.cancel_amounts(
        cancel_quantity,
        <b>false</b>,
    );
    <a href="account_data.md#0x0_account_data">account_data</a>.remove_order(order_id);
    <a href="account_data.md#0x0_account_data">account_data</a>.add_settled_amounts(base_quantity, quote_quantity, deep_quantity);
}
</code></pre>



</details>

<a name="0x0_state_process_modify"></a>

## Function `process_modify`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_modify">process_modify</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, base_quantity: u64, quote_quantity: u64, deep_quantity: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_modify">process_modify</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
    base_quantity: u64,
    quote_quantity: u64,
    deep_quantity: u64,
    ctx: &TxContext,
) {
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(ctx);
    self.<a href="state.md#0x0_state_update_account">update_account</a>(account_id, ctx.epoch());

    self.accounts[account_id].add_settled_amounts(base_quantity, quote_quantity, deep_quantity);
}
</code></pre>



</details>

<a name="0x0_state_process_stake"></a>

## Function `process_stake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_stake">process_stake</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, new_stake: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_stake">process_stake</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
    new_stake: u64,
    ctx: &TxContext,
) {
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(ctx);
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="state.md#0x0_state_update_account">update_account</a>(account_id, ctx.epoch());

    <b>let</b> (stake_before, stake_after) = self.accounts[account_id].add_stake(new_stake);
    self.<a href="governance.md#0x0_governance">governance</a>.adjust_voting_power(stake_before, stake_after);
}
</code></pre>



</details>

<a name="0x0_state_process_unstake"></a>

## Function `process_unstake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_unstake">process_unstake</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_unstake">process_unstake</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
    ctx: &TxContext,
) {
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(ctx);
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="state.md#0x0_state_update_account">update_account</a>(account_id, ctx.epoch());

    <b>let</b> <a href="account_data.md#0x0_account_data">account_data</a> = &<b>mut</b> self.accounts[account_id];
    <b>let</b> (total_stake, voted_proposal) = <a href="account_data.md#0x0_account_data">account_data</a>.remove_stake();
    self.<a href="governance.md#0x0_governance">governance</a>.adjust_voting_power(total_stake, 0);
    self.<a href="governance.md#0x0_governance">governance</a>.adjust_vote(voted_proposal, <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(), total_stake);
}
</code></pre>



</details>

<a name="0x0_state_process_proposal"></a>

## Function `process_proposal`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_proposal">process_proposal</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, taker_fee: u64, maker_fee: u64, stake_required: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_proposal">process_proposal</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
    ctx: &TxContext,
) {
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(ctx);
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="state.md#0x0_state_update_account">update_account</a>(account_id, ctx.epoch());

    <b>let</b> stake = self.accounts[account_id].active_stake();
    <b>assert</b>!(stake &gt;= <a href="state.md#0x0_state_STAKE_REQUIRED_TO_PARTICIPATE">STAKE_REQUIRED_TO_PARTICIPATE</a>, <a href="state.md#0x0_state_ENotEnoughStake">ENotEnoughStake</a>);

    self.<a href="governance.md#0x0_governance">governance</a>.add_proposal(taker_fee, maker_fee, stake_required, stake, account_id);
    self.<a href="state.md#0x0_state_process_vote">process_vote</a>(account_id, account_id, ctx);
}
</code></pre>



</details>

<a name="0x0_state_process_vote"></a>

## Function `process_vote`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_vote">process_vote</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, proposal_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_vote">process_vote</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
    proposal_id: ID,
    ctx: &TxContext,
) {
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(ctx);
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="state.md#0x0_state_update_account">update_account</a>(account_id, ctx.epoch());

    <b>let</b> <a href="account_data.md#0x0_account_data">account_data</a> = &<b>mut</b> self.accounts[account_id];
    <b>assert</b>!(<a href="account_data.md#0x0_account_data">account_data</a>.active_stake() &gt;= <a href="state.md#0x0_state_STAKE_REQUIRED_TO_PARTICIPATE">STAKE_REQUIRED_TO_PARTICIPATE</a>, <a href="state.md#0x0_state_ENotEnoughStake">ENotEnoughStake</a>);

    <b>let</b> prev_proposal = <a href="account_data.md#0x0_account_data">account_data</a>.set_voted_proposal(<a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(proposal_id));
    self.<a href="governance.md#0x0_governance">governance</a>.adjust_vote(
        prev_proposal,
        <a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(proposal_id),
        <a href="account_data.md#0x0_account_data">account_data</a>.active_stake(),
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

<a name="0x0_state_account"></a>

## Function `account`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account">account</a>(self: &<a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>): &<a href="account_data.md#0x0_account_data_AccountData">account_data::AccountData</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account">account</a>(
    self: &<a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
): &AccountData {
    &self.accounts[account_id]
}
</code></pre>



</details>

<a name="0x0_state_account_mut"></a>

## Function `account_mut`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_account_mut">account_mut</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, epoch: u64): &<b>mut</b> <a href="account_data.md#0x0_account_data_AccountData">account_data::AccountData</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_account_mut">account_mut</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
    epoch: u64,
): &<b>mut</b> AccountData {
    self.<a href="state.md#0x0_state_update_account">update_account</a>(account_id, epoch);

    &<b>mut</b> self.accounts[account_id]
}
</code></pre>



</details>

<a name="0x0_state_update_account"></a>

## Function `update_account`



<pre><code><b>fun</b> <a href="state.md#0x0_state_update_account">update_account</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, epoch: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="state.md#0x0_state_update_account">update_account</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
    epoch: u64,
) {
    <a href="state.md#0x0_state_add_new_account">add_new_account</a>(self, account_id, epoch);
    <b>let</b> account_id = &<b>mut</b> self.accounts[account_id];
    <b>let</b> (prev_epoch, maker_volume, active_stake) = account_id.<b>update</b>(epoch);
    <b>if</b> (prev_epoch &gt; 0 && maker_volume &gt; 0 && active_stake &gt; 0) {
        <b>let</b> rebates = self.<a href="history.md#0x0_history">history</a>.calculate_rebate_amount(prev_epoch, maker_volume, active_stake);
        account_id.add_rebates(rebates);
    }
}
</code></pre>



</details>

<a name="0x0_state_add_new_account"></a>

## Function `add_new_account`



<pre><code><b>fun</b> <a href="state.md#0x0_state_add_new_account">add_new_account</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, epoch: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="state.md#0x0_state_add_new_account">add_new_account</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
    epoch: u64,
) {
    <b>if</b> (!self.accounts.contains(account_id)) {
        self.accounts.add(account_id, <a href="account_data.md#0x0_account_data_empty">account_data::empty</a>(epoch));
    };
}
</code></pre>



</details>
