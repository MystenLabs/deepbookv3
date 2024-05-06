
<a name="0x0_state"></a>

# Module `0x0::state`



-  [Resource `State`](#0x0_state_State)
-  [Constants](#@Constants_0)
-  [Function `create_and_share`](#0x0_state_create_and_share)
-  [Function `create_pool`](#0x0_state_create_pool)
-  [Function `set_pool_as_stable`](#0x0_state_set_pool_as_stable)
-  [Function `add_deep_price_point`](#0x0_state_add_deep_price_point)
-  [Function `add_reference_pool`](#0x0_state_add_reference_pool)
-  [Function `stake`](#0x0_state_stake)
-  [Function `unstake`](#0x0_state_unstake)
-  [Function `submit_proposal`](#0x0_state_submit_proposal)
-  [Function `vote`](#0x0_state_vote)
-  [Function `get_pool_metadata_mut`](#0x0_state_get_pool_metadata_mut)
-  [Function `apply_winning_proposal`](#0x0_state_apply_winning_proposal)


<pre><code><b>use</b> <a href="account.md#0x0_account">0x0::account</a>;
<b>use</b> <a href="deep_reference_price.md#0x0_deep_reference_price">0x0::deep_reference_price</a>;
<b>use</b> <a href="pool.md#0x0_pool">0x0::pool</a>;
<b>use</b> <a href="pool_metadata.md#0x0_pool_metadata">0x0::pool_metadata</a>;
<b>use</b> <a href="state_manager.md#0x0_state_manager">0x0::state_manager</a>;
<b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
<b>use</b> <a href="dependencies/sui-framework/bag.md#0x2_bag">0x2::bag</a>;
<b>use</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">0x2::balance</a>;
<b>use</b> <a href="dependencies/sui-framework/coin.md#0x2_coin">0x2::coin</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
<b>use</b> <a href="dependencies/sui-framework/sui.md#0x2_sui">0x2::sui</a>;
<b>use</b> <a href="dependencies/sui-framework/transfer.md#0x2_transfer">0x2::transfer</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
</code></pre>



<a name="0x0_state_State"></a>

## Resource `State`



<pre><code><b>struct</b> <a href="state.md#0x0_state_State">State</a> <b>has</b> key
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
<dt>
<code>deep_reference_pools: <a href="deep_reference_price.md#0x0_deep_reference_price_DeepReferencePools">deep_reference_price::DeepReferencePools</a></code>
</dt>
<dd>

</dd>
<dt>
<code>vault: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;<a href="pool.md#0x0_pool_DEEP">pool::DEEP</a>&gt;</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_state_DEFAULT_MAKER_FEE"></a>



<pre><code><b>const</b> <a href="state.md#0x0_state_DEFAULT_MAKER_FEE">DEFAULT_MAKER_FEE</a>: u64 = 500;
</code></pre>



<a name="0x0_state_DEFAULT_TAKER_FEE"></a>



<pre><code><b>const</b> <a href="state.md#0x0_state_DEFAULT_TAKER_FEE">DEFAULT_TAKER_FEE</a>: u64 = 1000;
</code></pre>



<a name="0x0_state_ENotEnoughStake"></a>



<pre><code><b>const</b> <a href="state.md#0x0_state_ENotEnoughStake">ENotEnoughStake</a>: u64 = 3;
</code></pre>



<a name="0x0_state_EPoolAlreadyExists"></a>



<pre><code><b>const</b> <a href="state.md#0x0_state_EPoolAlreadyExists">EPoolAlreadyExists</a>: u64 = 2;
</code></pre>



<a name="0x0_state_EPoolDoesNotExist"></a>



<pre><code><b>const</b> <a href="state.md#0x0_state_EPoolDoesNotExist">EPoolDoesNotExist</a>: u64 = 1;
</code></pre>



<a name="0x0_state_STAKE_REQUIRED_TO_PARTICIPATE"></a>



<pre><code><b>const</b> <a href="state.md#0x0_state_STAKE_REQUIRED_TO_PARTICIPATE">STAKE_REQUIRED_TO_PARTICIPATE</a>: u64 = 100;
</code></pre>



<a name="0x0_state_create_and_share"></a>

## Function `create_and_share`

Create a new State and share it. Called once during init.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_create_and_share">create_and_share</a>(ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state.md#0x0_state_create_and_share">create_and_share</a>(ctx: &<b>mut</b> TxContext) {
    <b>let</b> <a href="state.md#0x0_state">state</a> = <a href="state.md#0x0_state_State">State</a> {
        id: <a href="dependencies/sui-framework/object.md#0x2_object_new">object::new</a>(ctx),
        pools: <a href="dependencies/sui-framework/bag.md#0x2_bag_new">bag::new</a>(ctx),
        deep_reference_pools: <a href="deep_reference_price.md#0x0_deep_reference_price_new">deep_reference_price::new</a>(),
        vault: <a href="dependencies/sui-framework/balance.md#0x2_balance_zero">balance::zero</a>(),
    };
    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_share_object">transfer::share_object</a>(<a href="state.md#0x0_state">state</a>);
}
</code></pre>



</details>

<a name="0x0_state_create_pool"></a>

## Function `create_pool`

Create a new pool. Calls create_pool inside Pool then registers it in
the state. <code>pool_key</code> is a sorted, concatenated string of the two asset
names. If SUI/USDC exists, you can't create USDC/SUI.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_create_pool">create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, tick_size: u64, lot_size: u64, min_size: u64, creation_fee: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;<a href="dependencies/sui-framework/sui.md#0x2_sui_SUI">sui::SUI</a>&gt;, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state.md#0x0_state_create_pool">create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    creation_fee: Balance&lt;SUI&gt;,
    ctx: &<b>mut</b> TxContext,
) {
    <b>let</b> (pool_key, rev_key) = <a href="pool.md#0x0_pool_create_pool">pool::create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(
        <a href="state.md#0x0_state_DEFAULT_TAKER_FEE">DEFAULT_TAKER_FEE</a>,
        <a href="state.md#0x0_state_DEFAULT_MAKER_FEE">DEFAULT_MAKER_FEE</a>,
        tick_size,
        lot_size,
        min_size,
        creation_fee,
        ctx
    );

    <b>assert</b>!(!self.pools.contains(pool_key) && !self.pools.contains(rev_key), <a href="state.md#0x0_state_EPoolAlreadyExists">EPoolAlreadyExists</a>);

    <b>let</b> <a href="pool_metadata.md#0x0_pool_metadata">pool_metadata</a> = <a href="pool_metadata.md#0x0_pool_metadata_empty">pool_metadata::empty</a>(ctx.epoch());
    self.pools.add(pool_key, <a href="pool_metadata.md#0x0_pool_metadata">pool_metadata</a>);
}
</code></pre>



</details>

<a name="0x0_state_set_pool_as_stable"></a>

## Function `set_pool_as_stable`

Set the as stable or volatile. This changes the fee structure of the pool.
New proposals will be asserted against the new fee structure.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_set_pool_as_stable">set_pool_as_stable</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="pool.md#0x0_pool">pool</a>: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, stable: bool, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state.md#0x0_state_set_pool_as_stable">set_pool_as_stable</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="pool.md#0x0_pool">pool</a>: &Pool&lt;BaseAsset, QuoteAsset&gt;,
    stable: bool,
    ctx: &TxContext,
) {
    self.<a href="state.md#0x0_state_get_pool_metadata_mut">get_pool_metadata_mut</a>(<a href="pool.md#0x0_pool">pool</a>, ctx)
        .set_as_stable(stable);

    // TODO: set fees
}
</code></pre>



</details>

<a name="0x0_state_add_deep_price_point"></a>

## Function `add_deep_price_point`

Insert a DEEP data point into a pool.
reference_pool is a DEEP pool, ie DEEP/USDC. This will be validated against DeepPriceReferencePools.
pool is the Pool that will have the DEEP data point added.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_add_deep_price_point">add_deep_price_point</a>&lt;BaseAsset, QuoteAsset, DEEPBaseAsset, DEEPQuoteAsset&gt;(self: &<a href="state.md#0x0_state_State">state::State</a>, reference_pool: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;DEEPBaseAsset, DEEPQuoteAsset&gt;, timestamp: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state.md#0x0_state_add_deep_price_point">add_deep_price_point</a>&lt;BaseAsset, QuoteAsset, DEEPBaseAsset, DEEPQuoteAsset&gt;(
    self: &<a href="state.md#0x0_state_State">State</a>,
    reference_pool: &Pool&lt;BaseAsset, QuoteAsset&gt;,
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;DEEPBaseAsset, DEEPQuoteAsset&gt;,
    timestamp: u64,
) {
    <b>let</b> (base_conversion_rate, quote_conversion_rate) = self.deep_reference_pools
        .get_conversion_rates(reference_pool, <a href="pool.md#0x0_pool">pool</a>);

    <a href="pool.md#0x0_pool">pool</a>.<a href="state.md#0x0_state_add_deep_price_point">add_deep_price_point</a>(
        base_conversion_rate,
        quote_conversion_rate,
        timestamp,
    );
}
</code></pre>



</details>

<a name="0x0_state_add_reference_pool"></a>

## Function `add_reference_pool`

Add a DEEP reference pool: DEEP/USDC, DEEP/SUI, etc.
This will be used to validate DEEP data points.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_add_reference_pool">add_reference_pool</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, reference_pool: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state.md#0x0_state_add_reference_pool">add_reference_pool</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    reference_pool: &Pool&lt;BaseAsset, QuoteAsset&gt;,
) {
    self.deep_reference_pools.<a href="state.md#0x0_state_add_reference_pool">add_reference_pool</a>(reference_pool);
}
</code></pre>



</details>

<a name="0x0_state_stake"></a>

## Function `stake`

Stake DEEP in the pool. This will increase the user's voting power next epoch
Individual user stakes are stored inside of the pool.
A user's stake is tracked as stake_amount, staked before current epoch, their "active" amount,
and next_stake_amount, stake_amount + new stake during this epoch. Upon refresh, stake_amount = next_stake_amount.
Total voting power is maintained in the pool metadata.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_stake">stake</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, amount: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state.md#0x0_state_stake">stake</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    amount: u64,
    ctx: &<b>mut</b> TxContext,
) {
    <b>let</b> user = <a href="account.md#0x0_account">account</a>.owner();
    <b>let</b> total_stake = <a href="pool.md#0x0_pool">pool</a>.increase_user_stake(user, amount, ctx);
    self.<a href="state.md#0x0_state_get_pool_metadata_mut">get_pool_metadata_mut</a>(<a href="pool.md#0x0_pool">pool</a>, ctx)
        .adjust_voting_power(total_stake, total_stake - amount);
    <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = <a href="account.md#0x0_account">account</a>.withdraw_with_proof&lt;DEEP&gt;(proof, amount, <b>false</b>, ctx).into_balance();
    self.vault.join(<a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
}
</code></pre>



</details>

<a name="0x0_state_unstake"></a>

## Function `unstake`

Unstake DEEP in the pool. This will decrease the user's voting power.
All stake for this user will be removed.
If the user has voted, their vote will be removed.
If the user had accumulated rebates during this epoch, they will be forfeited.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_unstake">unstake</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state.md#0x0_state_unstake">unstake</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    ctx: &<b>mut</b> TxContext
) {
    <b>let</b> user = <a href="account.md#0x0_account">account</a>.owner();
    <b>let</b> total_stake = <a href="pool.md#0x0_pool">pool</a>.remove_user_stake(user, ctx);
    <b>let</b> prev_proposal_id = <a href="pool.md#0x0_pool">pool</a>.set_user_voted_proposal(user, <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(), ctx);
    <b>if</b> (prev_proposal_id.is_some()) {
        <b>let</b> <a href="pool_metadata.md#0x0_pool_metadata">pool_metadata</a> = self.<a href="state.md#0x0_state_get_pool_metadata_mut">get_pool_metadata_mut</a>(<a href="pool.md#0x0_pool">pool</a>, ctx);
        <a href="pool_metadata.md#0x0_pool_metadata">pool_metadata</a>.adjust_voting_power(0, total_stake);
        <b>let</b> winning_proposal = <a href="pool_metadata.md#0x0_pool_metadata">pool_metadata</a>.<a href="state.md#0x0_state_vote">vote</a>(<a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(), prev_proposal_id, total_stake);
        self.<a href="state.md#0x0_state_apply_winning_proposal">apply_winning_proposal</a>(<a href="pool.md#0x0_pool">pool</a>, winning_proposal);
    };

    <b>let</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a> = self.vault.split(total_stake).into_coin(ctx);
    <a href="account.md#0x0_account">account</a>.deposit_with_proof&lt;DEEP&gt;(proof, <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>);
}
</code></pre>



</details>

<a name="0x0_state_submit_proposal"></a>

## Function `submit_proposal`

Submit a proposal to change the fee structure of a pool.
The user submitting this proposal must have vested stake in the pool.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_submit_proposal">submit_proposal</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="pool.md#0x0_pool">pool</a>: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user: <b>address</b>, maker_fee: u64, taker_fee: u64, stake_required: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state.md#0x0_state_submit_proposal">submit_proposal</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="pool.md#0x0_pool">pool</a>: &Pool&lt;BaseAsset, QuoteAsset&gt;,
    user: <b>address</b>,
    maker_fee: u64,
    taker_fee: u64,
    stake_required: u64,
    ctx: &TxContext,
) {
    <b>let</b> (stake, _) = <a href="pool.md#0x0_pool">pool</a>.get_user_stake(user, ctx);
    <b>assert</b>!(stake &gt;= <a href="state.md#0x0_state_STAKE_REQUIRED_TO_PARTICIPATE">STAKE_REQUIRED_TO_PARTICIPATE</a>, <a href="state.md#0x0_state_ENotEnoughStake">ENotEnoughStake</a>);

    <b>let</b> <a href="pool_metadata.md#0x0_pool_metadata">pool_metadata</a> = self.<a href="state.md#0x0_state_get_pool_metadata_mut">get_pool_metadata_mut</a>(<a href="pool.md#0x0_pool">pool</a>, ctx);
    <a href="pool_metadata.md#0x0_pool_metadata">pool_metadata</a>.add_proposal(maker_fee, taker_fee, stake_required);
}
</code></pre>



</details>

<a name="0x0_state_vote"></a>

## Function `vote`

Vote on a proposal using the user's full voting power.
If the vote pushes proposal over quorum, PoolData is created.
Set the Pool's next_pool_data with the created PoolData.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="state.md#0x0_state_vote">vote</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user: <b>address</b>, proposal_id: u64, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="state.md#0x0_state_vote">vote</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;BaseAsset, QuoteAsset&gt;,
    user: <b>address</b>,
    proposal_id: u64,
    ctx: &TxContext,
) {
    <b>let</b> (stake, _) = <a href="pool.md#0x0_pool">pool</a>.get_user_stake(user, ctx);
    <b>assert</b>!(stake &gt;= <a href="state.md#0x0_state_STAKE_REQUIRED_TO_PARTICIPATE">STAKE_REQUIRED_TO_PARTICIPATE</a>, <a href="state.md#0x0_state_ENotEnoughStake">ENotEnoughStake</a>);
    <b>let</b> prev_proposal_id = <a href="pool.md#0x0_pool">pool</a>.set_user_voted_proposal(user, <a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(proposal_id), ctx);

    <b>let</b> <a href="pool_metadata.md#0x0_pool_metadata">pool_metadata</a> = self.<a href="state.md#0x0_state_get_pool_metadata_mut">get_pool_metadata_mut</a>(<a href="pool.md#0x0_pool">pool</a>, ctx);
    <b>let</b> winning_proposal = <a href="pool_metadata.md#0x0_pool_metadata">pool_metadata</a>.<a href="state.md#0x0_state_vote">vote</a>(<a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(proposal_id), prev_proposal_id, stake);
    self.<a href="state.md#0x0_state_apply_winning_proposal">apply_winning_proposal</a>(<a href="pool.md#0x0_pool">pool</a>, winning_proposal);
}
</code></pre>



</details>

<a name="0x0_state_get_pool_metadata_mut"></a>

## Function `get_pool_metadata_mut`

Check whether pool exists, refresh and return its metadata.


<pre><code><b>fun</b> <a href="state.md#0x0_state_get_pool_metadata_mut">get_pool_metadata_mut</a>&lt;BaseAsset, QuoteAsset&gt;(self: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="pool.md#0x0_pool">pool</a>: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">pool_metadata::PoolMetadata</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="state.md#0x0_state_get_pool_metadata_mut">get_pool_metadata_mut</a>&lt;BaseAsset, QuoteAsset&gt;(
    self: &<b>mut</b> <a href="state.md#0x0_state_State">State</a>,
    <a href="pool.md#0x0_pool">pool</a>: &Pool&lt;BaseAsset, QuoteAsset&gt;,
    ctx: &TxContext
): &<b>mut</b> PoolMetadata {
    <b>let</b> pool_key = <a href="pool.md#0x0_pool">pool</a>.key();
    <b>assert</b>!(self.pools.contains(pool_key), <a href="state.md#0x0_state_EPoolDoesNotExist">EPoolDoesNotExist</a>);

    <b>let</b> <a href="pool_metadata.md#0x0_pool_metadata">pool_metadata</a>: &<b>mut</b> PoolMetadata = &<b>mut</b> self.pools[pool_key];
    <a href="pool_metadata.md#0x0_pool_metadata">pool_metadata</a>.refresh(ctx.epoch());
    <a href="pool_metadata.md#0x0_pool_metadata">pool_metadata</a>
}
</code></pre>



</details>

<a name="0x0_state_apply_winning_proposal"></a>

## Function `apply_winning_proposal`



<pre><code><b>fun</b> <a href="state.md#0x0_state_apply_winning_proposal">apply_winning_proposal</a>&lt;BaseAsset, QuoteAsset&gt;(_self: &<a href="state.md#0x0_state_State">state::State</a>, <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, winning_proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="pool_metadata.md#0x0_pool_metadata_Proposal">pool_metadata::Proposal</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="state.md#0x0_state_apply_winning_proposal">apply_winning_proposal</a>&lt;BaseAsset, QuoteAsset&gt;(
    _self: &<a href="state.md#0x0_state_State">State</a>,
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;BaseAsset, QuoteAsset&gt;,
    winning_proposal: Option&lt;Proposal&gt;,
) {
    <b>let</b> next_trade_params = <b>if</b> (winning_proposal.is_none()) {
        <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>()
    } <b>else</b> {
        <b>let</b> (stake_required, taker_fee, maker_fee) = winning_proposal
            .borrow()
            .proposal_params();

        <b>let</b> fees = <a href="state_manager.md#0x0_state_manager_new_trade_params">state_manager::new_trade_params</a>(taker_fee, maker_fee, stake_required);
        <a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(fees)
    };
    <a href="pool.md#0x0_pool">pool</a>.set_next_trade_params(next_trade_params);
}
</code></pre>



</details>
