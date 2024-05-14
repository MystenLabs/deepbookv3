
<a name="0x0_history"></a>

# Module `0x0::history`



-  [Struct `Volumes`](#0x0_history_Volumes)
-  [Struct `History`](#0x0_history_History)
-  [Constants](#@Constants_0)
-  [Function `empty`](#0x0_history_empty)
-  [Function `update`](#0x0_history_update)
-  [Function `calculate_rebate_amount`](#0x0_history_calculate_rebate_amount)
-  [Function `add_volume`](#0x0_history_add_volume)


<pre><code><b>use</b> <a href="dependencies/sui-framework/table.md#0x2_table">0x2::table</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
</code></pre>



<a name="0x0_history_Volumes"></a>

## Struct `Volumes`

Overall volume for the current epoch. Used to calculate rebates and burns.


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
<code>total_fees_collected: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>stake_required: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>users_with_rebates: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_history_History"></a>

## Struct `History`



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



<pre><code><b>const</b> <a href="history.md#0x0_history_EHistoricVolumesNotFound">EHistoricVolumesNotFound</a>: u64 = 1;
</code></pre>



<a name="0x0_history_empty"></a>

## Function `empty`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="history.md#0x0_history_empty">empty</a>(ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="history.md#0x0_history_History">history::History</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="history.md#0x0_history_empty">empty</a>(
    ctx: &<b>mut</b> TxContext,
): <a href="history.md#0x0_history_History">History</a> {
    <b>let</b> volumes = <a href="history.md#0x0_history_Volumes">Volumes</a> {
        total_volume: 0,
        total_staked_volume: 0,
        total_fees_collected: 0,
        stake_required: 0,
        users_with_rebates: 0,
    };
    <a href="history.md#0x0_history_History">History</a> {
        epoch: ctx.epoch(),
        volumes,
        historic_volumes: <a href="dependencies/sui-framework/table.md#0x2_table_new">table::new</a>(ctx),
        balance_to_burn: 0,
    }
}
</code></pre>



</details>

<a name="0x0_history_update"></a>

## Function `update`

Update the epoch if it has changed.
If there are users with rebates, add the current epoch's volume data to the historic volumes.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <b>update</b>(self: &<b>mut</b> <a href="history.md#0x0_history_History">history::History</a>, ctx: &<a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <b>update</b>(
    self: &<b>mut</b> <a href="history.md#0x0_history_History">History</a>,
    ctx: &TxContext,
) {
    <b>let</b> epoch = ctx.epoch();
    <b>if</b> (self.epoch == epoch) <b>return</b>;
    <b>if</b> (self.volumes.users_with_rebates &gt; 0) {
        self.historic_volumes.add(self.epoch, self.volumes);
    };
    self.epoch = epoch;
}
</code></pre>



</details>

<a name="0x0_history_calculate_rebate_amount"></a>

## Function `calculate_rebate_amount`

Given the epoch's volume data and the user's volume data,
calculate the rebate and burn amounts.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="history.md#0x0_history_calculate_rebate_amount">calculate_rebate_amount</a>(self: &<b>mut</b> <a href="history.md#0x0_history_History">history::History</a>, epoch: u64, _maker_volume: u64, user_stake: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="history.md#0x0_history_calculate_rebate_amount">calculate_rebate_amount</a>(
    self: &<b>mut</b> <a href="history.md#0x0_history_History">History</a>,
    epoch: u64,
    _maker_volume: u64,
    user_stake: u64,
): u64 {
    <b>assert</b>!(self.historic_volumes.contains(epoch), <a href="history.md#0x0_history_EHistoricVolumesNotFound">EHistoricVolumesNotFound</a>);
    <b>let</b> volumes = &<b>mut</b> self.historic_volumes[epoch];
    <b>if</b> (volumes.stake_required &gt; user_stake) <b>return</b> 0;

    // TODO: calculate and add <b>to</b> burn <a href="dependencies/sui-framework/balance.md#0x2_balance">balance</a>

    volumes.users_with_rebates = volumes.users_with_rebates - 1;
    <b>if</b> (volumes.users_with_rebates == 0) {
        self.historic_volumes.remove(epoch);
    };

    0
}
</code></pre>



</details>

<a name="0x0_history_add_volume"></a>

## Function `add_volume`

Add volume to the current epoch's volume data.
Increments the total volume and total staked volume.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="history.md#0x0_history_add_volume">add_volume</a>(self: &<b>mut</b> <a href="history.md#0x0_history_History">history::History</a>, maker_volume: u64, user_stake: u64, first_volume_by_user: bool)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="history.md#0x0_history_add_volume">add_volume</a>(
    self: &<b>mut</b> <a href="history.md#0x0_history_History">History</a>,
    maker_volume: u64,
    user_stake: u64,
    first_volume_by_user: bool,
) {
    <b>if</b> (maker_volume == 0) <b>return</b>;

    self.volumes.total_volume = self.volumes.total_volume + maker_volume;
    <b>if</b> (user_stake &gt; self.volumes.stake_required) {
        self.volumes.total_staked_volume = self.volumes.total_staked_volume + maker_volume;
        <b>if</b> (first_volume_by_user) {
            self.volumes.users_with_rebates = self.volumes.users_with_rebates + 1;
        }
    };
}
</code></pre>



</details>
