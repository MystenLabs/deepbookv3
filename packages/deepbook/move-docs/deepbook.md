
<a name="0x0_deepbook"></a>

# Module `0x0::deepbook`

Public-facing interface for the package.
TODO: No authorization checks are implemented;


-  [Resource `DeepBookAdminCap`](#0x0_deepbook_DeepBookAdminCap)
-  [Struct `DEEPBOOK`](#0x0_deepbook_DEEPBOOK)
-  [Function `init`](#0x0_deepbook_init)
-  [Function `create_pool`](#0x0_deepbook_create_pool)
-  [Function `set_pool_as_stable`](#0x0_deepbook_set_pool_as_stable)
-  [Function `add_reference_pool`](#0x0_deepbook_add_reference_pool)
-  [Function `add_deep_price_point`](#0x0_deepbook_add_deep_price_point)
-  [Function `claim_rebates`](#0x0_deepbook_claim_rebates)
-  [Function `stake`](#0x0_deepbook_stake)
-  [Function `unstake`](#0x0_deepbook_unstake)
-  [Function `submit_proposal`](#0x0_deepbook_submit_proposal)
-  [Function `vote`](#0x0_deepbook_vote)
-  [Function `place_limit_order`](#0x0_deepbook_place_limit_order)
-  [Function `place_market_order`](#0x0_deepbook_place_market_order)
-  [Function `cancel_order`](#0x0_deepbook_cancel_order)
-  [Function `cancel_all_orders`](#0x0_deepbook_cancel_all_orders)
-  [Function `user_open_orders`](#0x0_deepbook_user_open_orders)
-  [Function `get_amount_out`](#0x0_deepbook_get_amount_out)
-  [Function `get_level2_bids`](#0x0_deepbook_get_level2_bids)
-  [Function `get_level2_asks`](#0x0_deepbook_get_level2_asks)
-  [Function `get_level2_ticks_from_mid`](#0x0_deepbook_get_level2_ticks_from_mid)


<pre><code><b>use</b> <a href="account.md#0x0_account">0x0::account</a>;
<b>use</b> <a href="pool.md#0x0_pool">0x0::pool</a>;
<b>use</b> <a href="state.md#0x0_state">0x0::state</a>;
<b>use</b> <a href="dependencies/sui-framework/balance.md#0x2_balance">0x2::balance</a>;
<b>use</b> <a href="dependencies/sui-framework/clock.md#0x2_clock">0x2::clock</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
<b>use</b> <a href="dependencies/sui-framework/package.md#0x2_package">0x2::package</a>;
<b>use</b> <a href="dependencies/sui-framework/sui.md#0x2_sui">0x2::sui</a>;
<b>use</b> <a href="dependencies/sui-framework/transfer.md#0x2_transfer">0x2::transfer</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
<b>use</b> <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set">0x2::vec_set</a>;
</code></pre>



<a name="0x0_deepbook_DeepBookAdminCap"></a>

## Resource `DeepBookAdminCap`

DeepBookAdminCap is used to call admin functions.


<pre><code><b>struct</b> <a href="deepbook.md#0x0_deepbook_DeepBookAdminCap">DeepBookAdminCap</a> <b>has</b> store, key
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

<a name="0x0_deepbook_DEEPBOOK"></a>

## Struct `DEEPBOOK`

The one-time-witness used to claim Publisher object.


<pre><code><b>struct</b> <a href="deepbook.md#0x0_deepbook_DEEPBOOK">DEEPBOOK</a> <b>has</b> drop
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

<a name="0x0_deepbook_init"></a>

## Function `init`



<pre><code><b>fun</b> <a href="deepbook.md#0x0_deepbook_init">init</a>(otw: <a href="deepbook.md#0x0_deepbook_DEEPBOOK">deepbook::DEEPBOOK</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="deepbook.md#0x0_deepbook_init">init</a>(otw: <a href="deepbook.md#0x0_deepbook_DEEPBOOK">DEEPBOOK</a>, ctx: &<b>mut</b> TxContext) {
    sui::package::claim_and_keep(otw, ctx);
    <a href="state.md#0x0_state_create_and_share">state::create_and_share</a>(ctx);
    <b>let</b> cap = <a href="deepbook.md#0x0_deepbook_DeepBookAdminCap">DeepBookAdminCap</a> {
        id: <a href="dependencies/sui-framework/object.md#0x2_object_new">object::new</a>(ctx),
    };
    <a href="dependencies/sui-framework/transfer.md#0x2_transfer_transfer">transfer::transfer</a>(cap, ctx.sender());
}
</code></pre>



</details>

<a name="0x0_deepbook_create_pool"></a>

## Function `create_pool`

Public facing function to create a pool.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_create_pool">create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="state.md#0x0_state">state</a>: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, tick_size: u64, lot_size: u64, min_size: u64, creation_fee: <a href="dependencies/sui-framework/balance.md#0x2_balance_Balance">balance::Balance</a>&lt;<a href="dependencies/sui-framework/sui.md#0x2_sui_SUI">sui::SUI</a>&gt;, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_create_pool">create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="state.md#0x0_state">state</a>: &<b>mut</b> State,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    creation_fee: Balance&lt;SUI&gt;,
    ctx: &<b>mut</b> TxContext
) {
    <a href="state.md#0x0_state">state</a>.<a href="deepbook.md#0x0_deepbook_create_pool">create_pool</a>&lt;BaseAsset, QuoteAsset&gt;(
        tick_size, lot_size, min_size, creation_fee, ctx
    );
}
</code></pre>



</details>

<a name="0x0_deepbook_set_pool_as_stable"></a>

## Function `set_pool_as_stable`

Public facing function to set a pool as stable.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_set_pool_as_stable">set_pool_as_stable</a>&lt;BaseAsset, QuoteAsset&gt;(_cap: &<a href="deepbook.md#0x0_deepbook_DeepBookAdminCap">deepbook::DeepBookAdminCap</a>, <a href="state.md#0x0_state">state</a>: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="pool.md#0x0_pool">pool</a>: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, stable: bool, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_set_pool_as_stable">set_pool_as_stable</a>&lt;BaseAsset, QuoteAsset&gt;(
    _cap: &<a href="deepbook.md#0x0_deepbook_DeepBookAdminCap">DeepBookAdminCap</a>,
    <a href="state.md#0x0_state">state</a>: &<b>mut</b> State,
    <a href="pool.md#0x0_pool">pool</a>: &Pool&lt;BaseAsset, QuoteAsset&gt;,
    stable: bool,
    ctx: &TxContext,
) {
    <a href="state.md#0x0_state">state</a>.<a href="deepbook.md#0x0_deepbook_set_pool_as_stable">set_pool_as_stable</a>(<a href="pool.md#0x0_pool">pool</a>, stable, ctx);
}
</code></pre>



</details>

<a name="0x0_deepbook_add_reference_pool"></a>

## Function `add_reference_pool`

Public facing function to add a reference pool.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_add_reference_pool">add_reference_pool</a>&lt;BaseAsset, QuoteAsset&gt;(_cap: &<a href="deepbook.md#0x0_deepbook_DeepBookAdminCap">deepbook::DeepBookAdminCap</a>, <a href="state.md#0x0_state">state</a>: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, reference_pool: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_add_reference_pool">add_reference_pool</a>&lt;BaseAsset, QuoteAsset&gt;(
    _cap: &<a href="deepbook.md#0x0_deepbook_DeepBookAdminCap">DeepBookAdminCap</a>,
    <a href="state.md#0x0_state">state</a>: &<b>mut</b> State,
    reference_pool: &Pool&lt;BaseAsset, QuoteAsset&gt;,
) {
    <a href="state.md#0x0_state">state</a>.<a href="deepbook.md#0x0_deepbook_add_reference_pool">add_reference_pool</a>&lt;BaseAsset, QuoteAsset&gt;(reference_pool);
}
</code></pre>



</details>

<a name="0x0_deepbook_add_deep_price_point"></a>

## Function `add_deep_price_point`

Public facing function to add a deep price point into a specific pool.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_add_deep_price_point">add_deep_price_point</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="state.md#0x0_state">state</a>: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, reference_pool: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_add_deep_price_point">add_deep_price_point</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="state.md#0x0_state">state</a>: &<b>mut</b> State,
    reference_pool: &Pool&lt;BaseAsset, QuoteAsset&gt;, // DEEP Price or assertion
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;BaseAsset, QuoteAsset&gt;,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
) {
    <a href="state.md#0x0_state">state</a>.<a href="deepbook.md#0x0_deepbook_add_deep_price_point">add_deep_price_point</a>(
        reference_pool, <a href="pool.md#0x0_pool">pool</a>, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>
    );
    // Determine frequency this is done
}
</code></pre>



</details>

<a name="0x0_deepbook_claim_rebates"></a>

## Function `claim_rebates`

Public facing function to remove a deep price point from a specific pool.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_claim_rebates">claim_rebates</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_claim_rebates">claim_rebates</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    ctx: &<b>mut</b> TxContext
) {
    <a href="pool.md#0x0_pool">pool</a>.<a href="deepbook.md#0x0_deepbook_claim_rebates">claim_rebates</a>(<a href="account.md#0x0_account">account</a>, proof, ctx)
}
</code></pre>



</details>

<a name="0x0_deepbook_stake"></a>

## Function `stake`

Public facing function to stake DEEP tokens against a specific pool.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_stake">stake</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="state.md#0x0_state">state</a>: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, amount: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_stake">stake</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="state.md#0x0_state">state</a>: &<b>mut</b> State,
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    amount: u64,
    ctx: &<b>mut</b> TxContext,
) {
    <a href="state.md#0x0_state">state</a>.<a href="deepbook.md#0x0_deepbook_stake">stake</a>(<a href="pool.md#0x0_pool">pool</a>, <a href="account.md#0x0_account">account</a>, proof, amount, ctx)
}
</code></pre>



</details>

<a name="0x0_deepbook_unstake"></a>

## Function `unstake`

Public facing function to unstake DEEP tokens from a specific pool.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_unstake">unstake</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="state.md#0x0_state">state</a>: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_unstake">unstake</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="state.md#0x0_state">state</a>: &<b>mut</b> State,
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    ctx: &<b>mut</b> TxContext
) {
    <a href="state.md#0x0_state">state</a>.<a href="deepbook.md#0x0_deepbook_unstake">unstake</a>(<a href="pool.md#0x0_pool">pool</a>, <a href="account.md#0x0_account">account</a>, proof, ctx)
}
</code></pre>



</details>

<a name="0x0_deepbook_submit_proposal"></a>

## Function `submit_proposal`

Public facing function to submit a proposal.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_submit_proposal">submit_proposal</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="state.md#0x0_state">state</a>: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, maker_fee: u64, taker_fee: u64, stake_required: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_submit_proposal">submit_proposal</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="state.md#0x0_state">state</a>: &<b>mut</b> State,
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &Account,
    proof: &TradeProof,
    maker_fee: u64,
    taker_fee: u64,
    stake_required: u64,
    ctx: &<b>mut</b> TxContext,
) {
    <a href="account.md#0x0_account">account</a>.validate_proof(proof);

    <a href="state.md#0x0_state">state</a>.<a href="deepbook.md#0x0_deepbook_submit_proposal">submit_proposal</a>(
        <a href="pool.md#0x0_pool">pool</a>, <a href="account.md#0x0_account">account</a>.owner(), maker_fee, taker_fee, stake_required, ctx
    )
}
</code></pre>



</details>

<a name="0x0_deepbook_vote"></a>

## Function `vote`

Public facing function to vote on a proposal.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_vote">vote</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="state.md#0x0_state">state</a>: &<b>mut</b> <a href="state.md#0x0_state_State">state::State</a>, <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, proposal_id: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_vote">vote</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="state.md#0x0_state">state</a>: &<b>mut</b> State,
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &Account,
    proof: &TradeProof,
    proposal_id: u64,
    ctx: &<b>mut</b> TxContext,
) {
    <a href="account.md#0x0_account">account</a>.validate_proof(proof);

    <a href="state.md#0x0_state">state</a>.<a href="deepbook.md#0x0_deepbook_vote">vote</a>(<a href="pool.md#0x0_pool">pool</a>, <a href="account.md#0x0_account">account</a>.owner(), proposal_id, ctx)
}
</code></pre>



</details>

<a name="0x0_deepbook_place_limit_order"></a>

## Function `place_limit_order`

TODO: add other return values
Public facing function to place a limit order.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_place_limit_order">place_limit_order</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, client_order_id: u64, order_type: u8, price: u64, quantity: u64, is_bid: bool, expire_timestamp: u64, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="pool.md#0x0_pool_OrderPlaced">pool::OrderPlaced</a>&lt;BaseAsset, QuoteAsset&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_place_limit_order">place_limit_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    client_order_id: u64,
    order_type: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    expire_timestamp: u64, // Expiration timestamp in ms
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &<b>mut</b> TxContext,
): OrderPlaced&lt;BaseAsset, QuoteAsset&gt; {
    <a href="pool.md#0x0_pool">pool</a>.<a href="deepbook.md#0x0_deepbook_place_limit_order">place_limit_order</a>(
        <a href="account.md#0x0_account">account</a>,
        proof,
        client_order_id,
        order_type,
        price,
        quantity,
        is_bid,
        expire_timestamp,
        <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>,
        ctx,
    )
}
</code></pre>



</details>

<a name="0x0_deepbook_place_market_order"></a>

## Function `place_market_order`

Public facing function to place a market order.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_place_market_order">place_market_order</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, client_order_id: u64, quantity: u64, is_bid: bool, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_place_market_order">place_market_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    client_order_id: u64,
    quantity: u64,
    is_bid: bool,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &<b>mut</b> TxContext,
): (u64, u64) {
    <a href="pool.md#0x0_pool">pool</a>.<a href="deepbook.md#0x0_deepbook_place_market_order">place_market_order</a>(
        <a href="account.md#0x0_account">account</a>,
        proof,
        client_order_id,
        quantity,
        is_bid,
        <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>,
        ctx,
    )
}
</code></pre>



</details>

<a name="0x0_deepbook_cancel_order"></a>

## Function `cancel_order`

Public facing function to cancel an order.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_cancel_order">cancel_order</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, client_order_id: u128, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="pool.md#0x0_pool_Order">pool::Order</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_cancel_order">cancel_order</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    client_order_id: u128,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &<b>mut</b> TxContext,
): Order {
    <a href="pool.md#0x0_pool">pool</a>.<a href="deepbook.md#0x0_deepbook_cancel_order">cancel_order</a>(<a href="account.md#0x0_account">account</a>, proof, client_order_id, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>, ctx)
}
</code></pre>



</details>

<a name="0x0_deepbook_cancel_all_orders"></a>

## Function `cancel_all_orders`

Public facing function to cancel all orders.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_cancel_all_orders">cancel_all_orders</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> <a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, <a href="account.md#0x0_account">account</a>: &<b>mut</b> <a href="account.md#0x0_account_Account">account::Account</a>, proof: &<a href="account.md#0x0_account_TradeProof">account::TradeProof</a>, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &<a href="dependencies/sui-framework/clock.md#0x2_clock_Clock">clock::Clock</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="pool.md#0x0_pool_Order">pool::Order</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_cancel_all_orders">cancel_all_orders</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="pool.md#0x0_pool">pool</a>: &<b>mut</b> Pool&lt;BaseAsset, QuoteAsset&gt;,
    <a href="account.md#0x0_account">account</a>: &<b>mut</b> Account,
    proof: &TradeProof,
    <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>: &Clock,
    ctx: &<b>mut</b> TxContext,
): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;Order&gt; {
    <a href="pool.md#0x0_pool">pool</a>.cancel_all(<a href="account.md#0x0_account">account</a>, proof, <a href="dependencies/sui-framework/clock.md#0x2_clock">clock</a>, ctx)
}
</code></pre>



</details>

<a name="0x0_deepbook_user_open_orders"></a>

## Function `user_open_orders`

Public facing function to get open orders for a user.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_user_open_orders">user_open_orders</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="pool.md#0x0_pool">pool</a>: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, user: <b>address</b>): <a href="dependencies/sui-framework/vec_set.md#0x2_vec_set_VecSet">vec_set::VecSet</a>&lt;u128&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_user_open_orders">user_open_orders</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="pool.md#0x0_pool">pool</a>: &Pool&lt;BaseAsset, QuoteAsset&gt;,
    user: <b>address</b>,
): VecSet&lt;u128&gt; {
    <a href="pool.md#0x0_pool">pool</a>.<a href="deepbook.md#0x0_deepbook_user_open_orders">user_open_orders</a>(user)
}
</code></pre>



</details>

<a name="0x0_deepbook_get_amount_out"></a>

## Function `get_amount_out`

Public facing function to get amount_out given amount_in.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_get_amount_out">get_amount_out</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="pool.md#0x0_pool">pool</a>: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, amount_in: u64, is_bid: bool): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_get_amount_out">get_amount_out</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="pool.md#0x0_pool">pool</a>: &Pool&lt;BaseAsset, QuoteAsset&gt;,
    amount_in: u64,
    is_bid: bool,
): u64 {
    <a href="pool.md#0x0_pool">pool</a>.<a href="deepbook.md#0x0_deepbook_get_amount_out">get_amount_out</a>(amount_in, is_bid)
}
</code></pre>



</details>

<a name="0x0_deepbook_get_level2_bids"></a>

## Function `get_level2_bids`

Public facing function to get level2 bids.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_get_level2_bids">get_level2_bids</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="pool.md#0x0_pool">pool</a>: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, price_low: u64, price_high: u64): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_get_level2_bids">get_level2_bids</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="pool.md#0x0_pool">pool</a>: &Pool&lt;BaseAsset, QuoteAsset&gt;,
    price_low: u64,
    price_high: u64,
): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;) {
    <a href="pool.md#0x0_pool">pool</a>.<a href="deepbook.md#0x0_deepbook_get_level2_bids">get_level2_bids</a>(price_low, price_high)
}
</code></pre>



</details>

<a name="0x0_deepbook_get_level2_asks"></a>

## Function `get_level2_asks`

Public facing function to get level2 asks.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_get_level2_asks">get_level2_asks</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="pool.md#0x0_pool">pool</a>: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, price_low: u64, price_high: u64): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_get_level2_asks">get_level2_asks</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="pool.md#0x0_pool">pool</a>: &Pool&lt;BaseAsset, QuoteAsset&gt;,
    price_low: u64,
    price_high: u64,
): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;) {
    <a href="pool.md#0x0_pool">pool</a>.<a href="deepbook.md#0x0_deepbook_get_level2_asks">get_level2_asks</a>(price_low, price_high)
}
</code></pre>



</details>

<a name="0x0_deepbook_get_level2_ticks_from_mid"></a>

## Function `get_level2_ticks_from_mid`

Public facing function to get level2 ticks from mid.


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_get_level2_ticks_from_mid">get_level2_ticks_from_mid</a>&lt;BaseAsset, QuoteAsset&gt;(<a href="pool.md#0x0_pool">pool</a>: &<a href="pool.md#0x0_pool_Pool">pool::Pool</a>&lt;BaseAsset, QuoteAsset&gt;, ticks: u64): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="deepbook.md#0x0_deepbook_get_level2_ticks_from_mid">get_level2_ticks_from_mid</a>&lt;BaseAsset, QuoteAsset&gt;(
    <a href="pool.md#0x0_pool">pool</a>: &Pool&lt;BaseAsset, QuoteAsset&gt;,
    ticks: u64,
): (<a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;) {
    <a href="pool.md#0x0_pool">pool</a>.<a href="deepbook.md#0x0_deepbook_get_level2_ticks_from_mid">get_level2_ticks_from_mid</a>(ticks)
}
</code></pre>



</details>
