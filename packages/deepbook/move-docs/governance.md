
<a name="0x0_governance"></a>

# Module `0x0::governance`

Governance module handles the governance of the <code>Pool</code> that it's attached to.
Users with non zero stake can create proposals and vote on them. Winning
proposals are used to set the trade parameters for the next epoch.


-  [Struct `Proposal`](#0x0_governance_Proposal)
-  [Struct `Governance`](#0x0_governance_Governance)
-  [Constants](#@Constants_0)
-  [Function `empty`](#0x0_governance_empty)
-  [Function `set_whitelist`](#0x0_governance_set_whitelist)
-  [Function `whitelisted`](#0x0_governance_whitelisted)
-  [Function `set_stable`](#0x0_governance_set_stable)
-  [Function `update`](#0x0_governance_update)
-  [Function `add_proposal`](#0x0_governance_add_proposal)
-  [Function `adjust_vote`](#0x0_governance_adjust_vote)
-  [Function `adjust_voting_power`](#0x0_governance_adjust_voting_power)
-  [Function `trade_params`](#0x0_governance_trade_params)
-  [Function `stake_to_voting_power`](#0x0_governance_stake_to_voting_power)
-  [Function `new_proposal`](#0x0_governance_new_proposal)
-  [Function `remove_lowest_proposal`](#0x0_governance_remove_lowest_proposal)
-  [Function `reset_trade_params`](#0x0_governance_reset_trade_params)
-  [Function `to_trade_params`](#0x0_governance_to_trade_params)


<pre><code><b>use</b> <a href="constants.md#0x0_constants">0x0::constants</a>;
<b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="trade_params.md#0x0_trade_params">0x0::trade_params</a>;
<b>use</b> <a href="dependencies/move-stdlib/option.md#0x1_option">0x1::option</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
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
<code>whitelisted: bool</code>
</dt>
<dd>
 If Pool is whitelisted.
</dd>
<dt>
<code>stable: bool</code>
</dt>
<dd>
 If Pool is stable or volatile.
</dd>
<dt>
<code>proposals: <a href="dependencies/sui-framework/vec_map.md#0x2_vec_map_VecMap">vec_map::VecMap</a>&lt;<a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>, <a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>&gt;</code>
</dt>
<dd>
 List of proposals for the current epoch.
</dd>
<dt>
<code><a href="trade_params.md#0x0_trade_params">trade_params</a>: <a href="trade_params.md#0x0_trade_params_TradeParams">trade_params::TradeParams</a></code>
</dt>
<dd>
 Trade parameters for the current epoch.
</dd>
<dt>
<code>next_trade_params: <a href="trade_params.md#0x0_trade_params_TradeParams">trade_params::TradeParams</a></code>
</dt>
<dd>
 Trade parameters for the next epoch.
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



<a name="0x0_governance_EWhitelistedPoolCannotChange"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_EWhitelistedPoolCannotChange">EWhitelistedPoolCannotChange</a>: u64 = 6;
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



<a name="0x0_governance_VOTING_POWER_THRESHOLD"></a>



<pre><code><b>const</b> <a href="governance.md#0x0_governance_VOTING_POWER_THRESHOLD">VOTING_POWER_THRESHOLD</a>: u64 = 100000000000000;
</code></pre>



<a name="0x0_governance_empty"></a>

## Function `empty`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_empty">empty</a>(ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="governance.md#0x0_governance_Governance">governance::Governance</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="governance.md#0x0_governance_empty">empty</a>(
    ctx: &TxContext,
): <a href="governance.md#0x0_governance_Governance">Governance</a> {
    <a href="governance.md#0x0_governance_Governance">Governance</a> {
        epoch: ctx.epoch(),
        whitelisted: <b>false</b>,
        stable: <b>false</b>,
        proposals: <a href="dependencies/sui-framework/vec_map.md#0x2_vec_map_empty">vec_map::empty</a>(),
        <a href="trade_params.md#0x0_trade_params">trade_params</a>: <a href="trade_params.md#0x0_trade_params_new">trade_params::new</a>(<a href="governance.md#0x0_governance_MAX_TAKER_VOLATILE">MAX_TAKER_VOLATILE</a>, <a href="governance.md#0x0_governance_MAX_MAKER_VOLATILE">MAX_MAKER_VOLATILE</a>, <a href="constants.md#0x0_constants_default_stake_required">constants::default_stake_required</a>()),
        next_trade_params: <a href="trade_params.md#0x0_trade_params_new">trade_params::new</a>(<a href="governance.md#0x0_governance_MAX_TAKER_VOLATILE">MAX_TAKER_VOLATILE</a>, <a href="governance.md#0x0_governance_MAX_MAKER_VOLATILE">MAX_MAKER_VOLATILE</a>, <a href="constants.md#0x0_constants_default_stake_required">constants::default_stake_required</a>()),
        voting_power: 0,
        quorum: 0,
    }
}
</code></pre>



</details>

<a name="0x0_governance_set_whitelist"></a>

## Function `set_whitelist`

Whitelist a pool. This pool can be used as a DEEP reference price for
other pools. This pool will have zero fees.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_set_whitelist">set_whitelist</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, whitelisted: bool)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="governance.md#0x0_governance_set_whitelist">set_whitelist</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
    whitelisted: bool,
) {
    self.whitelisted = whitelisted;
    self.stable = <b>false</b>;
    self.<a href="governance.md#0x0_governance_reset_trade_params">reset_trade_params</a>();
}
</code></pre>



</details>

<a name="0x0_governance_whitelisted"></a>

## Function `whitelisted`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_whitelisted">whitelisted</a>(self: &<a href="governance.md#0x0_governance_Governance">governance::Governance</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="governance.md#0x0_governance_whitelisted">whitelisted</a>(self: &<a href="governance.md#0x0_governance_Governance">Governance</a>): bool {
    self.whitelisted
}
</code></pre>



</details>

<a name="0x0_governance_set_stable"></a>

## Function `set_stable`

Set the pool to stable or volatile. If stable, the fees are set to
stable fees. If volatile, the fees are set to volatile fees.
This resets governance. A whitelisted pool cannot be set to stable.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_set_stable">set_stable</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, stable: bool)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="governance.md#0x0_governance_set_stable">set_stable</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
    stable: bool,
) {
    <b>assert</b>!(!self.whitelisted, <a href="governance.md#0x0_governance_EWhitelistedPoolCannotChange">EWhitelistedPoolCannotChange</a>);

    self.stable = stable;
    self.<a href="governance.md#0x0_governance_reset_trade_params">reset_trade_params</a>();
}
</code></pre>



</details>

<a name="0x0_governance_update"></a>

## Function `update`

Update the governance state. This is called at the start of every epoch.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <b>update</b>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <b>update</b>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>, ctx: &TxContext) {
    <b>let</b> epoch = ctx.epoch();
    <b>if</b> (self.epoch == epoch) <b>return</b>;

    self.epoch = epoch;
    self.quorum = math::mul(self.voting_power, <a href="constants.md#0x0_constants_half">constants::half</a>());
    self.proposals = <a href="dependencies/sui-framework/vec_map.md#0x2_vec_map_empty">vec_map::empty</a>();
    self.<a href="trade_params.md#0x0_trade_params">trade_params</a> = self.next_trade_params;
}
</code></pre>



</details>

<a name="0x0_governance_add_proposal"></a>

## Function `add_proposal`

Add a new proposal to governance.
Check if proposer already voted, if so will give error.
If proposer has not voted, and there are already MAX_PROPOSALS proposals,
remove the proposal with the lowest votes if it has less votes than the voting power.
Validation of the account adding is done in <code>State</code>.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_add_proposal">add_proposal</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, taker_fee: u64, maker_fee: u64, stake_required: u64, stake_amount: u64, account_id: <a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="governance.md#0x0_governance_add_proposal">add_proposal</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
    stake_amount: u64,
    account_id: ID,
) {
    <b>assert</b>!(!self.proposals.contains(&account_id), <a href="governance.md#0x0_governance_EAlreadyProposed">EAlreadyProposed</a>);
    <b>assert</b>!(!self.whitelisted, <a href="governance.md#0x0_governance_EWhitelistedPoolCannotChange">EWhitelistedPoolCannotChange</a>);

    <b>if</b> (self.stable) {
        <b>assert</b>!(taker_fee &gt;= <a href="governance.md#0x0_governance_MIN_TAKER_STABLE">MIN_TAKER_STABLE</a> && taker_fee &lt;= <a href="governance.md#0x0_governance_MAX_TAKER_STABLE">MAX_TAKER_STABLE</a>, <a href="governance.md#0x0_governance_EInvalidTakerFee">EInvalidTakerFee</a>);
        <b>assert</b>!(maker_fee &gt;= <a href="governance.md#0x0_governance_MIN_MAKER_STABLE">MIN_MAKER_STABLE</a> && maker_fee &lt;= <a href="governance.md#0x0_governance_MAX_MAKER_STABLE">MAX_MAKER_STABLE</a>, <a href="governance.md#0x0_governance_EInvalidMakerFee">EInvalidMakerFee</a>);
    } <b>else</b> {
        <b>assert</b>!(taker_fee &gt;= <a href="governance.md#0x0_governance_MIN_TAKER_VOLATILE">MIN_TAKER_VOLATILE</a> && taker_fee &lt;= <a href="governance.md#0x0_governance_MAX_TAKER_VOLATILE">MAX_TAKER_VOLATILE</a>, <a href="governance.md#0x0_governance_EInvalidTakerFee">EInvalidTakerFee</a>);
        <b>assert</b>!(maker_fee &gt;= <a href="governance.md#0x0_governance_MIN_MAKER_VOLATILE">MIN_MAKER_VOLATILE</a> && maker_fee &lt;= <a href="governance.md#0x0_governance_MAX_MAKER_VOLATILE">MAX_MAKER_VOLATILE</a>, <a href="governance.md#0x0_governance_EInvalidMakerFee">EInvalidMakerFee</a>);
    };

    <b>let</b> voting_power = <a href="governance.md#0x0_governance_stake_to_voting_power">stake_to_voting_power</a>(stake_amount);
    <b>if</b> (self.proposals.size() == <a href="governance.md#0x0_governance_MAX_PROPOSALS">MAX_PROPOSALS</a>) {
        self.<a href="governance.md#0x0_governance_remove_lowest_proposal">remove_lowest_proposal</a>(voting_power);
    };

    <b>let</b> new_proposal = <a href="governance.md#0x0_governance_new_proposal">new_proposal</a>(taker_fee, maker_fee, stake_required);
    self.proposals.insert(account_id, new_proposal);
}
</code></pre>



</details>

<a name="0x0_governance_adjust_vote"></a>

## Function `adjust_vote`

Vote on a proposal. Validation of the account and stake is done in <code>State</code>.
If <code>from_proposal_id</code> is some, the account is removing their vote from that proposal.
If <code>to_proposal_id</code> is some, the account is voting for that proposal.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_adjust_vote">adjust_vote</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, from_proposal_id: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>&gt;, to_proposal_id: <a href="dependencies/move-stdlib/option.md#0x1_option_Option">option::Option</a>&lt;<a href="dependencies/sui-framework/object.md#0x2_object_ID">object::ID</a>&gt;, stake_amount: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="governance.md#0x0_governance_adjust_vote">adjust_vote</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
    from_proposal_id: Option&lt;ID&gt;,
    to_proposal_id: Option&lt;ID&gt;,
    stake_amount: u64,
) {
    <b>let</b> votes = <a href="governance.md#0x0_governance_stake_to_voting_power">stake_to_voting_power</a>(stake_amount);

    <b>if</b> (from_proposal_id.is_some() && self.proposals.contains(from_proposal_id.borrow())) {
        <b>let</b> proposal = &<b>mut</b> self.proposals[from_proposal_id.borrow()];
        proposal.votes = proposal.votes - votes;
        <b>if</b> (proposal.votes + votes &gt; self.quorum && proposal.votes &lt; self.quorum) {
            self.next_trade_params = self.<a href="trade_params.md#0x0_trade_params">trade_params</a>;
        };
    };

    <b>if</b> (to_proposal_id.is_some()) {
        <b>assert</b>!(self.proposals.contains(to_proposal_id.borrow()), <a href="governance.md#0x0_governance_EProposalDoesNotExist">EProposalDoesNotExist</a>);

        <b>let</b> proposal = &<b>mut</b> self.proposals[to_proposal_id.borrow()];
        proposal.votes = proposal.votes + votes;
        <b>if</b> (proposal.votes &gt; self.quorum) {
            self.next_trade_params = proposal.<a href="governance.md#0x0_governance_to_trade_params">to_trade_params</a>();
        };
    };
}
</code></pre>



</details>

<a name="0x0_governance_adjust_voting_power"></a>

## Function `adjust_voting_power`

Adjust the total voting power by adding and removing stake. For example, if an account's
stake goes from 2000 to 3000, then <code>stake_before</code> is 2000 and <code>stake_after</code> is 3000.
Validation of inputs done in <code>State</code>.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="governance.md#0x0_governance_adjust_voting_power">adjust_voting_power</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>, stake_before: u64, stake_after: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="governance.md#0x0_governance_adjust_voting_power">adjust_voting_power</a>(
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

<a name="0x0_governance_trade_params"></a>

## Function `trade_params`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="trade_params.md#0x0_trade_params">trade_params</a>(self: &<a href="governance.md#0x0_governance_Governance">governance::Governance</a>): <a href="trade_params.md#0x0_trade_params_TradeParams">trade_params::TradeParams</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="trade_params.md#0x0_trade_params">trade_params</a>(self: &<a href="governance.md#0x0_governance_Governance">Governance</a>): TradeParams {
    self.<a href="trade_params.md#0x0_trade_params">trade_params</a>
}
</code></pre>



</details>

<a name="0x0_governance_stake_to_voting_power"></a>

## Function `stake_to_voting_power`

Convert stake to voting power.


<pre><code><b>fun</b> <a href="governance.md#0x0_governance_stake_to_voting_power">stake_to_voting_power</a>(stake: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="governance.md#0x0_governance_stake_to_voting_power">stake_to_voting_power</a>(
    stake: u64
): u64 {
    <b>let</b> <b>mut</b> voting_power = <a href="dependencies/sui-framework/math.md#0x2_math_min">math::min</a>(stake, <a href="governance.md#0x0_governance_VOTING_POWER_THRESHOLD">VOTING_POWER_THRESHOLD</a>);
    <b>if</b> (stake &gt; <a href="governance.md#0x0_governance_VOTING_POWER_THRESHOLD">VOTING_POWER_THRESHOLD</a>) {
        voting_power = voting_power + <a href="dependencies/sui-framework/math.md#0x2_math_sqrt">math::sqrt</a>(stake) - <a href="dependencies/sui-framework/math.md#0x2_math_sqrt">math::sqrt</a>(<a href="governance.md#0x0_governance_VOTING_POWER_THRESHOLD">VOTING_POWER_THRESHOLD</a>);
    };

    voting_power
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
    <b>let</b> <b>mut</b> removal_id = <a href="dependencies/move-stdlib/option.md#0x1_option_none">option::none</a>&lt;ID&gt;();
    <b>let</b> <b>mut</b> cur_lowest_votes = <a href="constants.md#0x0_constants_max_u64">constants::max_u64</a>();
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

<a name="0x0_governance_reset_trade_params"></a>

## Function `reset_trade_params`



<pre><code><b>fun</b> <a href="governance.md#0x0_governance_reset_trade_params">reset_trade_params</a>(self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">governance::Governance</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="governance.md#0x0_governance_reset_trade_params">reset_trade_params</a>(
    self: &<b>mut</b> <a href="governance.md#0x0_governance_Governance">Governance</a>,
) {
    self.proposals = <a href="dependencies/sui-framework/vec_map.md#0x2_vec_map_empty">vec_map::empty</a>();
    <b>let</b> stake = self.<a href="trade_params.md#0x0_trade_params">trade_params</a>.stake_required();
    <b>if</b> (self.whitelisted) {
        self.<a href="trade_params.md#0x0_trade_params">trade_params</a> = <a href="trade_params.md#0x0_trade_params_new">trade_params::new</a>(0, 0, 0);
    } <b>else</b> <b>if</b> (self.stable) {
        self.<a href="trade_params.md#0x0_trade_params">trade_params</a> = <a href="trade_params.md#0x0_trade_params_new">trade_params::new</a>(<a href="governance.md#0x0_governance_MAX_TAKER_STABLE">MAX_TAKER_STABLE</a>, <a href="governance.md#0x0_governance_MAX_MAKER_STABLE">MAX_MAKER_STABLE</a>, stake);
    } <b>else</b> {
        self.<a href="trade_params.md#0x0_trade_params">trade_params</a> = <a href="trade_params.md#0x0_trade_params_new">trade_params::new</a>(<a href="governance.md#0x0_governance_MAX_TAKER_VOLATILE">MAX_TAKER_VOLATILE</a>, <a href="governance.md#0x0_governance_MAX_MAKER_VOLATILE">MAX_MAKER_VOLATILE</a>, stake);
    };
    self.next_trade_params = self.<a href="trade_params.md#0x0_trade_params">trade_params</a>;
}
</code></pre>



</details>

<a name="0x0_governance_to_trade_params"></a>

## Function `to_trade_params`



<pre><code><b>fun</b> <a href="governance.md#0x0_governance_to_trade_params">to_trade_params</a>(proposal: &<a href="governance.md#0x0_governance_Proposal">governance::Proposal</a>): <a href="trade_params.md#0x0_trade_params_TradeParams">trade_params::TradeParams</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="governance.md#0x0_governance_to_trade_params">to_trade_params</a>(proposal: &<a href="governance.md#0x0_governance_Proposal">Proposal</a>): TradeParams {
    <a href="trade_params.md#0x0_trade_params_new">trade_params::new</a>(proposal.taker_fee, proposal.maker_fee, proposal.stake_required)
}
</code></pre>



</details>
