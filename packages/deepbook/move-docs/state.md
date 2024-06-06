
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
-  [Function `process_claim_rebates`](#0x0_state_process_claim_rebates)
-  [Function `governance`](#0x0_state_governance)
-  [Function `governance_mut`](#0x0_state_governance_mut)
-  [Function `account`](#0x0_state_account)
-  [Function `history_mut`](#0x0_state_history_mut)
-  [Function `update_account`](#0x0_state_update_account)


<pre><code><b>use</b> <a href="account.md#0x0_account">0x0::account</a>;
<b>use</b> <a href="balances.md#0x0_balances">0x0::balances</a>;
<b>use</b> <a href="fill.md#0x0_fill">0x0::fill</a>;
<b>use</b> <a href="governance.md#0x0_governance">0x0::governance</a>;
<b>use</b> <a href="history.md#0x0_history">0x0::history</a>;
<b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="order.md#0x0_order">0x0::order</a>;
<b>use</b> <a href="order_info.md#0x0_order_info">0x0::order_info</a>;
<b>use</b> <a href="trade_params.md#0x0_trade_params">0x0::trade_params</a>;
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
<code>accounts: <a href="dependencies/sui-framework/table.md#0x2_table_Table">table::Table</a>&lt;<a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, <a href="account.md#0x0_account_Account">account::Account</a>&gt;</code>
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
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_state_ENotEnoughStake"></a>



<pre><code><b>const</b> <a href="state.md#0x0_state_ENotEnoughStake">ENotEnoughStake</a>: u64 = 1;
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
    <b>let</b> <a href="governance.md#0x0_governance">governance</a> = <a href="governance.md#0x0_governance_empty">governance::empty</a>(ctx);
    <b>let</b> <a href="trade_params.md#0x0_trade_params">trade_params</a> = <a href="governance.md#0x0_governance">governance</a>.<a href="trade_params.md#0x0_trade_params">trade_params</a>();
    <b>let</b> <a href="history.md#0x0_history">history</a> = <a href="history.md#0x0_history_empty">history::empty</a>(<a href="trade_params.md#0x0_trade_params">trade_params</a>, ctx);

    <a href="state.md#0x0_state_State">State</a> {
        <a href="history.md#0x0_history">history</a>,
        <a href="governance.md#0x0_governance">governance</a>,
        accounts: <a href="dependencies/sui-framework/table.md#0x2_table_new">table::new</a>(ctx),
    }
}
</code></pre>



</details>

<a name="0x0_state_process_create"></a>

## Function `process_create`

Process order fills.
Update all maker settled balances and volumes.
Update taker settled balances and volumes.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_create">process_create</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="order_info.md#0x0_order_info">order_info</a>: &<b>mut</b> <a href="order_info.md#0x0_order_info_OrderInfo">order_info::OrderInfo</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (<a href="balances.md#0x0_balances_Balances">balances::Balances</a>, <a href="balances.md#0x0_balances_Balances">balances::Balances</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_create">process_create</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="order_info.md#0x0_order_info">order_info</a>: &<b>mut</b> OrderInfo,
    ctx: &TxContext,
): (Balances, Balances) {
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(self.<a href="governance.md#0x0_governance">governance</a>.<a href="trade_params.md#0x0_trade_params">trade_params</a>(), ctx);
    <b>let</b> fills = <a href="order_info.md#0x0_order_info">order_info</a>.fills();
    <b>let</b> <b>mut</b> i = 0;
    <b>while</b> (i &lt; fills.length()) {
        <b>let</b> <a href="fill.md#0x0_fill">fill</a> = &fills[i];
        <b>let</b> maker = <a href="fill.md#0x0_fill">fill</a>.balance_manager_id();
        self.<a href="state.md#0x0_state_update_account">update_account</a>(maker, ctx);
        <b>let</b> <a href="account.md#0x0_account">account</a> = &<b>mut</b> self.accounts[maker];
        <a href="account.md#0x0_account">account</a>.process_maker_fill(<a href="fill.md#0x0_fill">fill</a>);

        <b>let</b> volume = <a href="fill.md#0x0_fill">fill</a>.base_quantity();
        self.<a href="history.md#0x0_history">history</a>.add_volume(volume, <a href="account.md#0x0_account">account</a>.active_stake());

        i = i + 1;
    };

    self.<a href="state.md#0x0_state_update_account">update_account</a>(<a href="order_info.md#0x0_order_info">order_info</a>.balance_manager_id(), ctx);
    <b>let</b> <a href="account.md#0x0_account">account</a> = &<b>mut</b> self.accounts[<a href="order_info.md#0x0_order_info">order_info</a>.balance_manager_id()];
    <a href="account.md#0x0_account">account</a>.add_order(<a href="order_info.md#0x0_order_info">order_info</a>.order_id());
    <a href="account.md#0x0_account">account</a>.add_taker_volume(<a href="order_info.md#0x0_order_info">order_info</a>.executed_quantity());

    <b>let</b> account_volume = <a href="account.md#0x0_account">account</a>.total_volume();
    <b>let</b> account_stake = <a href="account.md#0x0_account">account</a>.active_stake();
    <b>let</b> taker_fee = self.<a href="governance.md#0x0_governance">governance</a>.<a href="trade_params.md#0x0_trade_params">trade_params</a>().taker_fee_for_user(account_stake, <a href="math.md#0x0_math_mul">math::mul</a>(account_volume, <a href="order_info.md#0x0_order_info">order_info</a>.deep_per_base()));
    <b>let</b> maker_fee = self.<a href="governance.md#0x0_governance">governance</a>.<a href="trade_params.md#0x0_trade_params">trade_params</a>().maker_fee();
    <b>let</b> (<b>mut</b> settled, <b>mut</b> owed) = <a href="order_info.md#0x0_order_info">order_info</a>.calculate_partial_fill_balances(taker_fee, maker_fee);
    <b>let</b> (old_settled, old_owed) = <a href="account.md#0x0_account">account</a>.settle();
    settled.add_balances(old_settled);
    owed.add_balances(old_owed);

    (settled, owed)
}
</code></pre>



</details>

<a name="0x0_state_process_cancel"></a>

## Function `process_cancel`

Update account settled balances and volumes.
Remove order from account orders.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_cancel">process_cancel</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="order.md#0x0_order">order</a>: &<b>mut</b> <a href="order.md#0x0_order_Order">order::Order</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (<a href="balances.md#0x0_balances_Balances">balances::Balances</a>, <a href="balances.md#0x0_balances_Balances">balances::Balances</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_cancel">process_cancel</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="order.md#0x0_order">order</a>: &<b>mut</b> Order,
    account_id: ID,
    ctx: &TxContext,
): (Balances, Balances) {
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(self.<a href="governance.md#0x0_governance">governance</a>.<a href="trade_params.md#0x0_trade_params">trade_params</a>(), ctx);
    self.<a href="state.md#0x0_state_update_account">update_account</a>(account_id, ctx);
    <a href="order.md#0x0_order">order</a>.set_canceled();

    <b>let</b> epoch = <a href="order.md#0x0_order">order</a>.epoch();
    <b>let</b> maker_fee = self.<a href="history.md#0x0_history">history</a>.historic_maker_fee(epoch);
    <b>let</b> <a href="balances.md#0x0_balances">balances</a> = <a href="order.md#0x0_order">order</a>.calculate_cancel_refund(maker_fee, <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>());

    <b>let</b> <a href="account.md#0x0_account">account</a> = &<b>mut</b> self.accounts[account_id];
    <a href="account.md#0x0_account">account</a>.remove_order(<a href="order.md#0x0_order">order</a>.order_id());
    <a href="account.md#0x0_account">account</a>.add_settled_balances(<a href="balances.md#0x0_balances">balances</a>);

    <a href="account.md#0x0_account">account</a>.settle()
}
</code></pre>



</details>

<a name="0x0_state_process_modify"></a>

## Function `process_modify`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_modify">process_modify</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, cancel_quantity: u64, <a href="order.md#0x0_order">order</a>: &<a href="order.md#0x0_order_Order">order::Order</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (<a href="balances.md#0x0_balances_Balances">balances::Balances</a>, <a href="balances.md#0x0_balances_Balances">balances::Balances</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_modify">process_modify</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
    cancel_quantity: u64,
    <a href="order.md#0x0_order">order</a>: &Order,
    ctx: &TxContext,
): (Balances, Balances) {
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(self.<a href="governance.md#0x0_governance">governance</a>.<a href="trade_params.md#0x0_trade_params">trade_params</a>(), ctx);
    self.<a href="state.md#0x0_state_update_account">update_account</a>(account_id, ctx);

    <b>let</b> epoch = <a href="order.md#0x0_order">order</a>.epoch();
    <b>let</b> maker_fee = self.<a href="history.md#0x0_history">history</a>.historic_maker_fee(epoch);
    <b>let</b> <a href="balances.md#0x0_balances">balances</a> = <a href="order.md#0x0_order">order</a>.calculate_cancel_refund(maker_fee, <a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(cancel_quantity));

    self.accounts[account_id].add_settled_balances(<a href="balances.md#0x0_balances">balances</a>);

    self.accounts[account_id].settle()
}
</code></pre>



</details>

<a name="0x0_state_process_stake"></a>

## Function `process_stake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_stake">process_stake</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, new_stake: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (<a href="balances.md#0x0_balances_Balances">balances::Balances</a>, <a href="balances.md#0x0_balances_Balances">balances::Balances</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_stake">process_stake</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
    new_stake: u64,
    ctx: &TxContext,
): (Balances, Balances) {
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(self.<a href="governance.md#0x0_governance">governance</a>.<a href="trade_params.md#0x0_trade_params">trade_params</a>(), ctx);
    self.<a href="state.md#0x0_state_update_account">update_account</a>(account_id, ctx);

    <b>let</b> (stake_before, stake_after) = self.accounts[account_id].add_stake(new_stake);
    self.<a href="governance.md#0x0_governance">governance</a>.adjust_voting_power(stake_before, stake_after);

    self.accounts[account_id].settle()
}
</code></pre>



</details>

<a name="0x0_state_process_unstake"></a>

## Function `process_unstake`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_unstake">process_unstake</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (<a href="balances.md#0x0_balances_Balances">balances::Balances</a>, <a href="balances.md#0x0_balances_Balances">balances::Balances</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_unstake">process_unstake</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
    ctx: &TxContext,
): (Balances, Balances) {
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(self.<a href="governance.md#0x0_governance">governance</a>.<a href="trade_params.md#0x0_trade_params">trade_params</a>(), ctx);
    self.<a href="state.md#0x0_state_update_account">update_account</a>(account_id, ctx);

    <b>let</b> <a href="account.md#0x0_account">account</a> = &<b>mut</b> self.accounts[account_id];
    <b>let</b> voted_stake = <a href="account.md#0x0_account">account</a>.active_stake();
    <b>let</b> voted_proposal = <a href="account.md#0x0_account">account</a>.voted_proposal();
    <a href="account.md#0x0_account">account</a>.remove_stake();
    self.<a href="governance.md#0x0_governance">governance</a>.adjust_voting_power(voted_stake, 0);
    self.<a href="governance.md#0x0_governance">governance</a>.adjust_vote(voted_proposal, <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(), voted_stake);

    <a href="account.md#0x0_account">account</a>.settle()
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
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(self.<a href="governance.md#0x0_governance">governance</a>.<a href="trade_params.md#0x0_trade_params">trade_params</a>(), ctx);
    self.<a href="state.md#0x0_state_update_account">update_account</a>(account_id, ctx);

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
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(self.<a href="governance.md#0x0_governance">governance</a>.<a href="trade_params.md#0x0_trade_params">trade_params</a>(), ctx);
    self.<a href="state.md#0x0_state_update_account">update_account</a>(account_id, ctx);

    <b>let</b> <a href="account.md#0x0_account">account</a> = &<b>mut</b> self.accounts[account_id];
    <b>assert</b>!(<a href="account.md#0x0_account">account</a>.active_stake() &gt;= <a href="state.md#0x0_state_STAKE_REQUIRED_TO_PARTICIPATE">STAKE_REQUIRED_TO_PARTICIPATE</a>, <a href="state.md#0x0_state_ENotEnoughStake">ENotEnoughStake</a>);

    <b>let</b> prev_proposal = <a href="account.md#0x0_account">account</a>.set_voted_proposal(<a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(proposal_id));
    self.<a href="governance.md#0x0_governance">governance</a>.adjust_vote(
        prev_proposal,
        <a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(proposal_id),
        <a href="account.md#0x0_account">account</a>.active_stake(),
    );
}
</code></pre>



</details>

<a name="0x0_state_process_claim_rebates"></a>

## Function `process_claim_rebates`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_process_claim_rebates">process_claim_rebates</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (<a href="balances.md#0x0_balances_Balances">balances::Balances</a>, <a href="balances.md#0x0_balances_Balances">balances::Balances</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_process_claim_rebates">process_claim_rebates</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
    ctx: &TxContext,
): (Balances, Balances) {
    self.<a href="governance.md#0x0_governance">governance</a>.<b>update</b>(ctx);
    self.<a href="history.md#0x0_history">history</a>.<b>update</b>(self.<a href="governance.md#0x0_governance">governance</a>.<a href="trade_params.md#0x0_trade_params">trade_params</a>(), ctx);
    self.<a href="state.md#0x0_state_update_account">update_account</a>(account_id, ctx);

    <b>let</b> <a href="account.md#0x0_account">account</a> = &<b>mut</b> self.accounts[account_id];
    <a href="account.md#0x0_account">account</a>.claim_rebates();

    <a href="account.md#0x0_account">account</a>.settle()
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



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="account.md#0x0_account">account</a>(self: &<a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>): &<a href="account.md#0x0_account_Account">account::Account</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="account.md#0x0_account">account</a>(
    self: &<a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
): &Account {
    &self.accounts[account_id]
}
</code></pre>



</details>

<a name="0x0_state_history_mut"></a>

## Function `history_mut`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_history_mut">history_mut</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>): &<b>mut</b> <a href="history.md#0x0_history_History">history::History</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="state.md#0x0_state_history_mut">history_mut</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
): &<b>mut</b> History {
    &<b>mut</b> self.<a href="history.md#0x0_history">history</a>
}
</code></pre>



</details>

<a name="0x0_state_update_account"></a>

## Function `update_account`



<pre><code><b>fun</b> <a href="state.md#0x0_state_update_account">update_account</a>(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="state.md#0x0_state_update_account">update_account</a>(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    account_id: ID,
    ctx: &TxContext,
) {
    <b>if</b> (!self.accounts.contains(account_id)) {
        self.accounts.add(account_id, <a href="account.md#0x0_account_empty">account::empty</a>(ctx));
    };

    <b>let</b> account_id = &<b>mut</b> self.accounts[account_id];
    <b>let</b> (prev_epoch, maker_volume, active_stake) = account_id.<b>update</b>(ctx);
    <b>if</b> (prev_epoch &gt; 0 && maker_volume &gt; 0 && active_stake &gt; 0) {
        <b>let</b> rebates = self.<a href="history.md#0x0_history">history</a>.calculate_rebate_amount(prev_epoch, maker_volume, active_stake);
        account_id.add_rebates(rebates);
    }
}
</code></pre>



</details>
