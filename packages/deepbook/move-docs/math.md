
<a name="0x0_math"></a>

# Module `0x0::math`



-  [Constants](#@Constants_0)
-  [Function `mul`](#0x0_math_mul)
-  [Function `mul_round_up`](#0x0_math_mul_round_up)
-  [Function `div`](#0x0_math_div)
-  [Function `div_round_up`](#0x0_math_div_round_up)
-  [Function `min`](#0x0_math_min)
-  [Function `max`](#0x0_math_max)
-  [Function `median`](#0x0_math_median)
-  [Function `quick_sort`](#0x0_math_quick_sort)
-  [Function `mul_internal`](#0x0_math_mul_internal)
-  [Function `div_internal`](#0x0_math_div_internal)


<pre><code><b>use</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">0x1::vector</a>;
</code></pre>



<a name="@Constants_0"></a>

## Constants


<a name="0x0_math_FLOAT_SCALING"></a>

scaling setting for float


<pre><code><b>const</b> <a href="math.md#0x0_math_FLOAT_SCALING">FLOAT_SCALING</a>: u64 = 1000000000;
</code></pre>



<a name="0x0_math_FLOAT_SCALING_U128"></a>



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

<a name="0x0_math_median"></a>

## Function `median`

given a vector of u64, return the median


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="math.md#0x0_math_median">median</a>(v: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(package) <b>fun</b> <a href="math.md#0x0_math_median">median</a>(v: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;): u64 {
    <b>let</b> n = v.length();
    <b>if</b> (n == 0) {
        <b>return</b> 0
    };

    <b>let</b> sorted_v = <a href="math.md#0x0_math_quick_sort">quick_sort</a>(v);
    <b>if</b> (n % 2 == 0) {
        <a href="math.md#0x0_math_mul">mul</a>((sorted_v[n / 2 - 1] + sorted_v[n / 2]), <a href="math.md#0x0_math_FLOAT_SCALING">FLOAT_SCALING</a> / 2)
    } <b>else</b> {
        sorted_v[n / 2]
    }
}
</code></pre>



</details>

<a name="0x0_math_quick_sort"></a>

## Function `quick_sort`



<pre><code><b>fun</b> <a href="math.md#0x0_math_quick_sort">quick_sort</a>(data: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="math.md#0x0_math_quick_sort">quick_sort</a>(<b>mut</b> data: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt; {
    <b>if</b> (data.length() &lt;= 1) {
        <b>return</b> data
    };

    <b>let</b> pivot = data[0];
    <b>let</b> <b>mut</b> less = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;[];
    <b>let</b> <b>mut</b> equal = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;[];
    <b>let</b> <b>mut</b> greater = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;[];

    <b>while</b> (data.length() &gt; 0) {
        <b>let</b> value = data.remove(0);
        <b>if</b> (value &lt; pivot) {
            less.push_back(value);
        } <b>else</b> <b>if</b> (value == pivot) {
            equal.push_back(value);
        } <b>else</b> {
            greater.push_back(value);
        };
    };

    <b>let</b> <b>mut</b> sortedData = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u64&gt;[];
    sortedData.append(<a href="math.md#0x0_math_quick_sort">quick_sort</a>(less));
    sortedData.append(equal);
    sortedData.append(<a href="math.md#0x0_math_quick_sort">quick_sort</a>(greater));
    sortedData
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
