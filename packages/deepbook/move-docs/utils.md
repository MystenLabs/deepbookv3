
<a name="0x0_utils"></a>

# Module `0x0::utils`

Deepbook utility functions.


-  [Function `pop_until`](#0x0_utils_pop_until)
-  [Function `pop_n`](#0x0_utils_pop_n)
-  [Function `compare`](#0x0_utils_compare)
-  [Function `concat_ascii`](#0x0_utils_concat_ascii)
-  [Function `encode_order_id`](#0x0_utils_encode_order_id)


<pre><code><b>use</b> <a href="dependencies/move-stdlib/ascii.md#0x1_ascii">0x1::ascii</a>;
<b>use</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">0x1::vector</a>;
<b>use</b> <a href="dependencies/sui-framework/math.md#0x2_math">0x2::math</a>;
</code></pre>



<a name="0x0_utils_pop_until"></a>

## Function `pop_until`

Pop elements from the back of <code>v</code> until its length equals <code>n</code>,
returning the elements that were popped in the order they
appeared in <code>v</code>.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="utils.md#0x0_utils_pop_until">pop_until</a>&lt;T&gt;(v: &<b>mut</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;T&gt;, n: u64): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;T&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="utils.md#0x0_utils_pop_until">pop_until</a>&lt;T&gt;(v: &<b>mut</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;T&gt;, n: u64): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;T&gt; {
    <b>let</b> <b>mut</b> res = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[];
    <b>while</b> (v.length() &gt; n) {
        res.push_back(v.pop_back());
    };

    res.reverse();
    res
}
</code></pre>



</details>

<a name="0x0_utils_pop_n"></a>

## Function `pop_n`

Pop <code>n</code> elements from the back of <code>v</code>, returning the elements
that were popped in the order they appeared in <code>v</code>.

Aborts if <code>v</code> has fewer than <code>n</code> elements.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="utils.md#0x0_utils_pop_n">pop_n</a>&lt;T&gt;(v: &<b>mut</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;T&gt;, n: u64): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;T&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="utils.md#0x0_utils_pop_n">pop_n</a>&lt;T&gt;(v: &<b>mut</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;T&gt;, <b>mut</b> n: u64): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;T&gt; {
    <b>let</b> <b>mut</b> res = <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[];
    <b>while</b> (n &gt; 0) {
        res.push_back(v.pop_back());
        n = n - 1;
    };

    res.reverse();
    res
}
</code></pre>



</details>

<a name="0x0_utils_compare"></a>

## Function `compare`

Compare two ASCII strings, return True if first string is less than or
equal to the second string in lexicographic order


<pre><code><b>public</b> <b>fun</b> <a href="utils.md#0x0_utils_compare">compare</a>(str1: &<a href="dependencies/move-stdlib/ascii.md#0x1_ascii_String">ascii::String</a>, str2: &<a href="dependencies/move-stdlib/ascii.md#0x1_ascii_String">ascii::String</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="utils.md#0x0_utils_compare">compare</a>(str1: &String, str2: &String): bool {
    <b>if</b> (str1 == str2) <b>return</b> <b>true</b>;

    <b>let</b> min_len = <a href="dependencies/sui-framework/math.md#0x2_math_min">math::min</a>(str1.length(), str2.length());
    <b>let</b> (bytes1, bytes2) = (str1.as_bytes(), str2.as_bytes());

    // skip until bytes are different or one of the strings ends;
    <b>let</b> <b>mut</b> i: u64 = 0;
    <b>while</b> (i &lt; min_len && bytes1[i] == bytes2[i]) {
        i = i + 1
    };

    <b>if</b> (i == min_len) {
        (str1.length() &lt;= str2.length())
    } <b>else</b> {
        (bytes1[i] &lt;= bytes2[i])
    }
}
</code></pre>



</details>

<a name="0x0_utils_concat_ascii"></a>

## Function `concat_ascii`

Concatenate two ASCII strings and return the result.


<pre><code><b>public</b> <b>fun</b> <a href="utils.md#0x0_utils_concat_ascii">concat_ascii</a>(str1: <a href="dependencies/move-stdlib/ascii.md#0x1_ascii_String">ascii::String</a>, str2: <a href="dependencies/move-stdlib/ascii.md#0x1_ascii_String">ascii::String</a>): <a href="dependencies/move-stdlib/ascii.md#0x1_ascii_String">ascii::String</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="utils.md#0x0_utils_concat_ascii">concat_ascii</a>(str1: String, str2: String): String {
    // Append bytes from the first <a href="dependencies/move-stdlib/string.md#0x1_string">string</a>
    <b>let</b> <b>mut</b> bytes1 = str1.into_bytes();
    <b>let</b> bytes2 = str2.into_bytes();

    bytes1.append(bytes2);
    bytes1.to_ascii_string()
}
</code></pre>



</details>

<a name="0x0_utils_encode_order_id"></a>

## Function `encode_order_id`

first bit is 0 for bid, 1 for ask
next 63 bits are price (assertion for price is done in order function)
last 64 bits are order_id


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="utils.md#0x0_utils_encode_order_id">encode_order_id</a>(is_bid: bool, price: u64, order_id: u64): u128
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<a href="dependencies/sui-framework/package.md#0x2_package">package</a>) <b>fun</b> <a href="utils.md#0x0_utils_encode_order_id">encode_order_id</a>(
    is_bid: bool,
    price: u64,
    order_id: u64
): u128 {
    <b>if</b> (is_bid) {
        ((price <b>as</b> u128) &lt;&lt; 64) + (order_id <b>as</b> u128)
    } <b>else</b> {
        (1u128 &lt;&lt; 127) + ((price <b>as</b> u128) &lt;&lt; 64) + (order_id <b>as</b> u128)
    }
}
</code></pre>



</details>
