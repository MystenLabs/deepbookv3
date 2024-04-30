
<a name="0x0_pool_metadata"></a>

# Module `0x0::pool_metadata`



-  [Struct `PoolMetadata`](#0x0_pool_metadata_PoolMetadata)
-  [Constants](#@Constants_0)
-  [Function `new`](#0x0_pool_metadata_new)
-  [Function `set_as_stable`](#0x0_pool_metadata_set_as_stable)
-  [Function `refresh`](#0x0_pool_metadata_refresh)
-  [Function `add_proposal`](#0x0_pool_metadata_add_proposal)
-  [Function `vote`](#0x0_pool_metadata_vote)
-  [Function `add_voting_power`](#0x0_pool_metadata_add_voting_power)
-  [Function `remove_voting_power`](#0x0_pool_metadata_remove_voting_power)
-  [Function `stake_to_voting_power`](#0x0_pool_metadata_stake_to_voting_power)
-  [Function `calculate_new_voting_power`](#0x0_pool_metadata_calculate_new_voting_power)
-  [Function `calculate_voting_power_removed`](#0x0_pool_metadata_calculate_voting_power_removed)


<pre><code><b>use</b> <a href="governance.md#0x0_governance">0x0::governance</a>;
<b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
</code></pre>



<a name="0x0_pool_metadata_PoolMetadata"></a>

## Struct `PoolMetadata`

Details of a pool. This is refreshed every epoch by the first State level action against this pool.


<pre><code><b>struct</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a> <b>has</b> store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>last_refresh_epoch: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>is_stable: bool</code>
</dt>
<dd>

</dd>
<dt>
<code><a href="governance.md#0x0_governance">governance</a>: <a href="governance.md#0x0_governance_Governance">governance::Governance</a></code>
</dt>
<dd>

</dd>
<dt>
<code>new_voting_power: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_pool_metadata_VOTING_POWER_CUTOFF"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_VOTING_POWER_CUTOFF">VOTING_POWER_CUTOFF</a>: u64 = 1000;
</code></pre>



<a name="0x0_pool_metadata_new"></a>

## Function `new`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_new">new</a>(ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">pool_metadata::PoolMetadata</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_new">new</a>(
    ctx: &TxContext,
): <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a> {
    <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a> {
        last_refresh_epoch: ctx.epoch(),
        is_stable: <b>false</b>,
        <a href="governance.md#0x0_governance">governance</a>: <a href="governance.md#0x0_governance_new">governance::new</a>(),
        new_voting_power: 0,
    }
}
</code></pre>



</details>

<a name="0x0_pool_metadata_set_as_stable"></a>

## Function `set_as_stable`

Set the pool as stable. Called by State, validation done in State.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_set_as_stable">set_as_stable</a>(self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">pool_metadata::PoolMetadata</a>, stable: bool)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_set_as_stable">set_as_stable</a>(self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a>, stable: bool) {
    self.is_stable = stable;
}
</code></pre>



</details>

<a name="0x0_pool_metadata_refresh"></a>

## Function `refresh`

Refresh the pool metadata.
This is called by every State level action, but only processed once per epoch.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_refresh">refresh</a>(self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">pool_metadata::PoolMetadata</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_refresh">refresh</a>(self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a>, ctx: &TxContext) {
    <b>let</b> current_epoch = ctx.epoch();
    <b>if</b> (self.last_refresh_epoch == current_epoch) <b>return</b>;

    self.last_refresh_epoch = current_epoch;
    self.<a href="governance.md#0x0_governance">governance</a>.increase_voting_power(self.new_voting_power);
    self.<a href="governance.md#0x0_governance">governance</a>.reset();
}
</code></pre>



</details>

<a name="0x0_pool_metadata_add_proposal"></a>

## Function `add_proposal`

Add a new proposal to the governance. Called by State.
Validation of the user adding is done in State.
Validation of proposal parameters done in Goverance.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_add_proposal">add_proposal</a>(self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">pool_metadata::PoolMetadata</a>, user: <b>address</b>, maker_fee: u64, taker_fee: u64, stake_required: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_add_proposal">add_proposal</a>(
    self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a>,
    user: <b>address</b>,
    maker_fee: u64,
    taker_fee: u64,
    stake_required: u64
) {
    self.<a href="governance.md#0x0_governance">governance</a>.create_new_proposal(
        user,
        self.is_stable,
        maker_fee,
        taker_fee,
        stake_required
    );
}
</code></pre>



</details>

<a name="0x0_pool_metadata_vote"></a>

## Function `vote`

Vote on a proposal. Called by State.
Validation of the user and stake is done in State.
Validation of proposal id is done in Governance.
Remove any existing vote by this user and add new vote.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_vote">vote</a>(self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">pool_metadata::PoolMetadata</a>, proposal_id: u64, voter: <b>address</b>, stake_amount: u64): <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_vote">vote</a>(
    self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a>,
    proposal_id: u64,
    voter: <b>address</b>,
    stake_amount: u64,
): Option&lt;Proposal&gt; {
    self.<a href="governance.md#0x0_governance">governance</a>.remove_vote(voter);
    <b>let</b> voting_power = <a href="pool_metadata.md#0x0_pool_metadata_stake_to_voting_power">stake_to_voting_power</a>(stake_amount);
    self.<a href="governance.md#0x0_governance">governance</a>.<a href="pool_metadata.md#0x0_pool_metadata_vote">vote</a>(voter, proposal_id, voting_power)
}
</code></pre>



</details>

<a name="0x0_pool_metadata_add_voting_power"></a>

## Function `add_voting_power`

Add stake to the pool. Called by State.
Total user stake is the sum of the user's historic and current stake, including amount.
This is needed to calculate the new voting power.
Validation of the user, amount, and total_user_stake is done in State.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_add_voting_power">add_voting_power</a>(self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">pool_metadata::PoolMetadata</a>, old_stake: u64, new_stake: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_add_voting_power">add_voting_power</a>(
    self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a>,
    old_stake: u64,
    new_stake: u64,
) {
    <b>let</b> new_voting_power = <a href="pool_metadata.md#0x0_pool_metadata_calculate_new_voting_power">calculate_new_voting_power</a>(old_stake, new_stake);
    self.new_voting_power = self.new_voting_power + new_voting_power;
}
</code></pre>



</details>

<a name="0x0_pool_metadata_remove_voting_power"></a>

## Function `remove_voting_power`

Remove stake from the pool. Called by State.
old_epoch_stake is the user's stake before the current epoch.
current_epoch_stake is the user's stake during the current epoch.
These are needed to calculate the voting power to remove in Governance and are validated in State.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_remove_voting_power">remove_voting_power</a>(self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">pool_metadata::PoolMetadata</a>, old_epoch_stake: u64, current_epoch_stake: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_remove_voting_power">remove_voting_power</a>(
    self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a>,
    old_epoch_stake: u64,
    current_epoch_stake: u64,
) {
    <b>let</b> (
        old_voting_power,
        new_voting_power
    ) = <a href="pool_metadata.md#0x0_pool_metadata_calculate_voting_power_removed">calculate_voting_power_removed</a>(old_epoch_stake, current_epoch_stake);
    self.new_voting_power = self.new_voting_power - new_voting_power;
    self.<a href="governance.md#0x0_governance">governance</a>.decrease_voting_power(old_voting_power);
}
</code></pre>



</details>

<a name="0x0_pool_metadata_stake_to_voting_power"></a>

## Function `stake_to_voting_power`



<pre><code><b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_stake_to_voting_power">stake_to_voting_power</a>(stake: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_stake_to_voting_power">stake_to_voting_power</a>(stake: u64): u64 {
    <b>if</b> (stake &gt;= <a href="pool_metadata.md#0x0_pool_metadata_VOTING_POWER_CUTOFF">VOTING_POWER_CUTOFF</a>) {
        stake - (stake - <a href="pool_metadata.md#0x0_pool_metadata_VOTING_POWER_CUTOFF">VOTING_POWER_CUTOFF</a>) / 2
    } <b>else</b> {
        stake
    }
}
</code></pre>



</details>

<a name="0x0_pool_metadata_calculate_new_voting_power"></a>

## Function `calculate_new_voting_power`

Given a user's total stake and new stake from this epoch,
calculate the new voting power to add to the governance.


<pre><code><b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_calculate_new_voting_power">calculate_new_voting_power</a>(old_stake: u64, new_stake: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_calculate_new_voting_power">calculate_new_voting_power</a>(
    old_stake: u64,
    new_stake: u64,
): u64 {
    <b>if</b> (old_stake &gt;= <a href="pool_metadata.md#0x0_pool_metadata_VOTING_POWER_CUTOFF">VOTING_POWER_CUTOFF</a>) {
        <b>return</b> new_stake / 2
    };
    <b>let</b> amount_till_cutoff = <a href="pool_metadata.md#0x0_pool_metadata_VOTING_POWER_CUTOFF">VOTING_POWER_CUTOFF</a> - old_stake;
    <b>if</b> (amount_till_cutoff &gt;= new_stake) {
        <b>return</b> new_stake
    };

    amount_till_cutoff + (new_stake - amount_till_cutoff) / 2
}
</code></pre>



</details>

<a name="0x0_pool_metadata_calculate_voting_power_removed"></a>

## Function `calculate_voting_power_removed`

Given a user's total stake and new stake from this epoch,
calculate the voting power and new voting power to remove from the governance.


<pre><code><b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_calculate_voting_power_removed">calculate_voting_power_removed</a>(old_stake: u64, new_stake: u64): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_calculate_voting_power_removed">calculate_voting_power_removed</a>(
    old_stake: u64,
    new_stake: u64,
): (u64, u64) {
    <b>if</b> (old_stake + new_stake &lt;= <a href="pool_metadata.md#0x0_pool_metadata_VOTING_POWER_CUTOFF">VOTING_POWER_CUTOFF</a>) {
        <b>return</b> (old_stake, new_stake)
    };
    <b>if</b> (old_stake &lt;= <a href="pool_metadata.md#0x0_pool_metadata_VOTING_POWER_CUTOFF">VOTING_POWER_CUTOFF</a>) {
        <b>let</b> amount_till_cutoff = <a href="pool_metadata.md#0x0_pool_metadata_VOTING_POWER_CUTOFF">VOTING_POWER_CUTOFF</a> - old_stake;
        <b>return</b> (
            old_stake + amount_till_cutoff,
            (new_stake - amount_till_cutoff) / 2
        )
    };

    <b>let</b> old_after_cutoff = old_stake - <a href="pool_metadata.md#0x0_pool_metadata_VOTING_POWER_CUTOFF">VOTING_POWER_CUTOFF</a>;

    (
        old_stake + old_after_cutoff,
        new_stake / 2
    )
}
</code></pre>



</details>
