
<a name="0x0_math"></a>

# Module `0x0::math`



-  [Constants](#@Constants_0)
-  [Function `mul`](#0x0_math_mul)
-  [Function `mul_round_up`](#0x0_math_mul_round_up)
-  [Function `unsafe_mul_round`](#0x0_math_unsafe_mul_round)
-  [Function `div`](#0x0_math_div)
-  [Function `unsafe_div_round`](#0x0_math_unsafe_div_round)
-  [Function `min`](#0x0_math_min)
-  [Function `max`](#0x0_math_max)


<pre><code></code></pre>



<a name="@Constants_0"></a>

## Constants


<a name="0x0_math_EUnderflow"></a>



<pre><code><b>const</b> <a href="math.md#0x0_math_EUnderflow">EUnderflow</a>: u64 = 1;
</code></pre>



<a name="0x0_math_FLOAT_SCALING_U128"></a>

scaling setting for float


<pre><code><b>const</b> <a href="math.md#0x0_math_FLOAT_SCALING_U128">FLOAT_SCALING_U128</a>: u128 = 1000000000;
</code></pre>



<a name="0x0_math_mul"></a>

## Function `mul`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="math.md#0x0_math_mul">mul</a>(x: u64, y: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="math.md#0x0_math_mul">mul</a>(x: u64, y: u64): u64 {
    <b>let</b> (_, result) = <a href="math.md#0x0_math_unsafe_mul_round">unsafe_mul_round</a>(x, y);
    result
}
</code></pre>



</details>

<a name="0x0_math_mul_round_up"></a>

## Function `mul_round_up`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="math.md#0x0_math_mul_round_up">mul_round_up</a>(x: u64, y: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="math.md#0x0_math_mul_round_up">mul_round_up</a>(x: u64, y: u64): u64 {
    <b>let</b> (is_round_down, result) = <a href="math.md#0x0_math_unsafe_mul_round">unsafe_mul_round</a>(x, y);
    <b>assert</b>!(result &gt; 0, <a href="math.md#0x0_math_EUnderflow">EUnderflow</a>);
    <b>if</b> (is_round_down) {
        result + 1
    } <b>else</b> {
        result
    }
}
</code></pre>



</details>

<a name="0x0_math_unsafe_mul_round"></a>

## Function `unsafe_mul_round`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="math.md#0x0_math_unsafe_mul_round">unsafe_mul_round</a>(x: u64, y: u64): (bool, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="math.md#0x0_math_unsafe_mul_round">unsafe_mul_round</a>(x: u64, y: u64): (bool, u64) {
    <b>let</b> x = x <b>as</b> u128;
    <b>let</b> y = y <b>as</b> u128;
    <b>let</b> <b>mut</b> is_round_down = <b>true</b>;
    <b>if</b> ((x * y) % <a href="math.md#0x0_math_FLOAT_SCALING_U128">FLOAT_SCALING_U128</a> == 0) is_round_down = <b>false</b>;
    (is_round_down, (x * y / <a href="math.md#0x0_math_FLOAT_SCALING_U128">FLOAT_SCALING_U128</a>) <b>as</b> u64)
}
</code></pre>



</details>

<a name="0x0_math_div"></a>

## Function `div`

divide two floating numbers


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="math.md#0x0_math_div">div</a>(x: u64, y: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="math.md#0x0_math_div">div</a>(x: u64, y: u64): u64 {
    <b>let</b> (_, result) = <a href="math.md#0x0_math_unsafe_div_round">unsafe_div_round</a>(x, y);
    result
}
</code></pre>



</details>

<a name="0x0_math_unsafe_div_round"></a>

## Function `unsafe_div_round`

divide two floating numbers
also returns whether the result is rounded down


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="math.md#0x0_math_unsafe_div_round">unsafe_div_round</a>(x: u64, y: u64): (bool, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="math.md#0x0_math_unsafe_div_round">unsafe_div_round</a>(x: u64, y: u64): (bool, u64) {
    <b>let</b> x = x <b>as</b> u128;
    <b>let</b> y = y <b>as</b> u128;
    <b>let</b> <b>mut</b> is_round_down = <b>true</b>;
    <b>if</b> ((x * <a href="math.md#0x0_math_FLOAT_SCALING_U128">FLOAT_SCALING_U128</a> % y) == 0) is_round_down = <b>false</b>;
    (is_round_down, (x * <a href="math.md#0x0_math_FLOAT_SCALING_U128">FLOAT_SCALING_U128</a> / y) <b>as</b> u64)
}
</code></pre>



</details>

<a name="0x0_math_min"></a>

## Function `min`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <b>min</b>(x: u64, y: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <b>min</b>(x: u64, y: u64): u64 {
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


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="math.md#0x0_math_max">max</a>(x: u64, y: u64): u64 {
    <b>if</b> (x &gt; y) {
        x
    } <b>else</b> {
        y
    }
}
</code></pre>



</details>
