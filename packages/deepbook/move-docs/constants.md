
<a name="0x0_constants"></a>

# Module `0x0::constants`



-  [Constants](#@Constants_0)
-  [Function `pool_creation_fee`](#0x0_constants_pool_creation_fee)
-  [Function `float_scaling`](#0x0_constants_float_scaling)
-  [Function `max_u64`](#0x0_constants_max_u64)
-  [Function `no_restriction`](#0x0_constants_no_restriction)
-  [Function `immediate_or_cancel`](#0x0_constants_immediate_or_cancel)
-  [Function `fill_or_kill`](#0x0_constants_fill_or_kill)
-  [Function `post_only`](#0x0_constants_post_only)
-  [Function `max_restriction`](#0x0_constants_max_restriction)
-  [Function `live`](#0x0_constants_live)
-  [Function `partially_filled`](#0x0_constants_partially_filled)
-  [Function `filled`](#0x0_constants_filled)
-  [Function `canceled`](#0x0_constants_canceled)
-  [Function `expired`](#0x0_constants_expired)
-  [Function `self_matching_allowed`](#0x0_constants_self_matching_allowed)
-  [Function `cancel_taker`](#0x0_constants_cancel_taker)
-  [Function `cancel_maker`](#0x0_constants_cancel_maker)
-  [Function `min_price`](#0x0_constants_min_price)
-  [Function `max_price`](#0x0_constants_max_price)
-  [Function `phase_out_epochs`](#0x0_constants_phase_out_epochs)
-  [Function `default_stake_required`](#0x0_constants_default_stake_required)
-  [Function `half`](#0x0_constants_half)
-  [Function `fee_is_deep`](#0x0_constants_fee_is_deep)


<pre><code></code></pre>



<a name="@Constants_0"></a>

## Constants


<a name="0x0_constants_FLOAT_SCALING"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_FLOAT_SCALING">FLOAT_SCALING</a>: u64 = 1000000000;
</code></pre>



<a name="0x0_constants_CANCELED"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_CANCELED">CANCELED</a>: u8 = 3;
</code></pre>



<a name="0x0_constants_CANCEL_MAKER"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_CANCEL_MAKER">CANCEL_MAKER</a>: u8 = 2;
</code></pre>



<a name="0x0_constants_CANCEL_TAKER"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_CANCEL_TAKER">CANCEL_TAKER</a>: u8 = 1;
</code></pre>



<a name="0x0_constants_DEFAULT_STAKE_REQUIRED"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_DEFAULT_STAKE_REQUIRED">DEFAULT_STAKE_REQUIRED</a>: u64 = 100000000000;
</code></pre>



<a name="0x0_constants_EXPIRED"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_EXPIRED">EXPIRED</a>: u8 = 4;
</code></pre>



<a name="0x0_constants_FEE_IS_DEEP"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_FEE_IS_DEEP">FEE_IS_DEEP</a>: bool = <b>true</b>;
</code></pre>



<a name="0x0_constants_FILLED"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_FILLED">FILLED</a>: u8 = 2;
</code></pre>



<a name="0x0_constants_FILL_OR_KILL"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_FILL_OR_KILL">FILL_OR_KILL</a>: u8 = 2;
</code></pre>



<a name="0x0_constants_HALF"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_HALF">HALF</a>: u64 = 500000000;
</code></pre>



<a name="0x0_constants_IMMEDIATE_OR_CANCEL"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_IMMEDIATE_OR_CANCEL">IMMEDIATE_OR_CANCEL</a>: u8 = 1;
</code></pre>



<a name="0x0_constants_LIVE"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_LIVE">LIVE</a>: u8 = 0;
</code></pre>



<a name="0x0_constants_MAX_PRICE"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_MAX_PRICE">MAX_PRICE</a>: u64 = 4611686018427387904;
</code></pre>



<a name="0x0_constants_MAX_RESTRICTION"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_MAX_RESTRICTION">MAX_RESTRICTION</a>: u8 = 3;
</code></pre>



<a name="0x0_constants_MAX_U64"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_MAX_U64">MAX_U64</a>: u64 = 9223372036854775808;
</code></pre>



<a name="0x0_constants_MIN_PRICE"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_MIN_PRICE">MIN_PRICE</a>: u64 = 1;
</code></pre>



<a name="0x0_constants_NO_RESTRICTION"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_NO_RESTRICTION">NO_RESTRICTION</a>: u8 = 0;
</code></pre>



<a name="0x0_constants_PARTIALLY_FILLED"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_PARTIALLY_FILLED">PARTIALLY_FILLED</a>: u8 = 1;
</code></pre>



<a name="0x0_constants_PHASE_OUT_EPOCHS"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_PHASE_OUT_EPOCHS">PHASE_OUT_EPOCHS</a>: u64 = 28;
</code></pre>



<a name="0x0_constants_POOL_CREATION_FEE"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_POOL_CREATION_FEE">POOL_CREATION_FEE</a>: u64 = 100000000000;
</code></pre>



<a name="0x0_constants_POST_ONLY"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_POST_ONLY">POST_ONLY</a>: u8 = 3;
</code></pre>



<a name="0x0_constants_SELF_MATCHING_ALLOWED"></a>



<pre><code><b>const</b> <a href="constants.md#0x0_constants_SELF_MATCHING_ALLOWED">SELF_MATCHING_ALLOWED</a>: u8 = 0;
</code></pre>



<a name="0x0_constants_pool_creation_fee"></a>

## Function `pool_creation_fee`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_pool_creation_fee">pool_creation_fee</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_pool_creation_fee">pool_creation_fee</a>(): u64 {
    <a href="constants.md#0x0_constants_POOL_CREATION_FEE">POOL_CREATION_FEE</a>
}
</code></pre>



</details>

<a name="0x0_constants_float_scaling"></a>

## Function `float_scaling`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_float_scaling">float_scaling</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_float_scaling">float_scaling</a>(): u64 {
    <a href="constants.md#0x0_constants_FLOAT_SCALING">FLOAT_SCALING</a>
}
</code></pre>



</details>

<a name="0x0_constants_max_u64"></a>

## Function `max_u64`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_max_u64">max_u64</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_max_u64">max_u64</a>(): u64 {
    <a href="constants.md#0x0_constants_MAX_U64">MAX_U64</a>
}
</code></pre>



</details>

<a name="0x0_constants_no_restriction"></a>

## Function `no_restriction`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_no_restriction">no_restriction</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_no_restriction">no_restriction</a>(): u8 {
    <a href="constants.md#0x0_constants_NO_RESTRICTION">NO_RESTRICTION</a>
}
</code></pre>



</details>

<a name="0x0_constants_immediate_or_cancel"></a>

## Function `immediate_or_cancel`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_immediate_or_cancel">immediate_or_cancel</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_immediate_or_cancel">immediate_or_cancel</a>(): u8 {
    <a href="constants.md#0x0_constants_IMMEDIATE_OR_CANCEL">IMMEDIATE_OR_CANCEL</a>
}
</code></pre>



</details>

<a name="0x0_constants_fill_or_kill"></a>

## Function `fill_or_kill`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_fill_or_kill">fill_or_kill</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_fill_or_kill">fill_or_kill</a>(): u8 {
    <a href="constants.md#0x0_constants_FILL_OR_KILL">FILL_OR_KILL</a>
}
</code></pre>



</details>

<a name="0x0_constants_post_only"></a>

## Function `post_only`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_post_only">post_only</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_post_only">post_only</a>(): u8 {
    <a href="constants.md#0x0_constants_POST_ONLY">POST_ONLY</a>
}
</code></pre>



</details>

<a name="0x0_constants_max_restriction"></a>

## Function `max_restriction`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_max_restriction">max_restriction</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_max_restriction">max_restriction</a>(): u8 {
    <a href="constants.md#0x0_constants_MAX_RESTRICTION">MAX_RESTRICTION</a>
}
</code></pre>



</details>

<a name="0x0_constants_live"></a>

## Function `live`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_live">live</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_live">live</a>(): u8 {
    <a href="constants.md#0x0_constants_LIVE">LIVE</a>
}
</code></pre>



</details>

<a name="0x0_constants_partially_filled"></a>

## Function `partially_filled`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_partially_filled">partially_filled</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_partially_filled">partially_filled</a>(): u8 {
    <a href="constants.md#0x0_constants_PARTIALLY_FILLED">PARTIALLY_FILLED</a>
}
</code></pre>



</details>

<a name="0x0_constants_filled"></a>

## Function `filled`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_filled">filled</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_filled">filled</a>(): u8 {
    <a href="constants.md#0x0_constants_FILLED">FILLED</a>
}
</code></pre>



</details>

<a name="0x0_constants_canceled"></a>

## Function `canceled`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_canceled">canceled</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_canceled">canceled</a>(): u8 {
    <a href="constants.md#0x0_constants_CANCELED">CANCELED</a>
}
</code></pre>



</details>

<a name="0x0_constants_expired"></a>

## Function `expired`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_expired">expired</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_expired">expired</a>(): u8 {
    <a href="constants.md#0x0_constants_EXPIRED">EXPIRED</a>
}
</code></pre>



</details>

<a name="0x0_constants_self_matching_allowed"></a>

## Function `self_matching_allowed`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_self_matching_allowed">self_matching_allowed</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_self_matching_allowed">self_matching_allowed</a>(): u8 {
    <a href="constants.md#0x0_constants_SELF_MATCHING_ALLOWED">SELF_MATCHING_ALLOWED</a>
}
</code></pre>



</details>

<a name="0x0_constants_cancel_taker"></a>

## Function `cancel_taker`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_cancel_taker">cancel_taker</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_cancel_taker">cancel_taker</a>(): u8 {
    <a href="constants.md#0x0_constants_CANCEL_TAKER">CANCEL_TAKER</a>
}
</code></pre>



</details>

<a name="0x0_constants_cancel_maker"></a>

## Function `cancel_maker`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_cancel_maker">cancel_maker</a>(): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_cancel_maker">cancel_maker</a>(): u8 {
    <a href="constants.md#0x0_constants_CANCEL_MAKER">CANCEL_MAKER</a>
}
</code></pre>



</details>

<a name="0x0_constants_min_price"></a>

## Function `min_price`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_min_price">min_price</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_min_price">min_price</a>(): u64 {
    <a href="constants.md#0x0_constants_MIN_PRICE">MIN_PRICE</a>
}
</code></pre>



</details>

<a name="0x0_constants_max_price"></a>

## Function `max_price`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_max_price">max_price</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_max_price">max_price</a>(): u64 {
    <a href="constants.md#0x0_constants_MAX_PRICE">MAX_PRICE</a>
}
</code></pre>



</details>

<a name="0x0_constants_phase_out_epochs"></a>

## Function `phase_out_epochs`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_phase_out_epochs">phase_out_epochs</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_phase_out_epochs">phase_out_epochs</a>(): u64 {
    <a href="constants.md#0x0_constants_PHASE_OUT_EPOCHS">PHASE_OUT_EPOCHS</a>
}
</code></pre>



</details>

<a name="0x0_constants_default_stake_required"></a>

## Function `default_stake_required`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_default_stake_required">default_stake_required</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_default_stake_required">default_stake_required</a>(): u64 {
    <a href="constants.md#0x0_constants_DEFAULT_STAKE_REQUIRED">DEFAULT_STAKE_REQUIRED</a>
}
</code></pre>



</details>

<a name="0x0_constants_half"></a>

## Function `half`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_half">half</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_half">half</a>(): u64 {
    <a href="constants.md#0x0_constants_HALF">HALF</a>
}
</code></pre>



</details>

<a name="0x0_constants_fee_is_deep"></a>

## Function `fee_is_deep`



<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_fee_is_deep">fee_is_deep</a>(): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="constants.md#0x0_constants_fee_is_deep">fee_is_deep</a>(): bool {
    <a href="constants.md#0x0_constants_FEE_IS_DEEP">FEE_IS_DEEP</a>
}
</code></pre>



</details>
