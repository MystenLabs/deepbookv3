
<a name="0x0_governance"></a>

# Module `0x0::governance`

Governance module that handles the creation and voting on proposals.
Voting power is increased or decreased by state depending on stakes being added or removed.
When an epoch advances, the governance state is reset and the quorum is updated.


-  [Struct `Proposal`](#0x0_governance_Proposal)
-  [Struct `Voter`](#0x0_governance_Voter)
-  [Struct `Governance`](#0x0_governance_Governance)
-  [Constants](#@Constants_0)
-  [Function `empty`](#0x0_governance_empty)
-  [Function `reset`](#0x0_governance_reset)
-  [Function `proposal_params`](#0x0_governance_proposal_params)
-  [Function `increase_voting_power`](#0x0_governance_increase_voting_power)
-  [Function `decrease_voting_power`](#0x0_governance_decrease_voting_power)
-  [Function `create_new_proposal`](#0x0_governance_create_new_proposal)
-  [Function `vote`](#0x0_governance_vote)
-  [Function `remove_vote`](#0x0_governance_remove_vote)
-  [Function `new_proposal`](#0x0_governance_new_proposal)
-  [Function `new_voter`](#0x0_governance_new_voter)
-  [Function `add_voter_if_does_not_exist`](#0x0_governance_add_voter_if_does_not_exist)
-  [Function `increment_proposals_created`](#0x0_governance_increment_proposals_created)
-  [Function `update_voter`](#0x0_governance_update_voter)


<pre><code><b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
<b>use</b> <a href="dependencies/sui-framework/table.md#0x2_table">0x2::table</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
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
<code>maker_fee: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>taker_fee: u64</code>
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

<a name="0x0_governance_Voter"></a>

## Struct `Voter`

<code><a href="governance.md#0x0_governance_Voter">Voter</a></code> represents a single voter and the actions they have taken in the current epoch.
A user can create up to 1 proposal per epoch.
A user can cast/recast votes up to 3 times per epoch.


<pre><code><b>struct</b> <a href="governance.md#0x0_governance_Voter">Voter</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>proposal_id: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;u64&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>voting_power: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;u64&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>proposals_created: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>votes_casted: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_governance_Governance"></a>

## Struct `Governance`

<code><a href="governance.md#0x0_governance_Governance">Governance</a></code> struct holds all the governance related data. This will reset during
every epoch change, except <code>voting_power</code>. Participation is
limited to users with staked voting power.


<pre><code><b>struct</b> <a href="governance.md#0x0_governance_Governance">Governance</a> <b>has</b> store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>voting_power: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>quorum: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>winning_proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>proposals: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>voters: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="dependencies/sui-framework/table.md#0x2_table_Table">table::Table</a>&lt;<b>address</b>, <a href="governance.md#0x0_governance_Voter">governance::Voter</a>&gt;&gt;</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_governance_EInvalidMakerFee"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EInvalidMakerFee">EInvalidMakerFee</a>: u64 = 1;
</code></pre>



<a name="0x0_governance_EInvalidTakerFee"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EInvalidTakerFee">EInvalidTakerFee</a>: u64 = 2;
</code></pre>



<a name="0x0_governance_EMaxProposalsReached"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EMaxProposalsReached">EMaxProposalsReached</a>: u64 = 6;
</code></pre>



<a name="0x0_governance_EProposalDoesNotExist"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EProposalDoesNotExist">EProposalDoesNotExist</a>: u64 = 3;
</code></pre>



<a name="0x0_governance_EUserProposalCreationLimitReached"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EUserProposalCreationLimitReached">EUserProposalCreationLimitReached</a>: u64 = 4;
</code></pre>



<a name="0x0_governance_EUserVotesCastedLimitReached"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EUserVotesCastedLimitReached">EUserVotesCastedLimitReached</a>: u64 = 5;
</code></pre>



<a name="0x0_governance_MAX_MAKER_STABLE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MAX_MAKER_STABLE">MAX_MAKER_STABLE</a>: u64 = 50;
</code></pre>



<a name="0x0_governance_MAX_MAKER_VOLATILE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MAX_MAKER_VOLATILE">MAX_MAKER_VOLATILE</a>: u64 = 500;
</code></pre>



<a name="0x0_governance_MAX_PROPOSALS"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MAX_PROPOSALS">MAX_PROPOSALS</a>: u64 = 100;
</code></pre>



<a name="0x0_governance_MAX_PROPOSALS_CREATIONS_PER_USER"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MAX_PROPOSALS_CREATIONS_PER_USER">MAX_PROPOSALS_CREATIONS_PER_USER</a>: u64 = 1;
</code></pre>



<a name="0x0_governance_MAX_TAKER_STABLE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MAX_TAKER_STABLE">MAX_TAKER_STABLE</a>: u64 = 100;
</code></pre>



<a name="0x0_governance_MAX_TAKER_VOLATILE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MAX_TAKER_VOLATILE">MAX_TAKER_VOLATILE</a>: u64 = 1000;
</code></pre>



<a name="0x0_governance_MAX_VOTES_CASTED_PER_USER"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MAX_VOTES_CASTED_PER_USER">MAX_VOTES_CASTED_PER_USER</a>: u64 = 3;
</code></pre>



<a name="0x0_governance_MIN_MAKER_STABLE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MIN_MAKER_STABLE">MIN_MAKER_STABLE</a>: u64 = 20;
</code></pre>



<a name="0x0_governance_MIN_MAKER_VOLATILE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MIN_MAKER_VOLATILE">MIN_MAKER_VOLATILE</a>: u64 = 200;
</code></pre>



<a name="0x0_governance_MIN_TAKER_STABLE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MIN_TAKER_STABLE">MIN_TAKER_STABLE</a>: u64 = 50;
</code></pre>



<a name="0x0_governance_MIN_TAKER_VOLATILE"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_MIN_TAKER_VOLATILE">MIN_TAKER_VOLATILE</a>: u64 = 500;
</code></pre>



<a name="0x0_governance_empty"></a>

## Function `empty`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_empty">empty</a>(ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="governance.md#0x0_governance_Governance">governance::Governance</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_empty">empty</a>(ctx: &<b>mut</b> TxContext): <a href="governance.md#0x0_governance_Governance">Governance</a> {
    <a href="governance.md#0x0_governance_Governance">Governance</a> {
        voting_power: 0,
        quorum: 0,
        winning_proposal: <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(),
        proposals: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
        voters: <a href="dependencies/move-stdlib/option.md#0x1_option_some">option::some</a>(<a href="dependencies/sui-framework/table.md#0x2_table_new">table::new</a>(ctx)),
    }
}
</code></pre>



</details>

<a name="0x0_governance_reset"></a>

## Function `reset`

Reset the governance state. This will happen after an epoch change.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_reset">reset</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_reset">reset</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>, ctx: &<b>mut</b> TxContext) {
    self.quorum = self.voting_power / 2;
    self.winning_proposal = <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>();
    self.proposals = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[];
    <b>let</b> new_table: Table&lt;<b>address</b>, <a href="governance.md#0x0_governance_Voter">Voter</a>&gt; = <a href="dependencies/sui-framework/table.md#0x2_table_new">table::new</a>(ctx);
    <b>let</b> old_table = self.voters.swap(new_table);
    old_table.drop();
}
</code></pre>



</details>

<a name="0x0_governance_proposal_params"></a>

## Function `proposal_params`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_proposal_params">proposal_params</a>(proposal: &<a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_proposal_params">proposal_params</a>(proposal: &<a href="governance.md#0x0_governance_Proposal">Proposal</a>): (u64, u64, u64) {
    (proposal.maker_fee, proposal.taker_fee, proposal.stake_required)
}
</code></pre>



</details>

<a name="0x0_governance_increase_voting_power"></a>

## Function `increase_voting_power`

Increase the voting power available. This is called by the state during an epoch change.
The newly staked voting power from the previous epoch is added to the governance.
Validation should be done before calling this funciton.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_increase_voting_power">increase_voting_power</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, voting_power: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_increase_voting_power">increase_voting_power</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>, voting_power: u64) {
    self.voting_power = self.voting_power + voting_power;
}
</code></pre>



</details>

<a name="0x0_governance_decrease_voting_power"></a>

## Function `decrease_voting_power`

Decrease the voting power available.This is called by the parent when a user unstakes.
Only voting power that has been added previously can be removed. This will always be >= 0.
Validation should be done before calling this funciton.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_decrease_voting_power">decrease_voting_power</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, voting_power: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_decrease_voting_power">decrease_voting_power</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>, voting_power: u64) {
    self.voting_power = self.voting_power - voting_power;
}
</code></pre>



</details>

<a name="0x0_governance_create_new_proposal"></a>

## Function `create_new_proposal`

Create a new proposal with the given parameters. Perform validation depending
on the type of pool. A user can create up to 1 proposal per epoch.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_create_new_proposal">create_new_proposal</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, user: <b>address</b>, stable: bool, maker_fee: u64, taker_fee: u64, stake_required: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_create_new_proposal">create_new_proposal</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
    user: <b>address</b>,
    stable: bool,
    maker_fee: u64,
    taker_fee: u64,
    stake_required: u64,
) {
    self.<a href="governance.md#0x0_governance_add_voter_if_does_not_exist">add_voter_if_does_not_exist</a>(user);
    self.<a href="governance.md#0x0_governance_increment_proposals_created">increment_proposals_created</a>(user);

    <b>if</b> (stable) {
        <b>assert</b>!(maker_fee &gt;= <a href="governance.md#0x0_governance_MIN_MAKER_STABLE">MIN_MAKER_STABLE</a> && maker_fee &lt;= <a href="governance.md#0x0_governance_MAX_MAKER_STABLE">MAX_MAKER_STABLE</a>, <a href="governance.md#0x0_governance_EInvalidMakerFee">EInvalidMakerFee</a>);
        <b>assert</b>!(taker_fee &gt;= <a href="governance.md#0x0_governance_MIN_TAKER_STABLE">MIN_TAKER_STABLE</a> && taker_fee &lt;= <a href="governance.md#0x0_governance_MAX_TAKER_STABLE">MAX_TAKER_STABLE</a>, <a href="governance.md#0x0_governance_EInvalidTakerFee">EInvalidTakerFee</a>);
    } <b>else</b> {
        <b>assert</b>!(maker_fee &gt;= <a href="governance.md#0x0_governance_MIN_MAKER_VOLATILE">MIN_MAKER_VOLATILE</a> && maker_fee &lt;= <a href="governance.md#0x0_governance_MAX_MAKER_VOLATILE">MAX_MAKER_VOLATILE</a>, <a href="governance.md#0x0_governance_EInvalidMakerFee">EInvalidMakerFee</a>);
        <b>assert</b>!(taker_fee &gt;= <a href="governance.md#0x0_governance_MIN_TAKER_VOLATILE">MIN_TAKER_VOLATILE</a> && taker_fee &lt;= <a href="governance.md#0x0_governance_MAX_TAKER_VOLATILE">MAX_TAKER_VOLATILE</a>, <a href="governance.md#0x0_governance_EInvalidTakerFee">EInvalidTakerFee</a>);
    };

    <b>let</b> proposal = <a href="governance.md#0x0_governance_new_proposal">new_proposal</a>(maker_fee, taker_fee, stake_required);
    self.proposals.push_back(proposal);
}
</code></pre>



</details>

<a name="0x0_governance_vote"></a>

## Function `vote`

Vote on a proposal. Validation of user and voting power is done before calling this function.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_vote">vote</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, user: <b>address</b>, proposal_id: u64, voting_power: u64): <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_vote">vote</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
    user: <b>address</b>,
    proposal_id: u64,
    voting_power: u64,
): Option&lt;<a href="governance.md#0x0_governance_Proposal">Proposal</a>&gt; {
    <b>assert</b>!(proposal_id &lt; self.proposals.length(), <a href="governance.md#0x0_governance_EProposalDoesNotExist">EProposalDoesNotExist</a>);
    self.<a href="governance.md#0x0_governance_add_voter_if_does_not_exist">add_voter_if_does_not_exist</a>(user);
    self.<a href="governance.md#0x0_governance_update_voter">update_voter</a>(user, proposal_id, voting_power);

    <b>let</b> proposal = &<b>mut</b> self.proposals[proposal_id];
    proposal.votes = proposal.votes + voting_power;

    <b>if</b> (proposal.votes &gt; self.quorum) {
        self.winning_proposal.swap_or_fill(*proposal);
    };

    self.winning_proposal
}
</code></pre>



</details>

<a name="0x0_governance_remove_vote"></a>

## Function `remove_vote`

Remove a vote from a proposal. If user doesn't exist, do nothing.
This is called in two scenarios: a voted user changes his vote, or a user unstakes.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_remove_vote">remove_vote</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, user: <b>address</b>): <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_remove_vote">remove_vote</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
    user: <b>address</b>
): Option&lt;<a href="governance.md#0x0_governance_Proposal">Proposal</a>&gt; {
    <b>if</b> (!self.voters.borrow().contains(user)) <b>return</b> self.winning_proposal;
    <b>let</b> voter = &<b>mut</b> self.voters.borrow_mut()[user];
    <b>if</b> (voter.proposal_id.is_none()) <b>return</b> self.winning_proposal;

    <b>let</b> votes = voter.voting_power.extract();

    <b>let</b> proposal = &<b>mut</b> self.proposals[voter.proposal_id.extract()];
    proposal.votes = proposal.votes - votes;

    // this was over quorum before, now it is not
    // it was the winning proposal before, now it is not
    <b>if</b> (proposal.votes + votes &gt;= self.quorum
        && proposal.votes &lt; self.quorum) {
        self.winning_proposal = <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(); // .extract() ?
    };

    self.winning_proposal
}
</code></pre>



</details>

<a name="0x0_governance_new_proposal"></a>

## Function `new_proposal`



<pre><code><b>fun</b> <a href="governance.md#0x0_governance_new_proposal">new_proposal</a>(maker_fee: u64, taker_fee: u64, stake_required: u64): <a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="governance.md#0x0_governance_new_proposal">new_proposal</a>(maker_fee: u64, taker_fee: u64, stake_required: u64): <a href="governance.md#0x0_governance_Proposal">Proposal</a> {
    <a href="governance.md#0x0_governance_Proposal">Proposal</a> {
        maker_fee,
        taker_fee,
        stake_required,
        votes: 0,
    }
}
</code></pre>



</details>

<a name="0x0_governance_new_voter"></a>

## Function `new_voter`



<pre><code><b>fun</b> <a href="governance.md#0x0_governance_new_voter">new_voter</a>(): <a href="governance.md#0x0_governance_Voter">governance::Voter</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="governance.md#0x0_governance_new_voter">new_voter</a>(): <a href="governance.md#0x0_governance_Voter">Voter</a> {
    <a href="governance.md#0x0_governance_Voter">Voter</a> {
        proposal_id: <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(),
        voting_power: <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>(),
        proposals_created: 0,
        votes_casted: 0,
    }
}
</code></pre>



</details>

<a name="0x0_governance_add_voter_if_does_not_exist"></a>

## Function `add_voter_if_does_not_exist`



<pre><code><b>fun</b> <a href="governance.md#0x0_governance_add_voter_if_does_not_exist">add_voter_if_does_not_exist</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, user: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="governance.md#0x0_governance_add_voter_if_does_not_exist">add_voter_if_does_not_exist</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>, user: <b>address</b>) {
    <b>if</b> (!self.voters.borrow().contains(user)) {
        self.voters.borrow_mut().add(user, <a href="governance.md#0x0_governance_new_voter">new_voter</a>());
    };
}
</code></pre>



</details>

<a name="0x0_governance_increment_proposals_created"></a>

## Function `increment_proposals_created`



<pre><code><b>fun</b> <a href="governance.md#0x0_governance_increment_proposals_created">increment_proposals_created</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, user: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="governance.md#0x0_governance_increment_proposals_created">increment_proposals_created</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>, user: <b>address</b>) {
    <b>let</b> voter = &<b>mut</b> self.voters.borrow_mut()[user];
    <b>assert</b>!(voter.proposals_created &lt; <a href="governance.md#0x0_governance_MAX_PROPOSALS_CREATIONS_PER_USER">MAX_PROPOSALS_CREATIONS_PER_USER</a>, <a href="governance.md#0x0_governance_EUserProposalCreationLimitReached">EUserProposalCreationLimitReached</a>);
    <b>assert</b>!(self.proposals.length() &lt; <a href="governance.md#0x0_governance_MAX_PROPOSALS">MAX_PROPOSALS</a>, <a href="governance.md#0x0_governance_EMaxProposalsReached">EMaxProposalsReached</a>);

    voter.proposals_created = voter.proposals_created + 1;
}
</code></pre>



</details>

<a name="0x0_governance_update_voter"></a>

## Function `update_voter`



<pre><code><b>fun</b> <a href="governance.md#0x0_governance_update_voter">update_voter</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, user: <b>address</b>, proposal_id: u64, voting_power: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="governance.md#0x0_governance_update_voter">update_voter</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
    user: <b>address</b>,
    proposal_id: u64,
    voting_power: u64,
) {
    <b>let</b> voter = &<b>mut</b> self.voters.borrow_mut()[user];
    <b>assert</b>!(voter.votes_casted &lt; <a href="governance.md#0x0_governance_MAX_VOTES_CASTED_PER_USER">MAX_VOTES_CASTED_PER_USER</a>, <a href="governance.md#0x0_governance_EUserVotesCastedLimitReached">EUserVotesCastedLimitReached</a>);

    voter.votes_casted = voter.votes_casted + 1;
    voter.proposal_id.swap_or_fill(proposal_id);
    voter.voting_power.swap_or_fill(voting_power);
}
</code></pre>



</details>
