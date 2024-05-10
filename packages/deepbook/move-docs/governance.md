
<a name="0x0_governance"></a>

# Module `0x0::governance`



-  [Struct `Proposal`](#0x0_governance_Proposal)
-  [Struct `Governance`](#0x0_governance_Governance)
-  [Constants](#@Constants_0)
-  [Function `empty`](#0x0_governance_empty)
-  [Function `default_fees`](#0x0_governance_default_fees)
-  [Function `refresh`](#0x0_governance_refresh)
-  [Function `add_proposal`](#0x0_governance_add_proposal)
-  [Function `adjust_vote`](#0x0_governance_adjust_vote)
-  [Function `adjust_voting_power`](#0x0_governance_adjust_voting_power)
-  [Function `params`](#0x0_governance_params)
-  [Function `stake_to_voting_power`](#0x0_governance_stake_to_voting_power)
-  [Function `new_proposal`](#0x0_governance_new_proposal)
-  [Function `remove_lowest_proposal`](#0x0_governance_remove_lowest_proposal)


<pre><code><b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
<b>use</b> <a href="dependencies/sui-framework/vec_map.md#0x2_vec_map">0x2::vec_map</a>;
</code></pre>



<a name="0x0_governance_Proposal"></a>

## Struct `Proposal`

<code><a href="governance.md#0x0_governance_Proposal">Proposal</a></code> struct that holds the parameters of a proposal and its current total votes.


<pre><code><b>struct</b> <a href="governance.md#0x0_governance_Proposal">Proposal</a> <b>has</b> <b>copy</b>, drop, store
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

<a name="0x0_governance_Governance"></a>

## Struct `Governance`

Details of a pool. This is refreshed every epoch by the first
<code>State</code> action against this pool.


<pre><code><b>struct</b> <a href="governance.md#0x0_governance_Governance">Governance</a> <b>has</b> store
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
<code>proposals: <a href="dependencies/sui-framework/vec_map.md#0x2_vec_map_VecMap">vec_map::VecMap</a>&lt;<b>address</b>, <a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>&gt;</code>
</dt>
<dd>
 List of proposals for the current epoch.
</dd>
<dt>
<code>winning_proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>&gt;</code>
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


<a name="0x0_governance_EAlreadyProposed"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EAlreadyProposed">EAlreadyProposed</a>: u64 = 5;
</code></pre>



<a name="0x0_governance_EInvalidMakerFee"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EInvalidMakerFee">EInvalidMakerFee</a>: u64 = 1;
</code></pre>



<a name="0x0_governance_EInvalidTakerFee"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EInvalidTakerFee">EInvalidTakerFee</a>: u64 = 2;
</code></pre>



<a name="0x0_governance_EMaxProposalsReachedNotEnoughVotes"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EMaxProposalsReachedNotEnoughVotes">EMaxProposalsReachedNotEnoughVotes</a>: u64 = 4;
</code></pre>



<a name="0x0_governance_EProposalDoesNotExist"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EProposalDoesNotExist">EProposalDoesNotExist</a>: u64 = 3;
</code></pre>



<a name="0x0_governance_MAX_MAKER_STABLE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MAX_MAKER_STABLE">MAX_MAKER_STABLE</a>: u64 = 50000;
</code></pre>



<a name="0x0_governance_MAX_MAKER_VOLATILE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MAX_MAKER_VOLATILE">MAX_MAKER_VOLATILE</a>: u64 = 500000;
</code></pre>



<a name="0x0_governance_MAX_PROPOSALS"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MAX_PROPOSALS">MAX_PROPOSALS</a>: u64 = 100;
</code></pre>



<a name="0x0_governance_MAX_TAKER_STABLE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MAX_TAKER_STABLE">MAX_TAKER_STABLE</a>: u64 = 100000;
</code></pre>



<a name="0x0_governance_MAX_TAKER_VOLATILE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MAX_TAKER_VOLATILE">MAX_TAKER_VOLATILE</a>: u64 = 1000000;
</code></pre>



<a name="0x0_governance_MAX_U64"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MAX_U64">MAX_U64</a>: u64 = 9223372036854775808;
</code></pre>



<a name="0x0_governance_MIN_MAKER_STABLE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MIN_MAKER_STABLE">MIN_MAKER_STABLE</a>: u64 = 20000;
</code></pre>



<a name="0x0_governance_MIN_MAKER_VOLATILE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MIN_MAKER_VOLATILE">MIN_MAKER_VOLATILE</a>: u64 = 200000;
</code></pre>



<a name="0x0_governance_MIN_TAKER_STABLE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MIN_TAKER_STABLE">MIN_TAKER_STABLE</a>: u64 = 50000;
</code></pre>



<a name="0x0_governance_MIN_TAKER_VOLATILE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MIN_TAKER_VOLATILE">MIN_TAKER_VOLATILE</a>: u64 = 500000;
</code></pre>



<a name="0x0_governance_VOTING_POWER_CUTOFF"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_VOTING_POWER_CUTOFF">VOTING_POWER_CUTOFF</a>: u64 = 1000;
</code></pre>



<a name="0x0_governance_empty"></a>

## Function `empty`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_empty">empty</a>(epoch: u64): <a href="governance.md#0x0_governance_Governance">governance::Governance</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_empty">empty</a>(
    epoch: u64,
): <a href="governance.md#0x0_governance_Governance">Governance</a> {
    <a href="governance.md#0x0_governance_Governance">Governance</a> {
        epoch,
        proposals: <a href="dependencies/sui-framework/vec_map.md#0x2_vec_map_empty">vec_map::empty</a>(),
        winning_proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(),
        voting_power: 0,
        quorum: 0,
    }
}
</code></pre>



</details>

<a name="0x0_governance_default_fees"></a>

## Function `default_fees`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_default_fees">default_fees</a>(stable: bool): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_default_fees">default_fees</a>(stable: bool): (u64, u64) {
    <b>if</b> (stable) {
        (<a href="governance.md#0x0_governance_MAX_TAKER_STABLE">MAX_TAKER_STABLE</a>, <a href="governance.md#0x0_governance_MAX_MAKER_STABLE">MAX_MAKER_STABLE</a>)
    } <b>else</b> {
        (<a href="governance.md#0x0_governance_MAX_TAKER_VOLATILE">MAX_TAKER_VOLATILE</a>, <a href="governance.md#0x0_governance_MAX_MAKER_VOLATILE">MAX_MAKER_VOLATILE</a>)
    }
}
</code></pre>



</details>

<a name="0x0_governance_refresh"></a>

## Function `refresh`

Refresh the pool metadata. This is called by every <code>State</code>
action, but only processed once per epoch.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_refresh">refresh</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, epoch: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_refresh">refresh</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>, epoch: u64) {
    <b>if</b> (self.epoch == epoch) <b>return</b>;

    self.epoch = epoch;
    self.quorum = self.voting_power / 2;
    self.proposals = <a href="dependencies/sui-framework/vec_map.md#0x2_vec_map_empty">vec_map::empty</a>();
}
</code></pre>



</details>

<a name="0x0_governance_add_proposal"></a>

## Function `add_proposal`

Add a new proposal to governance.
Check if proposer already voted, if so will give error.
If proposer has not voted, and there are already MAX_PROPOSALS proposals,
remove the proposal with the lowest votes if it has less votes than the voting power.
Validation of the user adding is done in <code>State</code>.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_add_proposal">add_proposal</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, stable: bool, taker_fee: u64, maker_fee: u64, stake_required: u64, stake_amount: u64, proposer_address: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_add_proposal">add_proposal</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
    stable: bool,
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
    stake_amount: u64,
    proposer_address: <b>address</b>,
) {
    <b>assert</b>!(!self.proposals.contains(&proposer_address), <a href="governance.md#0x0_governance_EAlreadyProposed">EAlreadyProposed</a>);

    <b>let</b> voting_power = <a href="governance.md#0x0_governance_stake_to_voting_power">stake_to_voting_power</a>(stake_amount);
    <b>if</b> (self.proposals.size() == <a href="governance.md#0x0_governance_MAX_PROPOSALS">MAX_PROPOSALS</a>) {
        self.<a href="governance.md#0x0_governance_remove_lowest_proposal">remove_lowest_proposal</a>(voting_power);
    };

    <b>if</b> (stable) {
        <b>assert</b>!(taker_fee &gt;= <a href="governance.md#0x0_governance_MIN_TAKER_STABLE">MIN_TAKER_STABLE</a> && taker_fee &lt;= <a href="governance.md#0x0_governance_MAX_TAKER_STABLE">MAX_TAKER_STABLE</a>, <a href="governance.md#0x0_governance_EInvalidTakerFee">EInvalidTakerFee</a>);
        <b>assert</b>!(maker_fee &gt;= <a href="governance.md#0x0_governance_MIN_MAKER_STABLE">MIN_MAKER_STABLE</a> && maker_fee &lt;= <a href="governance.md#0x0_governance_MAX_MAKER_STABLE">MAX_MAKER_STABLE</a>, <a href="governance.md#0x0_governance_EInvalidMakerFee">EInvalidMakerFee</a>);
    } <b>else</b> {
        <b>assert</b>!(taker_fee &gt;= <a href="governance.md#0x0_governance_MIN_TAKER_VOLATILE">MIN_TAKER_VOLATILE</a> && taker_fee &lt;= <a href="governance.md#0x0_governance_MAX_TAKER_VOLATILE">MAX_TAKER_VOLATILE</a>, <a href="governance.md#0x0_governance_EInvalidTakerFee">EInvalidTakerFee</a>);
        <b>assert</b>!(maker_fee &gt;= <a href="governance.md#0x0_governance_MIN_MAKER_VOLATILE">MIN_MAKER_VOLATILE</a> && maker_fee &lt;= <a href="governance.md#0x0_governance_MAX_MAKER_VOLATILE">MAX_MAKER_VOLATILE</a>, <a href="governance.md#0x0_governance_EInvalidMakerFee">EInvalidMakerFee</a>);
    };

    <b>let</b> new_proposal = <a href="governance.md#0x0_governance_new_proposal">new_proposal</a>(taker_fee, maker_fee, stake_required);
    self.proposals.insert(proposer_address, new_proposal);
}
</code></pre>



</details>

<a name="0x0_governance_adjust_vote"></a>

## Function `adjust_vote`

Vote on a proposal. Validation of the user and stake is done in <code>State</code>.
If <code>from_proposal_id</code> is some, the user is removing their vote from that proposal.
If <code>to_proposal_id</code> is some, the user is voting for that proposal.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_adjust_vote">adjust_vote</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, from_proposal_id: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<b>address</b>&gt;, to_proposal_id: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<b>address</b>&gt;, stake_amount: u64): <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_adjust_vote">adjust_vote</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
    from_proposal_id: Option&lt;<b>address</b>&gt;,
    to_proposal_id: Option&lt;<b>address</b>&gt;,
    stake_amount: u64,
): Option&lt;<a href="governance.md#0x0_governance_Proposal">Proposal</a>&gt; {
    <b>let</b> voting_power = <a href="governance.md#0x0_governance_stake_to_voting_power">stake_to_voting_power</a>(stake_amount);

    <b>if</b> (from_proposal_id.is_some()) {
        <b>let</b> id = from_proposal_id.borrow();
        <b>if</b> (self.proposals.contains(id)) {
            self.proposals[id].votes = self.proposals[id].votes - voting_power;

            // This was the winning proposal, now it is not.
            <b>if</b> (self.proposals[id].votes + voting_power &gt; self.quorum &&
                self.proposals[id].votes &lt;= self.quorum) {
                self.winning_proposal = <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>();
            };
        };
    };

    <b>if</b> (to_proposal_id.is_some()) {
        <b>let</b> id = to_proposal_id.borrow();
        <b>assert</b>!(self.proposals.contains(id), <a href="governance.md#0x0_governance_EProposalDoesNotExist">EProposalDoesNotExist</a>);
        self.proposals[id].votes = self.proposals[id].votes + voting_power;
        <b>if</b> (self.proposals[id].votes &gt; self.quorum) {
            self.winning_proposal = <a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(self.proposals[id]);
        };
    };

    self.winning_proposal
}
</code></pre>



</details>

<a name="0x0_governance_adjust_voting_power"></a>

## Function `adjust_voting_power`

Adjust the total voting power by adding and removing stake. If a user's
stake goes from 2000 to 3000, then <code>stake_before</code> is 2000 and <code>stake_after</code> is 3000.
Validation of inputs done in <code>State</code>.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_adjust_voting_power">adjust_voting_power</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, stake_before: u64, stake_after: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_adjust_voting_power">adjust_voting_power</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
    stake_before: u64,
    stake_after: u64,
) {
    self.voting_power =
        self.voting_power +
        <a href="governance.md#0x0_governance_stake_to_voting_power">stake_to_voting_power</a>(stake_after) -
        <a href="governance.md#0x0_governance_stake_to_voting_power">stake_to_voting_power</a>(stake_before);
}
</code></pre>



</details>

<a name="0x0_governance_params"></a>

## Function `params`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_params">params</a>(proposal: &<a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_params">params</a>(proposal: &<a href="governance.md#0x0_governance_Proposal">Proposal</a>): (u64, u64, u64) {
    (proposal.taker_fee, proposal.maker_fee, proposal.stake_required)
}
</code></pre>



</details>

<a name="0x0_governance_stake_to_voting_power"></a>

## Function `stake_to_voting_power`

Convert stake to voting power. If the stake is above the cutoff, then the voting power is halved.


<pre><code><b>fun</b> <a href="governance.md#0x0_governance_stake_to_voting_power">stake_to_voting_power</a>(stake: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="governance.md#0x0_governance_stake_to_voting_power">stake_to_voting_power</a>(stake: u64): u64 {
    <b>if</b> (stake &gt;= <a href="governance.md#0x0_governance_VOTING_POWER_CUTOFF">VOTING_POWER_CUTOFF</a>) {
        stake - (stake - <a href="governance.md#0x0_governance_VOTING_POWER_CUTOFF">VOTING_POWER_CUTOFF</a>) / 2
    } <b>else</b> {
        stake
    }
}
</code></pre>



</details>

<a name="0x0_governance_new_proposal"></a>

## Function `new_proposal`



<pre><code><b>fun</b> <a href="governance.md#0x0_governance_new_proposal">new_proposal</a>(taker_fee: u64, maker_fee: u64, stake_required: u64): <a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="governance.md#0x0_governance_new_proposal">new_proposal</a>(taker_fee: u64, maker_fee: u64, stake_required: u64): <a href="governance.md#0x0_governance_Proposal">Proposal</a> {
    <a href="governance.md#0x0_governance_Proposal">Proposal</a> {
        taker_fee,
        maker_fee,
        stake_required,
        votes: 0,
    }
}
</code></pre>



</details>

<a name="0x0_governance_remove_lowest_proposal"></a>

## Function `remove_lowest_proposal`

Remove the proposal with the lowest votes if it has less votes than the voting power.
If there are multiple proposals with the same lowest votes, the latest one is removed.


<pre><code><b>fun</b> <a href="governance.md#0x0_governance_remove_lowest_proposal">remove_lowest_proposal</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, voting_power: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="governance.md#0x0_governance_remove_lowest_proposal">remove_lowest_proposal</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
    voting_power: u64,
) {
    <b>let</b> <b>mut</b> removal_id = <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>&lt;<b>address</b>&gt;();
    <b>let</b> <b>mut</b> cur_lowest_votes = <a href="governance.md#0x0_governance_MAX_U64">MAX_U64</a>;
    <b>let</b> (keys, values) = self.proposals.into_keys_values();
    <b>let</b> <b>mut</b> i = 0;

    <b>while</b> (i &lt; self.proposals.size()) {
        <b>let</b> proposal_votes = values[i].votes;
        <b>if</b> (proposal_votes &lt; voting_power && proposal_votes &lt;= cur_lowest_votes) {
            removal_id = <a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(keys[i]);
            cur_lowest_votes = proposal_votes;
        };
        i = i + 1;
    };

    <b>assert</b>!(removal_id.is_some(), <a href="governance.md#0x0_governance_EMaxProposalsReachedNotEnoughVotes">EMaxProposalsReachedNotEnoughVotes</a>);
    self.proposals.remove(removal_id.borrow());
}
</code></pre>



</details>
