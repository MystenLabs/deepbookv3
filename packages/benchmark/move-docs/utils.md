
<a name="0x0_utils"></a>

# Module `0x0::utils`

Vector-related utilities.


-  [Function `pop_until`](#0x0_utils_pop_until)
-  [Function `pop_n`](#0x0_utils_pop_n)


<pre><code><b>use</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">0x1::vector</a>;
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


<pre><code><b>public</b>(package) <b>fun</b> <a href="utils.md#0x0_utils_pop_until">pop_until</a>&lt;T&gt;(v: &<b>mut</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;T&gt;, n: u64): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;T&gt; {
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


<pre><code><b>public</b>(package) <b>fun</b> <a href="utils.md#0x0_utils_pop_n">pop_n</a>&lt;T&gt;(v: &<b>mut</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;T&gt;, <b>mut</b> n: u64): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;T&gt; {
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
