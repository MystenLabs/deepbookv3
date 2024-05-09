
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


<pre><code><b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
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
<code>proposals: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;<a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>&gt;</code>
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


<a name="0x0_governance_EInvalidMakerFee"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EInvalidMakerFee">EInvalidMakerFee</a>: u64 = 1;
</code></pre>



<a name="0x0_governance_EInvalidTakerFee"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EInvalidTakerFee">EInvalidTakerFee</a>: u64 = 2;
</code></pre>



<a name="0x0_governance_EMaxProposalsReached"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EMaxProposalsReached">EMaxProposalsReached</a>: u64 = 4;
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
        proposals: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[],
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
    self.proposals = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[];
}
</code></pre>



</details>

<a name="0x0_governance_add_proposal"></a>

## Function `add_proposal`

Add a new proposal to governance.
Validation of the user adding is done in <code>State</code>.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_add_proposal">add_proposal</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, stable: bool, taker_fee: u64, maker_fee: u64, stake_required: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_add_proposal">add_proposal</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
    stable: bool,
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64
) {
    <b>assert</b>!(self.proposals.length() &lt; <a href="governance.md#0x0_governance_MAX_PROPOSALS">MAX_PROPOSALS</a>, <a href="governance.md#0x0_governance_EMaxProposalsReached">EMaxProposalsReached</a>);
    <b>if</b> (stable) {
        <b>assert</b>!(taker_fee &gt;= <a href="governance.md#0x0_governance_MIN_TAKER_STABLE">MIN_TAKER_STABLE</a> && taker_fee &lt;= <a href="governance.md#0x0_governance_MAX_TAKER_STABLE">MAX_TAKER_STABLE</a>, <a href="governance.md#0x0_governance_EInvalidTakerFee">EInvalidTakerFee</a>);
        <b>assert</b>!(maker_fee &gt;= <a href="governance.md#0x0_governance_MIN_MAKER_STABLE">MIN_MAKER_STABLE</a> && maker_fee &lt;= <a href="governance.md#0x0_governance_MAX_MAKER_STABLE">MAX_MAKER_STABLE</a>, <a href="governance.md#0x0_governance_EInvalidMakerFee">EInvalidMakerFee</a>);
    } <b>else</b> {
        <b>assert</b>!(taker_fee &gt;= <a href="governance.md#0x0_governance_MIN_TAKER_VOLATILE">MIN_TAKER_VOLATILE</a> && taker_fee &lt;= <a href="governance.md#0x0_governance_MAX_TAKER_VOLATILE">MAX_TAKER_VOLATILE</a>, <a href="governance.md#0x0_governance_EInvalidTakerFee">EInvalidTakerFee</a>);
        <b>assert</b>!(maker_fee &gt;= <a href="governance.md#0x0_governance_MIN_MAKER_VOLATILE">MIN_MAKER_VOLATILE</a> && maker_fee &lt;= <a href="governance.md#0x0_governance_MAX_MAKER_VOLATILE">MAX_MAKER_VOLATILE</a>, <a href="governance.md#0x0_governance_EInvalidMakerFee">EInvalidMakerFee</a>);
    };

    self.proposals.push_back(<a href="governance.md#0x0_governance_new_proposal">new_proposal</a>(taker_fee, maker_fee, stake_required));
}
</code></pre>



</details>

<a name="0x0_governance_adjust_vote"></a>

## Function `adjust_vote`

Vote on a proposal. Validation of the user and stake is done in <code>State</code>.
If <code>from_proposal_id</code> is some, the user is removing their vote from that proposal.
If <code>to_proposal_id</code> is some, the user is voting for that proposal.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_adjust_vote">adjust_vote</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, from_proposal_id: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;u64&gt;, to_proposal_id: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;u64&gt;, stake_amount: u64): <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="governance.md#0x0_governance_adjust_vote">adjust_vote</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
    from_proposal_id: Option&lt;u64&gt;,
    to_proposal_id: Option&lt;u64&gt;,
    stake_amount: u64,
): Option&lt;<a href="governance.md#0x0_governance_Proposal">Proposal</a>&gt; {
    <b>let</b> voting_power = <a href="governance.md#0x0_governance_stake_to_voting_power">stake_to_voting_power</a>(stake_amount);

    <b>if</b> (from_proposal_id.is_some()) {
        <b>let</b> id = *from_proposal_id.borrow();
        <b>assert</b>!(self.proposals.length() &gt; id, <a href="governance.md#0x0_governance_EProposalDoesNotExist">EProposalDoesNotExist</a>);
        self.proposals[id].votes = self.proposals[id].votes - voting_power;

        // This was the winning proposal, now it is not.
        <b>if</b> (self.proposals[id].votes + voting_power &gt; self.quorum &&
            self.proposals[id].votes &lt;= self.quorum) {
            self.winning_proposal = <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>();
        };
    };

    <b>if</b> (to_proposal_id.is_some()) {
        <b>let</b> id = *to_proposal_id.borrow();
        <b>assert</b>!(self.proposals.length() &gt; id, <a href="governance.md#0x0_governance_EProposalDoesNotExist">EProposalDoesNotExist</a>);
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
