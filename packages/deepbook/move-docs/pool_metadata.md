
<a name="0x0_pool_metadata"></a>

# Module `0x0::pool_metadata`

This module contains the metadata for a pool. It manages cumulative voting power
for the pool, proposals, and governance. The metadata is refreshed every epoch.
Refreshing clears old proposals and resets the quorum.


-  [Struct `Proposal`](#0x0_pool_metadata_Proposal)
-  [Struct `PoolMetadata`](#0x0_pool_metadata_PoolMetadata)
-  [Constants](#@Constants_0)
-  [Function `empty`](#0x0_pool_metadata_empty)
-  [Function `set_as_stable`](#0x0_pool_metadata_set_as_stable)
-  [Function `refresh`](#0x0_pool_metadata_refresh)
-  [Function `add_proposal`](#0x0_pool_metadata_add_proposal)
-  [Function `vote`](#0x0_pool_metadata_vote)
-  [Function `adjust_voting_power`](#0x0_pool_metadata_adjust_voting_power)
-  [Function `proposal_params`](#0x0_pool_metadata_proposal_params)
-  [Function `stake_to_voting_power`](#0x0_pool_metadata_stake_to_voting_power)
-  [Function `new_proposal`](#0x0_pool_metadata_new_proposal)


<pre><code><b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
</code></pre>



<a name="0x0_pool_metadata_Proposal"></a>

## Struct `Proposal`

<code><a href="pool_metadata.md#0x0_pool_metadata_Proposal">Proposal</a></code> struct that holds the parameters of a proposal and its current total votes.


<pre><code><b>struct</b> <a href="pool_metadata.md#0x0_pool_metadata_Proposal">Proposal</a> <b>has</b> <b>copy</b>, drop, store
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
<dt>
<code>votes: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_pool_metadata_PoolMetadata"></a>

## Struct `PoolMetadata`

Details of a pool. This is refreshed every epoch by the first
<code>State</code> action against this pool.


<pre><code><b>struct</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a> <b>has</b> store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>epoch: u64</code>
</dt>
<dd>
 Tracks refreshes.
</dd>
<dt>
<code>is_stable: bool</code>
</dt>
<dd>
 If the pool is stable or volatile. Determines the fee structure applied.
</dd>
<dt>
<code>proposals: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="pool_metadata.md#0x0_pool_metadata_Proposal">pool_metadata::Proposal</a>&gt;</code>
</dt>
<dd>
 List of proposals for the current epoch.
</dd>
<dt>
<code>winning_proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="pool_metadata.md#0x0_pool_metadata_Proposal">pool_metadata::Proposal</a>&gt;</code>
</dt>
<dd>
 The winning proposal for the current epoch.
</dd>
<dt>
<code>voting_power: u64</code>
</dt>
<dd>
 All voting power from the current stakes.
</dd>
<dt>
<code>quorum: u64</code>
</dt>
<dd>
 Quorum for the current epoch.
</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_pool_metadata_EInvalidMakerFee"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_EInvalidMakerFee">EInvalidMakerFee</a>: u64 = 1;
</code></pre>



<a name="0x0_pool_metadata_EInvalidTakerFee"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_EInvalidTakerFee">EInvalidTakerFee</a>: u64 = 2;
</code></pre>



<a name="0x0_pool_metadata_EMaxProposalsReached"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_EMaxProposalsReached">EMaxProposalsReached</a>: u64 = 4;
</code></pre>



<a name="0x0_pool_metadata_EProposalDoesNotExist"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_EProposalDoesNotExist">EProposalDoesNotExist</a>: u64 = 3;
</code></pre>



<a name="0x0_pool_metadata_MAX_MAKER_STABLE"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_MAX_MAKER_STABLE">MAX_MAKER_STABLE</a>: u64 = 50;
</code></pre>



<a name="0x0_pool_metadata_MAX_MAKER_VOLATILE"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_MAX_MAKER_VOLATILE">MAX_MAKER_VOLATILE</a>: u64 = 500;
</code></pre>



<a name="0x0_pool_metadata_MAX_PROPOSALS"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_MAX_PROPOSALS">MAX_PROPOSALS</a>: u64 = 100;
</code></pre>



<a name="0x0_pool_metadata_MAX_TAKER_STABLE"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_MAX_TAKER_STABLE">MAX_TAKER_STABLE</a>: u64 = 100;
</code></pre>



<a name="0x0_pool_metadata_MAX_TAKER_VOLATILE"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_MAX_TAKER_VOLATILE">MAX_TAKER_VOLATILE</a>: u64 = 1000;
</code></pre>



<a name="0x0_pool_metadata_MIN_MAKER_STABLE"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_MIN_MAKER_STABLE">MIN_MAKER_STABLE</a>: u64 = 20;
</code></pre>



<a name="0x0_pool_metadata_MIN_MAKER_VOLATILE"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_MIN_MAKER_VOLATILE">MIN_MAKER_VOLATILE</a>: u64 = 200;
</code></pre>



<a name="0x0_pool_metadata_MIN_TAKER_STABLE"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_MIN_TAKER_STABLE">MIN_TAKER_STABLE</a>: u64 = 50;
</code></pre>



<a name="0x0_pool_metadata_MIN_TAKER_VOLATILE"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_MIN_TAKER_VOLATILE">MIN_TAKER_VOLATILE</a>: u64 = 500;
</code></pre>



<a name="0x0_pool_metadata_VOTING_POWER_CUTOFF"></a>



<pre><code><b>const</b> <a href="pool_metadata.md#0x0_pool_metadata_VOTING_POWER_CUTOFF">VOTING_POWER_CUTOFF</a>: u64 = 1000;
</code></pre>



<a name="0x0_pool_metadata_empty"></a>

## Function `empty`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_empty">empty</a>(epoch: u64): <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">pool_metadata::PoolMetadata</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_empty">empty</a>(
    epoch: u64,
): <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a> {
    <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a> {
        epoch,
        is_stable: <b>false</b>,
        proposals: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
        winning_proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(),
        voting_power: 0,
        quorum: 0,
    }
}
</code></pre>



</details>

<a name="0x0_pool_metadata_set_as_stable"></a>

## Function `set_as_stable`

Set the pool as stable. Called by <code>State</code>, validation done in <code>State</code>.


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

Refresh the pool metadata. This is called by every <code>State</code>
action, but only processed once per epoch.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_refresh">refresh</a>(self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">pool_metadata::PoolMetadata</a>, epoch: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_refresh">refresh</a>(self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a>, epoch: u64) {
    <b>if</b> (self.epoch == epoch) <b>return</b>;

    self.epoch = epoch;
    self.quorum = self.voting_power / 2;
    self.proposals = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[];
}
</code></pre>



</details>

<a name="0x0_pool_metadata_add_proposal"></a>

## Function `add_proposal`

Add a new proposal to governance.
Validation of the user adding is done in <code>State</code>.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_add_proposal">add_proposal</a>(self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">pool_metadata::PoolMetadata</a>, taker_fee: u64, maker_fee: u64, stake_required: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_add_proposal">add_proposal</a>(
    self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a>,
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64
) {
    <b>assert</b>!(self.proposals.length() &lt; <a href="pool_metadata.md#0x0_pool_metadata_MAX_PROPOSALS">MAX_PROPOSALS</a>, <a href="pool_metadata.md#0x0_pool_metadata_EMaxProposalsReached">EMaxProposalsReached</a>);
    <b>if</b> (self.is_stable) {
        <b>assert</b>!(taker_fee &gt;= <a href="pool_metadata.md#0x0_pool_metadata_MIN_TAKER_STABLE">MIN_TAKER_STABLE</a> && taker_fee &lt;= <a href="pool_metadata.md#0x0_pool_metadata_MAX_TAKER_STABLE">MAX_TAKER_STABLE</a>, <a href="pool_metadata.md#0x0_pool_metadata_EInvalidTakerFee">EInvalidTakerFee</a>);
        <b>assert</b>!(maker_fee &gt;= <a href="pool_metadata.md#0x0_pool_metadata_MIN_MAKER_STABLE">MIN_MAKER_STABLE</a> && maker_fee &lt;= <a href="pool_metadata.md#0x0_pool_metadata_MAX_MAKER_STABLE">MAX_MAKER_STABLE</a>, <a href="pool_metadata.md#0x0_pool_metadata_EInvalidMakerFee">EInvalidMakerFee</a>);
    } <b>else</b> {
        <b>assert</b>!(taker_fee &gt;= <a href="pool_metadata.md#0x0_pool_metadata_MIN_TAKER_VOLATILE">MIN_TAKER_VOLATILE</a> && taker_fee &lt;= <a href="pool_metadata.md#0x0_pool_metadata_MAX_TAKER_VOLATILE">MAX_TAKER_VOLATILE</a>, <a href="pool_metadata.md#0x0_pool_metadata_EInvalidTakerFee">EInvalidTakerFee</a>);
        <b>assert</b>!(maker_fee &gt;= <a href="pool_metadata.md#0x0_pool_metadata_MIN_MAKER_VOLATILE">MIN_MAKER_VOLATILE</a> && maker_fee &lt;= <a href="pool_metadata.md#0x0_pool_metadata_MAX_MAKER_VOLATILE">MAX_MAKER_VOLATILE</a>, <a href="pool_metadata.md#0x0_pool_metadata_EInvalidMakerFee">EInvalidMakerFee</a>);
    };

    self.proposals.push_back(<a href="pool_metadata.md#0x0_pool_metadata_new_proposal">new_proposal</a>(taker_fee, maker_fee, stake_required));
}
</code></pre>



</details>

<a name="0x0_pool_metadata_vote"></a>

## Function `vote`

Vote on a proposal. Validation of the user and stake is done in <code>State</code>.
If <code>from_proposal_id</code> is some, the user is removing their vote from that proposal.
If <code>to_proposal_id</code> is some, the user is voting for that proposal.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_vote">vote</a>(self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">pool_metadata::PoolMetadata</a>, from_proposal_id: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;u64&gt;, to_proposal_id: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;u64&gt;, stake_amount: u64): <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="pool_metadata.md#0x0_pool_metadata_Proposal">pool_metadata::Proposal</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_vote">vote</a>(
    self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a>,
    from_proposal_id: Option&lt;u64&gt;,
    to_proposal_id: Option&lt;u64&gt;,
    stake_amount: u64,
): Option&lt;<a href="pool_metadata.md#0x0_pool_metadata_Proposal">Proposal</a>&gt; {
    <b>let</b> voting_power = <a href="pool_metadata.md#0x0_pool_metadata_stake_to_voting_power">stake_to_voting_power</a>(stake_amount);

    <b>if</b> (from_proposal_id.is_some()) {
        <b>let</b> id = *from_proposal_id.borrow();
        <b>assert</b>!(self.proposals.length() &gt; id, <a href="pool_metadata.md#0x0_pool_metadata_EProposalDoesNotExist">EProposalDoesNotExist</a>);
        self.proposals[id].votes = self.proposals[id].votes - voting_power;

        // This was the winning proposal, now it is not.
        <b>if</b> (self.proposals[id].votes + voting_power &gt; self.quorum &&
            self.proposals[id].votes &lt;= self.quorum) {
            self.winning_proposal = <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>();
        };
    };

    <b>if</b> (to_proposal_id.is_some()) {
        <b>let</b> id = *to_proposal_id.borrow();
        <b>assert</b>!(self.proposals.length() &gt; id, <a href="pool_metadata.md#0x0_pool_metadata_EProposalDoesNotExist">EProposalDoesNotExist</a>);
        self.proposals[id].votes = self.proposals[id].votes + voting_power;
        <b>if</b> (self.proposals[id].votes &gt; self.quorum) {
            self.winning_proposal = <a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(self.proposals[id]);
        };
    };

    self.winning_proposal
}
</code></pre>



</details>

<a name="0x0_pool_metadata_adjust_voting_power"></a>

## Function `adjust_voting_power`

Adjust the total voting power by adding and removing stake. If a user's
stake goes from 2000 to 3000, then <code>stake_before</code> is 2000 and <code>stake_after</code> is 3000.
Validation of inputs done in <code>State</code>.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_adjust_voting_power">adjust_voting_power</a>(self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">pool_metadata::PoolMetadata</a>, stake_before: u64, stake_after: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_adjust_voting_power">adjust_voting_power</a>(
    self: &<b>mut</b> <a href="pool_metadata.md#0x0_pool_metadata_PoolMetadata">PoolMetadata</a>,
    stake_before: u64,
    stake_after: u64,
) {
    self.voting_power =
        self.voting_power +
        <a href="pool_metadata.md#0x0_pool_metadata_stake_to_voting_power">stake_to_voting_power</a>(stake_after) -
        <a href="pool_metadata.md#0x0_pool_metadata_stake_to_voting_power">stake_to_voting_power</a>(stake_before);
}
</code></pre>



</details>

<a name="0x0_pool_metadata_proposal_params"></a>

## Function `proposal_params`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_proposal_params">proposal_params</a>(proposal: &<a href="pool_metadata.md#0x0_pool_metadata_Proposal">pool_metadata::Proposal</a>): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_proposal_params">proposal_params</a>(proposal: &<a href="pool_metadata.md#0x0_pool_metadata_Proposal">Proposal</a>): (u64, u64, u64) {
    (proposal.taker_fee, proposal.maker_fee, proposal.stake_required)
}
</code></pre>



</details>

<a name="0x0_pool_metadata_stake_to_voting_power"></a>

## Function `stake_to_voting_power`

Convert stake to voting power. If the stake is above the cutoff, then the voting power is halved.


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

<a name="0x0_pool_metadata_new_proposal"></a>

## Function `new_proposal`



<pre><code><b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_new_proposal">new_proposal</a>(taker_fee: u64, maker_fee: u64, stake_required: u64): <a href="pool_metadata.md#0x0_pool_metadata_Proposal">pool_metadata::Proposal</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="pool_metadata.md#0x0_pool_metadata_new_proposal">new_proposal</a>(taker_fee: u64, maker_fee: u64, stake_required: u64): <a href="pool_metadata.md#0x0_pool_metadata_Proposal">Proposal</a> {
    <a href="pool_metadata.md#0x0_pool_metadata_Proposal">Proposal</a> {
        taker_fee,
        maker_fee,
        stake_required,
        votes: 0,
    }
}
</code></pre>



</details>
