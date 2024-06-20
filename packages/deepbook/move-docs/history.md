
<a name="0x0_history"></a>

# Module `0x0::history`

History module tracks the volume data for the current epoch and past epochs.
It also tracks past trade params. Past maker fees are used to calculate fills for
old orders. The historic median is used to calculate rebates and burns.


-  [Struct `Volumes`](#0x0_history_Volumes)
-  [Struct `History`](#0x0_history_History)
-  [Constants](#@Constants_0)
-  [Function `empty`](#0x0_history_empty)
-  [Function `update`](#0x0_history_update)
-  [Function `reset_volumes`](#0x0_history_reset_volumes)
-  [Function `calculate_rebate_amount`](#0x0_history_calculate_rebate_amount)
-  [Function `update_historic_median`](#0x0_history_update_historic_median)
-  [Function `add_volume`](#0x0_history_add_volume)
-  [Function `balance_to_burn`](#0x0_history_balance_to_burn)
-  [Function `reset_balance_to_burn`](#0x0_history_reset_balance_to_burn)
-  [Function `historic_maker_fee`](#0x0_history_historic_maker_fee)
-  [Function `add_total_fees_collected`](#0x0_history_add_total_fees_collected)


<pre><code><b>use</b> <a href="balances.md#0x0_balances">0x0::balances</a>;
<b>use</b> <a href="constants.md#0x0_constants">0x0::constants</a>;
<b>use</b> <a href="math.md#0x0_math">0x0::math</a>;
<b>use</b> <a href="trade_params.md#0x0_trade_params">0x0::trade_params</a>;
<b>use</b> <a href="dependencies/sui-framework/table.md#0x2_table">0x2::table</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
</code></pre>



<a name="0x0_history_Volumes"></a>

## Struct `Volumes`

<code><a href="history.md#0x0_history_Volumes">Volumes</a></code> represents volume data for a single epoch.


<pre><code><b>struct</b> <a href="history.md#0x0_history_Volumes">Volumes</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>total_volume: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>total_staked_volume: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>total_fees_collected: <a href="balances.md#0x0_balances_Balances">balances::Balances</a></code>
</dt>
<dd>

</dd>
<dt>
<code>historic_median: u64</code>
</dt>
<dd>

</dd>
<dt>
<code><a href="trade_params.md#0x0_trade_params">trade_params</a>: <a href="trade_params.md#0x0_trade_params_TradeParams">trade_params::TradeParams</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_history_History"></a>

## Struct `History`

<code><a href="history.md#0x0_history_History">History</a></code> represents the volume data for the current epoch and past epochs.


<pre><code><b>struct</b> <a href="history.md#0x0_history_History">History</a> <b>has</b> store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>epoch: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>epoch_created: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>volumes: <a href="history.md#0x0_history_Volumes">history::Volumes</a></code>
</dt>
<dd>

</dd>
<dt>
<code>historic_volumes: <a href="dependencies/sui-framework/table.md#0x2_table_Table">table::Table</a>&lt;u64, <a href="history.md#0x0_history_Volumes">history::Volumes</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>balance_to_burn: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_history_EHistoricVolumesNotFound"></a>



<pre><code><b>const</b> <a href="history.md#0x0_history_EHistoricVolumesNotFound">EHistoricVolumesNotFound</a>: u64 = 0;
</code></pre>



<a name="0x0_history_empty"></a>

## Function `empty`

Create a new <code><a href="history.md#0x0_history_History">History</a></code> instance. Called once upon pool creation. A single blank
<code><a href="history.md#0x0_history_Volumes">Volumes</a></code> instance is created and added to the historic_volumes table.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="history.md#0x0_history_empty">empty</a>(<a href="trade_params.md#0x0_trade_params">trade_params</a>: <a href="trade_params.md#0x0_trade_params_TradeParams">trade_params::TradeParams</a>, epoch_created: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="history.md#0x0_history_History">history::History</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="history.md#0x0_history_empty">empty</a>(
    <a href="trade_params.md#0x0_trade_params">trade_params</a>: TradeParams,
    epoch_created: u64,
    ctx: &<b>mut</b> TxContext,
): <a href="history.md#0x0_history_History">History</a> {
    <b>let</b> volumes = <a href="history.md#0x0_history_Volumes">Volumes</a> {
        total_volume: 0,
        total_staked_volume: 0,
        total_fees_collected: <a href="balances.md#0x0_balances_empty">balances::empty</a>(),
        historic_median: 0,
        <a href="trade_params.md#0x0_trade_params">trade_params</a>,
    };
    <b>let</b> <b>mut</b> <a href="history.md#0x0_history">history</a> = <a href="history.md#0x0_history_History">History</a> {
        epoch: ctx.epoch(),
        epoch_created,
        volumes,
        historic_volumes: <a href="dependencies/sui-framework/table.md#0x2_table_new">table::new</a>(ctx),
        balance_to_burn: 0,
    };
    <a href="history.md#0x0_history">history</a>.historic_volumes.add(ctx.epoch(), volumes);

    <a href="history.md#0x0_history">history</a>
}
</code></pre>



</details>

<a name="0x0_history_update"></a>

## Function `update`

Update the epoch if it has changed. If there are accounts with rebates,
add the current epoch's volume data to the historic volumes.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <b>update</b>(self: &<b>mut</b> <a href="history.md#0x0_history_History">history::History</a>, <a href="trade_params.md#0x0_trade_params">trade_params</a>: <a href="trade_params.md#0x0_trade_params_TradeParams">trade_params::TradeParams</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <b>update</b>(
    self: &<b>mut</b> <a href="history.md#0x0_history_History">History</a>,
    <a href="trade_params.md#0x0_trade_params">trade_params</a>: TradeParams,
    ctx: &TxContext,
) {
    <b>let</b> epoch = ctx.epoch();
    <b>if</b> (self.epoch == epoch) <b>return</b>;
    <b>if</b> (self.historic_volumes.contains(self.epoch)) {
        self.historic_volumes.remove(self.epoch);
    };
    self.<a href="history.md#0x0_history_update_historic_median">update_historic_median</a>();
    self.historic_volumes.add(self.epoch, self.volumes);

    self.epoch = epoch;
    self.<a href="history.md#0x0_history_reset_volumes">reset_volumes</a>(<a href="trade_params.md#0x0_trade_params">trade_params</a>);
    self.historic_volumes.add(self.epoch, self.volumes);
}
</code></pre>



</details>

<a name="0x0_history_reset_volumes"></a>

## Function `reset_volumes`

Reset the current epoch's volume data.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="history.md#0x0_history_reset_volumes">reset_volumes</a>(self: &<b>mut</b> <a href="history.md#0x0_history_History">history::History</a>, <a href="trade_params.md#0x0_trade_params">trade_params</a>: <a href="trade_params.md#0x0_trade_params_TradeParams">trade_params::TradeParams</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="history.md#0x0_history_reset_volumes">reset_volumes</a>(
    self: &<b>mut</b> <a href="history.md#0x0_history_History">History</a>,
    <a href="trade_params.md#0x0_trade_params">trade_params</a>: TradeParams,
) {
    self.volumes = <a href="history.md#0x0_history_Volumes">Volumes</a> {
        total_volume: 0,
        total_staked_volume: 0,
        total_fees_collected: <a href="balances.md#0x0_balances_empty">balances::empty</a>(),
        historic_median: 0,
        <a href="trade_params.md#0x0_trade_params">trade_params</a>,
    };
}
</code></pre>



</details>

<a name="0x0_history_calculate_rebate_amount"></a>

## Function `calculate_rebate_amount`

Given the epoch's volume data and the account's volume data,
calculate and returns rebate amount, updates the burn amount.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="history.md#0x0_history_calculate_rebate_amount">calculate_rebate_amount</a>(self: &<b>mut</b> <a href="history.md#0x0_history_History">history::History</a>, prev_epoch: u64, maker_volume: u64, account_stake: u64): <a href="balances.md#0x0_balances_Balances">balances::Balances</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="history.md#0x0_history_calculate_rebate_amount">calculate_rebate_amount</a>(
    self: &<b>mut</b> <a href="history.md#0x0_history_History">History</a>,
    prev_epoch: u64,
    maker_volume: u64,
    account_stake: u64,
): Balances {
    <b>assert</b>!(self.historic_volumes.contains(prev_epoch), <a href="history.md#0x0_history_EHistoricVolumesNotFound">EHistoricVolumesNotFound</a>);
    <b>let</b> volumes = &<b>mut</b> self.historic_volumes[prev_epoch];
    <b>if</b> (volumes.<a href="trade_params.md#0x0_trade_params">trade_params</a>.stake_required() &gt; account_stake) <b>return</b> <a href="balances.md#0x0_balances_empty">balances::empty</a>();

    <b>let</b> other_maker_liquidity = volumes.total_volume - maker_volume;
    <b>let</b> maker_rebate_percentage = <b>if</b> (volumes.historic_median &gt; 0) {
        <a href="constants.md#0x0_constants_float_scaling">constants::float_scaling</a>() - <a href="dependencies/sui-framework/math.md#0x2_math_min">math::min</a>(<a href="constants.md#0x0_constants_float_scaling">constants::float_scaling</a>(), math::div(other_maker_liquidity, volumes.historic_median))
    } <b>else</b> {
        0
    };
    <b>let</b> maker_volume_proportion = <b>if</b> (volumes.total_staked_volume &gt; 0) {
        math::div(maker_volume, volumes.total_staked_volume)
    } <b>else</b> {
        0
    };
    <b>let</b> maker_fee_proportion = math::mul(maker_volume_proportion, volumes.total_fees_collected.<a href="dependencies/token/deep.md#0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8_deep">deep</a>());
    <b>let</b> maker_rebate = math::mul(maker_rebate_percentage, maker_fee_proportion);
    <b>let</b> maker_burn = maker_fee_proportion - maker_rebate;

    self.balance_to_burn = self.balance_to_burn + maker_burn;

    <a href="balances.md#0x0_balances_new">balances::new</a>(0, 0, maker_rebate)
}
</code></pre>



</details>

<a name="0x0_history_update_historic_median"></a>

## Function `update_historic_median`

Updates the historic_median for past 28 epochs.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="history.md#0x0_history_update_historic_median">update_historic_median</a>(self: &<b>mut</b> <a href="history.md#0x0_history_History">history::History</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="history.md#0x0_history_update_historic_median">update_historic_median</a>(
    self: &<b>mut</b> <a href="history.md#0x0_history_History">History</a>,
) {
    <b>let</b> epochs_since_creation = self.epoch - self.epoch_created;
    <b>if</b> (epochs_since_creation &lt; <a href="constants.md#0x0_constants_phase_out_epochs">constants::phase_out_epochs</a>()) {
        self.volumes.historic_median = <a href="constants.md#0x0_constants_max_u64">constants::max_u64</a>();
        <b>return</b>
    };
    <b>let</b> <b>mut</b> median_vec = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;[];
    <b>let</b> <b>mut</b> i = self.epoch - <a href="constants.md#0x0_constants_phase_out_epochs">constants::phase_out_epochs</a>();
    <b>while</b> (i &lt; self.epoch) {
        <b>if</b> (self.historic_volumes.contains(i)) {
            median_vec.push_back(self.historic_volumes[i].total_volume);
        } <b>else</b> {
            median_vec.push_back(0);
        };
        i = i + 1;
    };

    self.volumes.historic_median = math::median(median_vec);
}
</code></pre>



</details>

<a name="0x0_history_add_volume"></a>

## Function `add_volume`

Add volume to the current epoch's volume data.
Increments the total volume and total staked volume.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="history.md#0x0_history_add_volume">add_volume</a>(self: &<b>mut</b> <a href="history.md#0x0_history_History">history::History</a>, maker_volume: u64, account_stake: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="history.md#0x0_history_add_volume">add_volume</a>(
    self: &<b>mut</b> <a href="history.md#0x0_history_History">History</a>,
    maker_volume: u64,
    account_stake: u64,
) {
    <b>if</b> (maker_volume == 0) <b>return</b>;

    self.volumes.total_volume = self.volumes.total_volume + maker_volume;
    <b>if</b> (account_stake &gt;= self.volumes.<a href="trade_params.md#0x0_trade_params">trade_params</a>.stake_required()) {
        self.volumes.total_staked_volume = self.volumes.total_staked_volume + maker_volume;
    };
}
</code></pre>



</details>

<a name="0x0_history_balance_to_burn"></a>

## Function `balance_to_burn`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="history.md#0x0_history_balance_to_burn">balance_to_burn</a>(self: &<a href="history.md#0x0_history_History">history::History</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="history.md#0x0_history_balance_to_burn">balance_to_burn</a>(
    self: &<a href="history.md#0x0_history_History">History</a>,
): u64 {
    self.balance_to_burn
}
</code></pre>



</details>

<a name="0x0_history_reset_balance_to_burn"></a>

## Function `reset_balance_to_burn`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="history.md#0x0_history_reset_balance_to_burn">reset_balance_to_burn</a>(self: &<b>mut</b> <a href="history.md#0x0_history_History">history::History</a>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="history.md#0x0_history_reset_balance_to_burn">reset_balance_to_burn</a>(
    self: &<b>mut</b> <a href="history.md#0x0_history_History">History</a>,
): u64 {
    <b>let</b> balance_to_burn = self.balance_to_burn;
    self.balance_to_burn = 0;

    balance_to_burn
}
</code></pre>



</details>

<a name="0x0_history_historic_maker_fee"></a>

## Function `historic_maker_fee`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="history.md#0x0_history_historic_maker_fee">historic_maker_fee</a>(self: &<a href="history.md#0x0_history_History">history::History</a>, epoch: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="history.md#0x0_history_historic_maker_fee">historic_maker_fee</a>(
    self: &<a href="history.md#0x0_history_History">History</a>,
    epoch: u64,
): u64 {
    <b>assert</b>!(self.historic_volumes.contains(epoch), <a href="history.md#0x0_history_EHistoricVolumesNotFound">EHistoricVolumesNotFound</a>);

    self.historic_volumes[epoch].<a href="trade_params.md#0x0_trade_params">trade_params</a>.maker_fee()
}
</code></pre>



</details>

<a name="0x0_history_add_total_fees_collected"></a>

## Function `add_total_fees_collected`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="history.md#0x0_history_add_total_fees_collected">add_total_fees_collected</a>(self: &<b>mut</b> <a href="history.md#0x0_history_History">history::History</a>, fees: <a href="balances.md#0x0_balances_Balances">balances::Balances</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="history.md#0x0_history_add_total_fees_collected">add_total_fees_collected</a>(
    self: &<b>mut</b> <a href="history.md#0x0_history_History">History</a>,
    fees: Balances,
) {
    self.volumes.total_fees_collected.add_balances(fees);
}
</code></pre>



</details>
