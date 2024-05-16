
<a name="0x0_math"></a>

# Module `0x0::math`



-  [Constants](#@Constants_0)
-  [Function `mul`](#0x0_math_mul)
-  [Function `mul_round_up`](#0x0_math_mul_round_up)
-  [Function `div`](#0x0_math_div)
-  [Function `div_round_up`](#0x0_math_div_round_up)
-  [Function `min`](#0x0_math_min)
-  [Function `max`](#0x0_math_max)
-  [Function `mul_internal`](#0x0_math_mul_internal)
-  [Function `div_internal`](#0x0_math_div_internal)


<pre><code></code></pre>



<a name="@Constants_0"></a>

## Constants


<a name="0x0_math_FLOAT_SCALING_U128"></a>

scaling setting for float


<pre><code><b>const</b> <a href="math.md#0x0_math_FLOAT_SCALING_U128">FLOAT_SCALING_U128</a>: u128 = 1000000000;
</code></pre>



<a name="0x0_math_mul"></a>

## Function `mul`

Multiply two floating numbers.
This function will round down the result.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="math.md#0x0_math_mul">mul</a>(x: u64, y: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="math.md#0x0_math_mul">mul</a>(x: u64, y: u64): u64 {
    <b>let</b> (_, result) = <a href="math.md#0x0_math_mul_internal">mul_internal</a>(x, y);

    result
}
</code></pre>



</details>

<a name="0x0_math_mul_round_up"></a>

## Function `mul_round_up`

Multiply two floating numbers.
This function will round up the result.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="math.md#0x0_math_mul_round_up">mul_round_up</a>(x: u64, y: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="math.md#0x0_math_mul_round_up">mul_round_up</a>(x: u64, y: u64): u64 {
    <b>let</b> (is_round_down, result) = <a href="math.md#0x0_math_mul_internal">mul_internal</a>(x, y);

    result + is_round_down
}
</code></pre>



</details>

<a name="0x0_math_div"></a>

## Function `div`

Divide two floating numbers.
This function will round down the result.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="math.md#0x0_math_div">div</a>(x: u64, y: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="math.md#0x0_math_div">div</a>(x: u64, y: u64): u64 {
    <b>let</b> (_, result) = <a href="math.md#0x0_math_div_internal">div_internal</a>(x, y);

    result
}
</code></pre>



</details>

<a name="0x0_math_div_round_up"></a>

## Function `div_round_up`

Divide two floating numbers.
This function will round up the result.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="math.md#0x0_math_div_round_up">div_round_up</a>(x: u64, y: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="math.md#0x0_math_div_round_up">div_round_up</a>(x: u64, y: u64): u64 {
    <b>let</b> (is_round_down, result) = <a href="math.md#0x0_math_div_internal">div_internal</a>(x, y);

    result + is_round_down
}
</code></pre>



</details>

<a name="0x0_math_min"></a>

## Function `min`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <b>min</b>(x: u64, y: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <b>min</b>(x: u64, y: u64): u64 {
    <b>if</b> (x &lt;= y) {
        x
    } <b>else</b> {
        y
    }
}
</code></pre>



</details>

<a name="0x0_math_max"></a>

## Function `max`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="math.md#0x0_math_max">max</a>(x: u64, y: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="math.md#0x0_math_max">max</a>(x: u64, y: u64): u64 {
    <b>if</b> (x &gt; y) {
        x
    } <b>else</b> {
        y
    }
}
</code></pre>



</details>

<a name="0x0_math_mul_internal"></a>

## Function `mul_internal`



<pre><code><b>fun</b> <a href="math.md#0x0_math_mul_internal">mul_internal</a>(x: u64, y: u64): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="math.md#0x0_math_mul_internal">mul_internal</a>(x: u64, y: u64): (u64, u64) {
    <b>let</b> x = x <b>as</b> u128;
    <b>let</b> y = y <b>as</b> u128;
    <b>let</b> round = <b>if</b>((x * y) % <a href="math.md#0x0_math_FLOAT_SCALING_U128">FLOAT_SCALING_U128</a> == 0) 0 <b>else</b> 1;

    (round, (x * y / <a href="math.md#0x0_math_FLOAT_SCALING_U128">FLOAT_SCALING_U128</a>) <b>as</b> u64)
}
</code></pre>



</details>

<a name="0x0_math_div_internal"></a>

## Function `div_internal`



<pre><code><b>fun</b> <a href="math.md#0x0_math_div_internal">div_internal</a>(x: u64, y: u64): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="math.md#0x0_math_div_internal">div_internal</a>(x: u64, y: u64): (u64, u64) {
    <b>let</b> x = x <b>as</b> u128;
    <b>let</b> y = y <b>as</b> u128;
    <b>let</b> round = <b>if</b> ((x * <a href="math.md#0x0_math_FLOAT_SCALING_U128">FLOAT_SCALING_U128</a> % y) == 0) 0 <b>else</b> 1;

    (round, (x * <a href="math.md#0x0_math_FLOAT_SCALING_U128">FLOAT_SCALING_U128</a> / y) <b>as</b> u64)
}
</code></pre>



</details>
