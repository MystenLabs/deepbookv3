
<a name="0x0_big_vector"></a>

# Module `0x0::big_vector`

BigVector is an arbitrary sized vector-like data structure,
implemented using an on-chain B+ Tree to support almost constant
time (log base max_fan_out) random access, insertion and removal.

Iteration is supported by exposing access to leaf nodes (slices).
Finding the initial slice can be done in almost constant time, and
subsequently finding the previous or next slice can also be done
in constant time.

Nodes in the B+ Tree are stored as individual dynamic fields
hanging off the <code><a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a></code>.

Note: The index type is <code>u128</code>, but the length is stored as <code>u64</code>
because the expectation is that indices are sparsely distributed.


-  [Resource `BigVector`](#0x0_big_vector_BigVector)
-  [Struct `Slice`](#0x0_big_vector_Slice)
-  [Struct `SliceRef`](#0x0_big_vector_SliceRef)
-  [Constants](#@Constants_0)
-  [Function `empty`](#0x0_big_vector_empty)
-  [Function `destroy_empty`](#0x0_big_vector_destroy_empty)
-  [Function `drop`](#0x0_big_vector_drop)
-  [Function `is_empty`](#0x0_big_vector_is_empty)
-  [Function `length`](#0x0_big_vector_length)
-  [Function `depth`](#0x0_big_vector_depth)
-  [Function `borrow`](#0x0_big_vector_borrow)
-  [Function `borrow_mut`](#0x0_big_vector_borrow_mut)
-  [Function `valid_next`](#0x0_big_vector_valid_next)
-  [Function `borrow_next`](#0x0_big_vector_borrow_next)
-  [Function `borrow_next_mut`](#0x0_big_vector_borrow_next_mut)
-  [Function `valid_prev`](#0x0_big_vector_valid_prev)
-  [Function `borrow_prev`](#0x0_big_vector_borrow_prev)
-  [Function `borrow_prev_mut`](#0x0_big_vector_borrow_prev_mut)
-  [Function `insert`](#0x0_big_vector_insert)
-  [Function `insert_batch`](#0x0_big_vector_insert_batch)
-  [Function `remove`](#0x0_big_vector_remove)
-  [Function `remove_range`](#0x0_big_vector_remove_range)
-  [Function `remove_batch`](#0x0_big_vector_remove_batch)
-  [Function `slice_around`](#0x0_big_vector_slice_around)
-  [Function `slice_following`](#0x0_big_vector_slice_following)
-  [Function `slice_before`](#0x0_big_vector_slice_before)
-  [Function `min_slice`](#0x0_big_vector_min_slice)
-  [Function `max_slice`](#0x0_big_vector_max_slice)
-  [Function `borrow_slice`](#0x0_big_vector_borrow_slice)
-  [Function `borrow_slice_mut`](#0x0_big_vector_borrow_slice_mut)
-  [Function `slice_is_null`](#0x0_big_vector_slice_is_null)
-  [Function `slice_is_leaf`](#0x0_big_vector_slice_is_leaf)
-  [Function `slice_next`](#0x0_big_vector_slice_next)
-  [Function `slice_prev`](#0x0_big_vector_slice_prev)
-  [Function `slice_length`](#0x0_big_vector_slice_length)
-  [Function `slice_key`](#0x0_big_vector_slice_key)
-  [Function `slice_borrow`](#0x0_big_vector_slice_borrow)
-  [Function `slice_borrow_mut`](#0x0_big_vector_slice_borrow_mut)
-  [Function `alloc`](#0x0_big_vector_alloc)
-  [Function `singleton`](#0x0_big_vector_singleton)
-  [Function `branch`](#0x0_big_vector_branch)
-  [Function `drop_slice`](#0x0_big_vector_drop_slice)
-  [Function `find_leaf`](#0x0_big_vector_find_leaf)
-  [Function `find_min_leaf`](#0x0_big_vector_find_min_leaf)
-  [Function `find_max_leaf`](#0x0_big_vector_find_max_leaf)
-  [Function `slice_bisect_left`](#0x0_big_vector_slice_bisect_left)
-  [Function `slice_bisect_right`](#0x0_big_vector_slice_bisect_right)
-  [Function `slice_insert`](#0x0_big_vector_slice_insert)
-  [Function `leaf_insert`](#0x0_big_vector_leaf_insert)
-  [Function `node_insert`](#0x0_big_vector_node_insert)
-  [Function `slice_remove`](#0x0_big_vector_slice_remove)
-  [Function `leaf_remove`](#0x0_big_vector_leaf_remove)
-  [Function `node_remove`](#0x0_big_vector_node_remove)
-  [Function `slice_redistribute`](#0x0_big_vector_slice_redistribute)
-  [Function `slice_merge`](#0x0_big_vector_slice_merge)


<pre><code><b>use</b> <a href="utils.md#0x0_utils">0x0::utils</a>;
<b>use</b> <a href="dependencies/move-stdlib/vector.md#0x1_vector">0x1::vector</a>;
<b>use</b> <a href="dependencies/sui-framework/dynamic_field.md#0x2_dynamic_field">0x2::dynamic_field</a>;
<b>use</b> <a href="dependencies/sui-framework/object.md#0x2_object">0x2::object</a>;
<b>use</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context">0x2::tx_context</a>;
</code></pre>



<a name="0x0_big_vector_BigVector"></a>

## Resource `BigVector`



<pre><code><b>struct</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E: store&gt; <b>has</b> store, key
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>id: <a href="dependencies/sui-framework/object.md#0x2_object_UID">object::UID</a></code>
</dt>
<dd>

</dd>
<dt>
<code>depth: u8</code>
</dt>
<dd>
 How deep the tree structure is.
</dd>
<dt>
<code>length: u64</code>
</dt>
<dd>
 Total number of elements that this vector contains, not
 including gaps in the vector.
</dd>
<dt>
<code>max_slice_size: u64</code>
</dt>
<dd>
 Max size of leaf nodes (counted in number of elements, <code>E</code>).
</dd>
<dt>
<code>max_fan_out: u64</code>
</dt>
<dd>
 Max size of interior nodes (counted in number of children).
</dd>
<dt>
<code>root_id: u64</code>
</dt>
<dd>
 ID of the tree's root structure. Value of <code><a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a></code> means
 there's no root.
</dd>
<dt>
<code>last_id: u64</code>
</dt>
<dd>
 The last node ID that was allocated.
</dd>
</dl>


</details>

<a name="0x0_big_vector_Slice"></a>

## Struct `Slice`

A node in the B+ tree.

If representing a leaf node, there are as many keys as values
(such that <code>keys[i]</code> is the key corresponding to <code>vals[i]</code>).

A <code><a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;u64&gt;</code> can also represent an interior node, in which
case <code>vals</code> contain the IDs of its children and <code>keys</code>
represent the partitions between children. There will be one
fewer key than value in this configuration.


<pre><code><b>struct</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E: store&gt; <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>prev: u64</code>
</dt>
<dd>
 Previous node in the intrusive doubly-linked list data
 structure.
</dd>
<dt>
<code>next: u64</code>
</dt>
<dd>
 Next node in the intrusive doubly-linked list data
 structure.
</dd>
<dt>
<code>keys: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u128&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>vals: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;E&gt;</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="0x0_big_vector_SliceRef"></a>

## Struct `SliceRef`

Wrapper type around indices for slices. The internal index is
the ID of the dynamic field containing the slice.


<pre><code><b>struct</b> <a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>ix: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a name="@Constants_0"></a>

## Constants


<a name="0x0_big_vector_EBadRedistribution"></a>

Tried to redistribute between two nodes, but the operation
would have had no effect.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_EBadRedistribution">EBadRedistribution</a>: u64 = 9;
</code></pre>



<a name="0x0_big_vector_EBadRemove"></a>

Found a node in an unexpected state during removal (namely, we
tried to remove from a node's child and found that it had
become empty, which should not be possible).


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_EBadRemove">EBadRemove</a>: u64 = 7;
</code></pre>



<a name="0x0_big_vector_EExists"></a>

Key already exists in <code><a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a></code>.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_EExists">EExists</a>: u64 = 6;
</code></pre>



<a name="0x0_big_vector_EFanOutTooBig"></a>

Max Fan-out provided is too big.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_EFanOutTooBig">EFanOutTooBig</a>: u64 = 3;
</code></pre>



<a name="0x0_big_vector_EFanOutTooSmall"></a>

Max Fan-out provided is too small.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_EFanOutTooSmall">EFanOutTooSmall</a>: u64 = 2;
</code></pre>



<a name="0x0_big_vector_ENotAdjacent"></a>

Found a pair of nodes that are expected to be adjacent but
whose linked list pointers don't match up.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_ENotAdjacent">ENotAdjacent</a>: u64 = 8;
</code></pre>



<a name="0x0_big_vector_ENotEmpty"></a>

<code><a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a></code> is not empty.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_ENotEmpty">ENotEmpty</a>: u64 = 4;
</code></pre>



<a name="0x0_big_vector_ENotFound"></a>

Key not found in <code><a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a></code>.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_ENotFound">ENotFound</a>: u64 = 5;
</code></pre>



<a name="0x0_big_vector_ESliceTooBig"></a>

Max Slice Size provided is too big.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_ESliceTooBig">ESliceTooBig</a>: u64 = 1;
</code></pre>



<a name="0x0_big_vector_ESliceTooSmall"></a>

Max Slice Size provided is too small.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_ESliceTooSmall">ESliceTooSmall</a>: u64 = 0;
</code></pre>



<a name="0x0_big_vector_MAX_FAN_OUT"></a>

Internal nodes of <code><a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a></code> can't have more children than
this, to avoid hitting object size limits.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_MAX_FAN_OUT">MAX_FAN_OUT</a>: u64 = 4096;
</code></pre>



<a name="0x0_big_vector_MAX_SLICE_SIZE"></a>

Leaf nodes of <code><a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a></code> can't be bigger than this, to avoid
hitting object size limits.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_MAX_SLICE_SIZE">MAX_SLICE_SIZE</a>: u64 = 262144;
</code></pre>



<a name="0x0_big_vector_MIN_FAN_OUT"></a>

We will accommodate at least this much fan out before
splitting interior nodes, so that after the split, we don't
get an interior node that contains only one child.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_MIN_FAN_OUT">MIN_FAN_OUT</a>: u64 = 4;
</code></pre>



<a name="0x0_big_vector_NO_SLICE"></a>

Sentinel representing the absence of a slice.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>: u64 = 0;
</code></pre>



<a name="0x0_big_vector_RM_FIX_EMPTY"></a>

0b001: Node is completely empty (applies only to root).


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_RM_FIX_EMPTY">RM_FIX_EMPTY</a>: u8 = 1;
</code></pre>



<a name="0x0_big_vector_RM_FIX_MERGE_L"></a>

0b100: Merged with the left neighbour.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_RM_FIX_MERGE_L">RM_FIX_MERGE_L</a>: u8 = 4;
</code></pre>



<a name="0x0_big_vector_RM_FIX_MERGE_R"></a>

0b101: Merged with the right neighbour.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_RM_FIX_MERGE_R">RM_FIX_MERGE_R</a>: u8 = 5;
</code></pre>



<a name="0x0_big_vector_RM_FIX_NOTHING"></a>

0b000: No fix-up.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_RM_FIX_NOTHING">RM_FIX_NOTHING</a>: u8 = 0;
</code></pre>



<a name="0x0_big_vector_RM_FIX_STEAL_L"></a>

0b010: Stole a key from the left neighbour, additional value
is the new pivot after the steal.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_RM_FIX_STEAL_L">RM_FIX_STEAL_L</a>: u8 = 2;
</code></pre>



<a name="0x0_big_vector_RM_FIX_STEAL_R"></a>

0b011: Stole a key from the right neighbour, additional value
is the new pivot after the steal.


<pre><code><b>const</b> <a href="big_vector.md#0x0_big_vector_RM_FIX_STEAL_R">RM_FIX_STEAL_R</a>: u8 = 3;
</code></pre>



<a name="0x0_big_vector_empty"></a>

## Function `empty`

Construct a new, empty <code><a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a></code>. <code>max_slice_size</code> contains
the maximum size of its leaf nodes, and <code>max_fan_out</code> contains
the maximum fan-out of its interior nodes.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_empty">empty</a>&lt;E: store&gt;(max_slice_size: u64, max_fan_out: u64, ctx: &<b>mut</b> <a href="dependencies/sui-framework/tx_context.md#0x2_tx_context_TxContext">tx_context::TxContext</a>): <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_empty">empty</a>&lt;E: store&gt;(
    max_slice_size: u64,
    max_fan_out: u64,
    ctx: &<b>mut</b> TxContext,
): <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt; {
    <b>assert</b>!(0 &lt; max_slice_size, <a href="big_vector.md#0x0_big_vector_ESliceTooSmall">ESliceTooSmall</a>);
    <b>assert</b>!(max_slice_size &lt;= <a href="big_vector.md#0x0_big_vector_MAX_SLICE_SIZE">MAX_SLICE_SIZE</a>, <a href="big_vector.md#0x0_big_vector_ESliceTooBig">ESliceTooBig</a>);
    <b>assert</b>!(<a href="big_vector.md#0x0_big_vector_MIN_FAN_OUT">MIN_FAN_OUT</a> &lt;= max_fan_out, <a href="big_vector.md#0x0_big_vector_EFanOutTooSmall">EFanOutTooSmall</a>);
    <b>assert</b>!(max_fan_out &lt;= <a href="big_vector.md#0x0_big_vector_MAX_FAN_OUT">MAX_FAN_OUT</a>, <a href="big_vector.md#0x0_big_vector_EFanOutTooBig">EFanOutTooBig</a>);

    <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a> {
        id: ctx.new(),

        depth: 0,
        length: 0,

        max_slice_size,
        max_fan_out,

        root_id: <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>,
        last_id: <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>,
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_destroy_empty"></a>

## Function `destroy_empty`

Destroy <code>self</code> as long as it is empty, even if its elements
are not droppable. Fails if <code>self</code> is not empty.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_destroy_empty">destroy_empty</a>&lt;E: store&gt;(self: <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_destroy_empty">destroy_empty</a>&lt;E: store&gt;(self: <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;) {
    <b>let</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a> {
        id,

        depth: _,
        length,
        max_slice_size: _,
        max_fan_out: _,

        root_id: _,
        last_id: _,
    } = self;

    <b>assert</b>!(length == 0, <a href="big_vector.md#0x0_big_vector_ENotEmpty">ENotEmpty</a>);
    id.delete();
}
</code></pre>



</details>

<a name="0x0_big_vector_drop"></a>

## Function `drop`

Destroy <code>self</code>, even if it contains elements, as long as they
are droppable.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_drop">drop</a>&lt;E: drop, store&gt;(self: <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_drop">drop</a>&lt;E: store + drop&gt;(self: <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;) {
    <b>let</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a> {
        <b>mut</b> id,

        depth,
        length: _,
        max_slice_size: _,
        max_fan_out: _,

        root_id,
        last_id: _,
    } = self;

    <a href="big_vector.md#0x0_big_vector_drop_slice">drop_slice</a>&lt;E&gt;(&<b>mut</b> id, depth, root_id);
    id.delete();
}
</code></pre>



</details>

<a name="0x0_big_vector_is_empty"></a>

## Function `is_empty`

Whether <code>self</code> contains no elements or not.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_is_empty">is_empty</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_is_empty">is_empty</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;): bool {
    self.length == 0
}
</code></pre>



</details>

<a name="0x0_big_vector_length"></a>

## Function `length`

The number of elements contained in <code>self</code>.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_length">length</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_length">length</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;): u64 {
    self.length
}
</code></pre>



</details>

<a name="0x0_big_vector_depth"></a>

## Function `depth`

The number of nodes between the root and the leaves in <code>self</code>.
This is within a constant factor of log base <code>max_fan_out</code> of
the length.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_depth">depth</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_depth">depth</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;): u8 {
    self.depth
}
</code></pre>



</details>

<a name="0x0_big_vector_borrow"></a>

## Function `borrow`

Access the element at index <code>ix</code> in <code>self</code>.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow">borrow</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, ix: u128): &E
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow">borrow</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;, ix: u128): &E {
    <b>let</b> (ref, offset) = self.<a href="big_vector.md#0x0_big_vector_slice_around">slice_around</a>(ix);
    <b>let</b> slice = self.<a href="big_vector.md#0x0_big_vector_borrow_slice">borrow_slice</a>(ref);
    &slice[offset]
}
</code></pre>



</details>

<a name="0x0_big_vector_borrow_mut"></a>

## Function `borrow_mut`

Access the element at index <code>ix</code> in <code>self</code>, mutably.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow_mut">borrow_mut</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, ix: u128): &<b>mut</b> E
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow_mut">borrow_mut</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;, ix: u128): &<b>mut</b> E {
    <b>let</b> (ref, offset) = self.<a href="big_vector.md#0x0_big_vector_slice_around">slice_around</a>(ix);
    <b>let</b> slice = self.<a href="big_vector.md#0x0_big_vector_borrow_slice_mut">borrow_slice_mut</a>(ref);
    &<b>mut</b> slice[offset]
}
</code></pre>



</details>

<a name="0x0_big_vector_valid_next"></a>

## Function `valid_next`

Return whether there is a valid next value in BigVector


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_valid_next">valid_next</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, ref: <a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, offset: u64): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_valid_next">valid_next</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;, ref: <a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, offset: u64): bool {
    <b>let</b> slice = self.<a href="big_vector.md#0x0_big_vector_borrow_slice">borrow_slice</a>(ref);
    (offset + 1 &lt; slice.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>() || !slice.next().is_null())
}
</code></pre>



</details>

<a name="0x0_big_vector_borrow_next"></a>

## Function `borrow_next`

Gets the next value within slice if exists, if at maximum gets the next element of the next slice
Assumes valid_next is true
Returns the next slice reference, the offset within the slice, and the immutable reference to the value


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow_next">borrow_next</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, ref: <a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, offset: u64): (<a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, u64, &E)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow_next">borrow_next</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;, ref: <a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, offset: u64): (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, u64, &E) {
    <b>let</b> slice = self.<a href="big_vector.md#0x0_big_vector_borrow_slice">borrow_slice</a>(ref);
    <b>if</b> (offset + 1 &lt; slice.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>()) {
        (ref, offset + 1, &slice[offset + 1])
    } <b>else</b> {
        <b>let</b> next_ref = slice.next();
        <b>let</b> next_slice = self.<a href="big_vector.md#0x0_big_vector_borrow_slice">borrow_slice</a>(next_ref);

        (next_ref, 0, &next_slice.vals[0])
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_borrow_next_mut"></a>

## Function `borrow_next_mut`

Gets the next value within slice if exists, if at maximum gets the next element of the next slice
Assumes valid_next is true
Returns the next slice reference, the offset within the slice, and the mutable reference to the value


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow_next_mut">borrow_next_mut</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, ref: <a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, offset: u64): (<a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, u64, &<b>mut</b> E)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow_next_mut">borrow_next_mut</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;, ref: <a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, offset: u64): (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, u64, &<b>mut</b> E) {
    <b>let</b> slice = self.<a href="big_vector.md#0x0_big_vector_borrow_slice_mut">borrow_slice_mut</a>(ref);
    <b>if</b> (offset + 1 &lt; slice.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>()) {
        (ref, offset + 1, &<b>mut</b> slice[offset + 1])
    } <b>else</b> {
        <b>let</b> next_ref = slice.next();
        <b>let</b> next_slice = self.<a href="big_vector.md#0x0_big_vector_borrow_slice_mut">borrow_slice_mut</a>(next_ref);

        (next_ref, 0, &<b>mut</b> next_slice.vals[0])
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_valid_prev"></a>

## Function `valid_prev`

Return whether there is a valid prev value in BigVector


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_valid_prev">valid_prev</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, ref: <a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, offset: u64): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_valid_prev">valid_prev</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;, ref: <a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, offset: u64): bool {
    <b>let</b> slice = self.<a href="big_vector.md#0x0_big_vector_borrow_slice">borrow_slice</a>(ref);
    (offset &gt; 0 || !slice.prev().is_null())
}
</code></pre>



</details>

<a name="0x0_big_vector_borrow_prev"></a>

## Function `borrow_prev`

Gets the prev value within slice if exists, if at minimum gets the last element of the prev slice
Assumes valid_prev is true
Returns the prev slice reference, the offset within the slice, and the immutable reference to the value


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow_prev">borrow_prev</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, ref: <a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, offset: u64): (<a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, u64, &E)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow_prev">borrow_prev</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;, ref: <a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, offset: u64): (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, u64, &E) {
    <b>let</b> slice = self.<a href="big_vector.md#0x0_big_vector_borrow_slice">borrow_slice</a>(ref);
    <b>if</b> (offset &gt; 0) {
        (ref, offset - 1, &slice[offset - 1])
    } <b>else</b> {
        <b>let</b> prev_ref = slice.prev();
        // Borrow the previous slice and get the last element
        <b>let</b> prev_slice = self.<a href="big_vector.md#0x0_big_vector_borrow_slice">borrow_slice</a>(prev_ref);
        <b>let</b> last_index = prev_slice.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>() - 1;

        (prev_ref, last_index, &prev_slice[last_index])
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_borrow_prev_mut"></a>

## Function `borrow_prev_mut`

Gets the prev value within slice if exists, if at minimum gets the last element of the prev slice
Assumes valid_prev is true
Returns the prev slice reference, the offset within the slice, and the mutable reference to the value


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow_prev_mut">borrow_prev_mut</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, ref: <a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, offset: u64): (<a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, u64, &<b>mut</b> E)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow_prev_mut">borrow_prev_mut</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;, ref: <a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, offset: u64): (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, u64, &<b>mut</b> E) {
    <b>let</b> slice = self.<a href="big_vector.md#0x0_big_vector_borrow_slice_mut">borrow_slice_mut</a>(ref);
    <b>if</b> (offset &gt; 0) {
        (ref, offset - 1, &<b>mut</b> slice[offset - 1])
    } <b>else</b> {
        <b>let</b> prev_ref = slice.prev();
        // Borrow the previous slice and get the last element
        <b>let</b> prev_slice = self.<a href="big_vector.md#0x0_big_vector_borrow_slice_mut">borrow_slice_mut</a>(prev_ref);
        <b>let</b> last_index = prev_slice.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>() - 1;

        (prev_ref, last_index, &<b>mut</b> prev_slice[last_index])
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_insert"></a>

## Function `insert`

Add <code>val</code> to <code>self</code> at index <code>key</code>. Aborts if <code>key</code> is already
present in <code>self</code>.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_insert">insert</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, key: u128, val: E)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_insert">insert</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;, key: u128, val: E) {
    self.length = self.length + 1;

    <b>if</b> (self.root_id == <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        self.root_id = self.<a href="big_vector.md#0x0_big_vector_alloc">alloc</a>(<a href="big_vector.md#0x0_big_vector_singleton">singleton</a>(key, val));
        <b>return</b>
    };

    <b>let</b> (root_id, depth) = (self.root_id, self.depth);
    <b>let</b> (key, other) = self.<a href="big_vector.md#0x0_big_vector_slice_insert">slice_insert</a>(root_id, depth, key, val);

    <b>if</b> (other != <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        self.root_id = self.<a href="big_vector.md#0x0_big_vector_alloc">alloc</a>(<a href="big_vector.md#0x0_big_vector_branch">branch</a>(key, root_id, other));
        self.depth = self.depth + 1;
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_insert_batch"></a>

## Function `insert_batch`

Adds key value pairs from <code>keys</code> and <code>vals</code> to <code>self</code>.
Requires that <code>keys</code> and <code>vals</code> have the same length, and that
<code>keys</code> is in sorted order.

Aborts if any of the keys are already present in <code>self</code>, or
the requirements on <code>keys</code> and <code>vals</code> are not met.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_insert_batch">insert_batch</a>&lt;E: store&gt;(_self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, _keys: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u128&gt;, _vals: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;E&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_insert_batch">insert_batch</a>&lt;E: store&gt;(
    _self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    _keys: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u128&gt;,
    _vals: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;E&gt;,
) {
    <b>abort</b> 0
}
</code></pre>



</details>

<a name="0x0_big_vector_remove"></a>

## Function `remove`

Remove the element with key <code>key</code> from <code>self</code>, returning its
value. Aborts if <code>key</code> is not found.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_remove">remove</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, key: u128): E
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_remove">remove</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;, key: u128): E {
    self.length = self.length - 1;

    <b>if</b> (self.root_id == <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>abort</b> <a href="big_vector.md#0x0_big_vector_ENotFound">ENotFound</a>
    };

    <b>let</b> (root_id, depth) = (self.root_id, self.depth);
    <b>let</b> (val, rm_fix, _) = self.<a href="big_vector.md#0x0_big_vector_slice_remove">slice_remove</a>(
        <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>,
        0u128,
        root_id,
        0u128,
        <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>,
        depth,
        key,
    );

    <b>if</b> (rm_fix == <a href="big_vector.md#0x0_big_vector_RM_FIX_EMPTY">RM_FIX_EMPTY</a>) {
        <b>if</b> (self.depth == 0) {
            <b>let</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt; {
                prev: _,
                next: _,
                keys: _,
                vals,
            } = df::remove(&<b>mut</b> self.id, root_id);

            // SAFETY: The slice is guaranteed <b>to</b> be empty because
            // it is a leaf and we received the <a href="big_vector.md#0x0_big_vector_RM_FIX_EMPTY">RM_FIX_EMPTY</a>
            // fix-up.
            vals.<a href="big_vector.md#0x0_big_vector_destroy_empty">destroy_empty</a>();

            self.root_id = <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>;
        } <b>else</b> {
            <b>let</b> <b>mut</b> root: <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;u64&gt; = df::remove(&<b>mut</b> self.id, root_id);
            self.root_id = root.vals.pop_back();
            self.depth = self.depth - 1;
        }
    };

    val
}
</code></pre>



</details>

<a name="0x0_big_vector_remove_range"></a>

## Function `remove_range`

Remove the elements between <code>lo</code> (inclusive) and <code>hi</code>
(exclusive) from <code>self</code>.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_remove_range">remove_range</a>&lt;E: drop, store&gt;(_self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, _lo: u128, _hi: u128)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_remove_range">remove_range</a>&lt;E: store + drop&gt;(
    _self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    _lo: u128,
    _hi: u128,
) {
    <b>abort</b> 0
}
</code></pre>



</details>

<a name="0x0_big_vector_remove_batch"></a>

## Function `remove_batch`

Remove elements from <code>self</code> at the indices in <code>keys</code>,
returning the associated values.

Aborts if any of the keys are not found.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_remove_batch">remove_batch</a>&lt;E: store&gt;(_self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, _keys: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u128&gt;): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;E&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_remove_batch">remove_batch</a>&lt;E: store&gt;(
    _self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    _keys: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;u128&gt;,
): <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>&lt;E&gt; {
    <b>abort</b> 0
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_around"></a>

## Function `slice_around`

Find the slice that contains the key-value pair for <code>key</code>,
assuming it exists in the data structure. Returns the
reference to the slice and the local offset within the slice
if it exists, aborts with <code><a href="big_vector.md#0x0_big_vector_ENotFound">ENotFound</a></code> otherwise.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_around">slice_around</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, key: u128): (<a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_around">slice_around</a>&lt;E: store&gt;(
    self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    key: u128,
): (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, u64) {
    <b>if</b> (self.root_id == <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>abort</b> <a href="big_vector.md#0x0_big_vector_ENotFound">ENotFound</a>
    };

    <b>let</b> (ix, leaf, off) = self.<a href="big_vector.md#0x0_big_vector_find_leaf">find_leaf</a>(key);

    <b>if</b> (off &gt;= leaf.keys.<a href="big_vector.md#0x0_big_vector_length">length</a>()) {
        <b>abort</b> <a href="big_vector.md#0x0_big_vector_ENotFound">ENotFound</a>
    } <b>else</b> <b>if</b> (key != leaf.keys[off]) {
        <b>abort</b> <a href="big_vector.md#0x0_big_vector_ENotFound">ENotFound</a>
    };

    (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> { ix }, off)
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_following"></a>

## Function `slice_following`

Find the slice that contains the key-value pair corresponding
to the next key in <code>self</code> at or after <code>key</code>. Returns the
reference to the slice and the local offset within the slice
if it exists, or (NO_SLICE, 0), if there is no matching
key-value pair.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_following">slice_following</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, key: u128): (<a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_following">slice_following</a>&lt;E: store&gt;(
    self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    key: u128,
): (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, u64) {
    <b>if</b> (self.root_id == <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>return</b> (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> { ix: <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a> }, 0)
    };

    <b>let</b> (ix, leaf, off) = self.<a href="big_vector.md#0x0_big_vector_find_leaf">find_leaf</a>(key);
    <b>if</b> (off &gt;= leaf.keys.<a href="big_vector.md#0x0_big_vector_length">length</a>()) {
        (leaf.next(), 0)
    } <b>else</b> {
        (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> { ix }, off)
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_before"></a>

## Function `slice_before`

Find the slice that contains the key-value pair corresponding
to the previous key in <code>self</code>. Returns the reference to the slice
and the local offset within the slice if it exists, or (NO_SLICE, 0),
if there is no matching key-value pair.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_before">slice_before</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, key: u128): (<a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_before">slice_before</a>&lt;E: store&gt;(
    self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    key: u128,
): (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, u64) {
    <b>if</b> (self.root_id == <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>return</b> (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> { ix: <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a> }, 0)
    };

    <b>let</b> (ix, leaf, off) = self.<a href="big_vector.md#0x0_big_vector_find_leaf">find_leaf</a>(key);
    <b>if</b> (off == 0) {
        <b>let</b> prev_ref = leaf.prev();
        <b>if</b> (prev_ref.is_null()) {
            (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> { ix: <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a> }, 0)
        } <b>else</b> {
            <b>let</b> prev_slice = self.<a href="big_vector.md#0x0_big_vector_borrow_slice">borrow_slice</a>(prev_ref);
            (prev_ref, prev_slice.keys.<a href="big_vector.md#0x0_big_vector_length">length</a>() - 1)
        }
    } <b>else</b> {
        (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> { ix }, off - 1)
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_min_slice"></a>

## Function `min_slice`

Find the slice that contains the key-value pair corresponding
to the minimum key in <code>self</code>. Returns the reference to the
slice and the local offset within the slice if it exists, or
(NO_SLICE, 0), if there is no matching key-value pair.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_min_slice">min_slice</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;): (<a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_min_slice">min_slice</a>&lt;E: store&gt;(
    self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
): (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, u64) {
    <b>if</b> (self.root_id == <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>return</b> (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> { ix: <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a> }, 0)
    };

    <b>let</b> (ix, _, off) = self.<a href="big_vector.md#0x0_big_vector_find_min_leaf">find_min_leaf</a>();
    (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> { ix }, off)
}
</code></pre>



</details>

<a name="0x0_big_vector_max_slice"></a>

## Function `max_slice`

Find the slice that contains the key-value pair corresponding
to the maximum key in <code>self</code>. Returns the reference to the
slice and the local offset within the slice if it exists, or
(NO_SLICE, 0), if there is no matching key-value pair.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_max_slice">max_slice</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;): (<a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_max_slice">max_slice</a>&lt;E: store&gt;(
    self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
): (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>, u64) {
    <b>if</b> (self.root_id == <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>return</b> (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> { ix: <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a> }, 0)
    };

    <b>let</b> (ix, _, off) = self.<a href="big_vector.md#0x0_big_vector_find_max_leaf">find_max_leaf</a>();
    (<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> { ix }, off)
}
</code></pre>



</details>

<a name="0x0_big_vector_borrow_slice"></a>

## Function `borrow_slice`

Borrow a slice from this vector.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow_slice">borrow_slice</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, ref: <a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>): &<a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow_slice">borrow_slice</a>&lt;E: store&gt;(
    self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    ref: <a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>,
): &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt; {
    df::borrow(&self.id, ref.ix)
}
</code></pre>



</details>

<a name="0x0_big_vector_borrow_slice_mut"></a>

## Function `borrow_slice_mut`

Borrow a slice from this vector, mutably.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow_slice_mut">borrow_slice_mut</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, ref: <a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>): &<b>mut</b> <a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_borrow_slice_mut">borrow_slice_mut</a>&lt;E: store&gt;(
    self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    ref: <a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>,
): &<b>mut</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt; {
    df::borrow_mut(&<b>mut</b> self.id, ref.ix)
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_is_null"></a>

## Function `slice_is_null`

Returns whether the SliceRef points to an actual slice, or the
<code><a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a></code> sentinel. It is an error to attempt to borrow a
slice from a <code><a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a></code> if it doesn't exist.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_is_null">slice_is_null</a>(self: &<a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_is_null">slice_is_null</a>(self: &<a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a>): bool {
    self.ix == <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_is_leaf"></a>

## Function `slice_is_leaf`

Returns whether the slice is a leaf node or not. Leaf nodes
have as many keys as values.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_is_leaf">slice_is_leaf</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_is_leaf">slice_is_leaf</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt;): bool {
    self.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>() == self.keys.<a href="big_vector.md#0x0_big_vector_length">length</a>()
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_next"></a>

## Function `slice_next`

Reference to the next (neighbouring) slice to this one.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_next">slice_next</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;): <a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_next">slice_next</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt;): <a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> {
    <a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> { ix: self.next }
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_prev"></a>

## Function `slice_prev`

Reference to the previous (neighbouring) slice to this one.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_prev">slice_prev</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;): <a href="big_vector.md#0x0_big_vector_SliceRef">big_vector::SliceRef</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_prev">slice_prev</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt;): <a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> {
    <a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a> { ix: self.prev }
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_length"></a>

## Function `slice_length`

Number of children (values) in this slice.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_length">slice_length</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_length">slice_length</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt;): u64 {
    self.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>()
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_key"></a>

## Function `slice_key`

Access a key from this slice, referenced by its offset, local
to the slice.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_key">slice_key</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;, ix: u64): u128
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_key">slice_key</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt;, ix: u64): u128 {
    self.keys[ix]
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_borrow"></a>

## Function `slice_borrow`

Access a value from this slice, referenced by its offset,
local to the slice.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_borrow">slice_borrow</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;, ix: u64): &E
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_borrow">slice_borrow</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt;, ix: u64): &E {
    &self.vals[ix]
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_borrow_mut"></a>

## Function `slice_borrow_mut`

Access a value from this slice, mutably, referenced by its
offset, local to the slice.


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_borrow_mut">slice_borrow_mut</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;, ix: u64): &<b>mut</b> E
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_borrow_mut">slice_borrow_mut</a>&lt;E: store&gt;(
    self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt;,
    ix: u64,
): &<b>mut</b> E {
    &<b>mut</b> self.vals[ix]
}
</code></pre>



</details>

<a name="0x0_big_vector_alloc"></a>

## Function `alloc`

Store <code>slice</code> as a dynamic field on <code>self</code>, and use its
dynamic field ID to connect it into the doubly linked list
structure at its level. Returns the ID of the slice to be used
in a <code><a href="big_vector.md#0x0_big_vector_SliceRef">SliceRef</a></code>.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_alloc">alloc</a>&lt;E: store, F: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, slice: <a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;F&gt;): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_alloc">alloc</a>&lt;E: store, F: store&gt;(
    self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    slice: <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;F&gt;,
): u64 {
    <b>let</b> prev = slice.prev;
    <b>let</b> next = slice.next;

    self.last_id = self.last_id + 1;
    df::add(&<b>mut</b> self.id, self.last_id, slice);
    <b>let</b> curr = self.last_id;

    <b>if</b> (prev != <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>let</b> prev: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;F&gt; = df::borrow_mut(&<b>mut</b> self.id, prev);
        prev.next = curr;
    };

    <b>if</b> (next != <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>let</b> next: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;F&gt; = df::borrow_mut(&<b>mut</b> self.id, next);
        next.prev = curr;
    };

    curr
}
</code></pre>



</details>

<a name="0x0_big_vector_singleton"></a>

## Function `singleton`

Create a slice representing a leaf node containing a single
key-value pair.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_singleton">singleton</a>&lt;E: store&gt;(key: u128, val: E): <a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_singleton">singleton</a>&lt;E: store&gt;(key: u128, val: E): <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt; {
    <a href="big_vector.md#0x0_big_vector_Slice">Slice</a> {
        prev: <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>,
        next: <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>,
        keys: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[key],
        vals: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[val],
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_branch"></a>

## Function `branch`

Create a slice representing an interior node containing a
single branch.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_branch">branch</a>(key: u128, left: u64, right: u64): <a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;u64&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_branch">branch</a>(key: u128, left: u64, right: u64): <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;u64&gt; {
    <a href="big_vector.md#0x0_big_vector_Slice">Slice</a> {
        prev: <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>,
        next: <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>,
        keys: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[key],
        vals: <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a>[left, right],
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_drop_slice"></a>

## Function `drop_slice`

Recursively <code>drop</code> the nodes under the node at id <code>node</code>.
Assumes that node has depth <code>depth</code> and is owned by <code>id</code>.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_drop_slice">drop_slice</a>&lt;E: drop, store&gt;(id: &<b>mut</b> <a href="dependencies/sui-framework/object.md#0x2_object_UID">object::UID</a>, depth: u8, slice: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_drop_slice">drop_slice</a>&lt;E: store + drop&gt;(id: &<b>mut</b> UID, depth: u8, slice: u64) {
    <b>if</b> (slice == <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>return</b>
    } <b>else</b> <b>if</b> (depth == 0) {
        <b>let</b> _: <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt; = df::remove(id, slice);
    } <b>else</b> {
        <b>let</b> <b>mut</b> slice: <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;u64&gt; = df::remove(id, slice);
        <b>while</b> (!slice.vals.<a href="big_vector.md#0x0_big_vector_is_empty">is_empty</a>()) {
            <a href="big_vector.md#0x0_big_vector_drop_slice">drop_slice</a>&lt;E&gt;(id, depth - 1, slice.vals.pop_back());
        }
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_find_leaf"></a>

## Function `find_leaf`

Find the leaf slice that would contain <code>key</code> if it existed in
<code>self</code>. Returns the slice ref for the leaf, a reference to the
leaf, and the offset in the leaf of the key (if the key were
to exist in <code>self</code> it would appear here).

Assumes <code>self</code> is non-empty.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_find_leaf">find_leaf</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, key: u128): (u64, &<a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_find_leaf">find_leaf</a>&lt;E: store&gt;(
    self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    key: u128,
): (u64, &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt;, u64) {
    <b>let</b> (<b>mut</b> slice_id, <b>mut</b> depth) = (self.root_id, self.depth);

    <b>while</b> (depth &gt; 0) {
        <b>let</b> node: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;u64&gt; = df::borrow(&self.id, slice_id);
        <b>let</b> off = node.bisect_right(key);
        slice_id = node.vals[off];
        depth = depth - 1;
    };

    <b>let</b> leaf: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt; = df::borrow(&self.id, slice_id);
    <b>let</b> off = leaf.bisect_left(key);

    (slice_id, leaf, off)
}
</code></pre>



</details>

<a name="0x0_big_vector_find_min_leaf"></a>

## Function `find_min_leaf`

Find the minimum leaf node that contains the smallest key in the BigVector.
Assumes <code>self</code> is non-empty.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_find_min_leaf">find_min_leaf</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;): (u64, &<a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_find_min_leaf">find_min_leaf</a>&lt;E: store&gt;(
    self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;
): (u64, &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt;, u64) {
    <b>let</b> (<b>mut</b> slice_id, <b>mut</b> depth) = (self.root_id, self.depth);

    // Traverse down <b>to</b> the leftmost leaf node
    <b>while</b> (depth &gt; 0) {
        <b>let</b> slice: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;u64&gt; = df::borrow(&self.id, slice_id);
        slice_id = slice.vals[0];  // Always take the leftmost child
        depth = depth - 1;
    };

    <b>let</b> leaf: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt; = df::borrow(&self.id, slice_id);

    (slice_id, leaf, 0)
}
</code></pre>



</details>

<a name="0x0_big_vector_find_max_leaf"></a>

## Function `find_max_leaf`

Find the maximum leaf node that contains the largest key in the BigVector.
Assumes <code>self</code> is non-empty.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_find_max_leaf">find_max_leaf</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;): (u64, &<a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_find_max_leaf">find_max_leaf</a>&lt;E: store&gt;(
    self: &<a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;
): (u64, &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt;, u64) {
    <b>let</b> (<b>mut</b> slice_id, <b>mut</b> depth) = (self.root_id, self.depth);

    // Traverse down <b>to</b> the rightmost leaf node
    <b>while</b> (depth &gt; 0) {
        <b>let</b> slice: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;u64&gt; = df::borrow(&self.id, slice_id);
        slice_id = slice.vals[slice.keys.<a href="big_vector.md#0x0_big_vector_length">length</a>()]; // Always take the rightmost child
        depth = depth - 1;
    };

    <b>let</b> leaf: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt; = df::borrow(&self.id, slice_id);

    (slice_id, leaf, leaf.keys.<a href="big_vector.md#0x0_big_vector_length">length</a>() - 1)
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_bisect_left"></a>

## Function `slice_bisect_left`

Find the position in <code>slice.keys</code> of <code>key</code> if it exists, or
the minimal position it should be inserted in to maintain
sorted order.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_bisect_left">slice_bisect_left</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;, key: u128): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_bisect_left">slice_bisect_left</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt;, key: u128): u64 {
    <b>let</b> (<b>mut</b> lo, <b>mut</b> hi) = (0, self.keys.<a href="big_vector.md#0x0_big_vector_length">length</a>());

    // Invariant: keys[0, lo) &lt; key &lt;= keys[hi, ..)
    <b>while</b> (lo &lt; hi) {
        <b>let</b> mid = (hi - lo) / 2 + lo;
        <b>if</b> (key &lt;= self.keys[mid]) {
            hi = mid;
        } <b>else</b> {
            lo = mid + 1;
        }
    };

    lo
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_bisect_right"></a>

## Function `slice_bisect_right`

Find the largest index in <code>slice.keys</code> to insert <code>key</code> to
maintain sorted order.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_bisect_right">slice_bisect_right</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">big_vector::Slice</a>&lt;E&gt;, key: u128): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_bisect_right">slice_bisect_right</a>&lt;E: store&gt;(self: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt;, key: u128): u64 {
    <b>let</b> (<b>mut</b> lo, <b>mut</b> hi) = (0, self.keys.<a href="big_vector.md#0x0_big_vector_length">length</a>());

    // Invariant: keys[0, lo) &lt;= key &lt; keys[hi, ..)
    <b>while</b> (lo &lt; hi) {
        <b>let</b> mid = (hi - lo) / 2 + lo;
        <b>if</b> (key &lt; self.keys[mid]) {
            hi = mid;
        } <b>else</b> {
            lo = mid + 1;
        }
    };

    lo
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_insert"></a>

## Function `slice_insert`

Insert <code>key: val</code> into the slice at ID <code>slice_id</code> with depth
<code>depth</code>.

Returns (0, NO_SLICE), if the insertion could be completed
without splitting, otherwise returns the key that was split
upon, and the ID of the new Slice which always sits next to
(and not previously to) <code>slice_id</code>.

Upon returning, sibling pointers are fixed up, but children
pointers will not be.

Aborts if <code>key</code> is already found within the slice.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_insert">slice_insert</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, slice_id: u64, depth: u8, key: u128, val: E): (u128, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_insert">slice_insert</a>&lt;E: store&gt;(
    self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    slice_id: u64,
    depth: u8,
    key: u128,
    val: E,
): (u128, u64) {
    <b>if</b> (depth == 0) {
        self.<a href="big_vector.md#0x0_big_vector_leaf_insert">leaf_insert</a>(slice_id, key, val)
    } <b>else</b> {
        self.<a href="big_vector.md#0x0_big_vector_node_insert">node_insert</a>(slice_id, depth - 1, key, val)
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_leaf_insert"></a>

## Function `leaf_insert`

Like <code>slice_insert</code> but you know that <code>slice_id</code> points to a leaf node.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_leaf_insert">leaf_insert</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, slice_id: u64, key: u128, val: E): (u128, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_leaf_insert">leaf_insert</a>&lt;E: store&gt;(
    self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    slice_id: u64,
    key: u128,
    val: E,
): (u128, u64) {
    <b>let</b> leaf: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt; = df::borrow_mut(&<b>mut</b> self.id, slice_id);
    <b>let</b> off = leaf.bisect_left(key);

    <b>if</b> (off &lt; leaf.keys.<a href="big_vector.md#0x0_big_vector_length">length</a>() &&
        key == leaf.keys[off]) {
        <b>abort</b> <a href="big_vector.md#0x0_big_vector_EExists">EExists</a>
    };

    // If there is enough space in the current leaf, no need
    // <b>to</b> split.
    <b>if</b> (leaf.keys.<a href="big_vector.md#0x0_big_vector_length">length</a>() &lt; self.max_slice_size) {
        leaf.keys.<a href="big_vector.md#0x0_big_vector_insert">insert</a>(key, off);
        leaf.vals.<a href="big_vector.md#0x0_big_vector_insert">insert</a>(val, off);
        <b>return</b> (0, <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>)
    };

    // Split off half the current leaf <b>to</b> be the new `next` leaf.
    <b>let</b> split_at = leaf.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>() / 2;
    <b>let</b> <b>mut</b> next = <a href="big_vector.md#0x0_big_vector_Slice">Slice</a> {
        prev: slice_id,
        next: leaf.next,
        keys: leaf.keys.pop_until(split_at),
        vals: leaf.vals.pop_until(split_at),
    };

    // Insert the key-value pair into the correct side of the
    // split -- the first element in the new slice is the pivot.
    //
    // SAFETY: The next slice is guaranteed <b>to</b> be non-empty,
    // because we round down the size of the original slice when
    // splitting, so <b>as</b> long <b>as</b> `leaf.keys` had at least one
    // element at the start of the call, then `next.keys` will
    // have at least one element at this point.
    <b>let</b> pivot = next.keys[0];
    <b>if</b> (key &lt; pivot) {
        leaf.keys.<a href="big_vector.md#0x0_big_vector_insert">insert</a>(key, off);
        leaf.vals.<a href="big_vector.md#0x0_big_vector_insert">insert</a>(val, off);
    } <b>else</b> {
        next.keys.<a href="big_vector.md#0x0_big_vector_insert">insert</a>(key, off - split_at);
        next.vals.<a href="big_vector.md#0x0_big_vector_insert">insert</a>(val, off - split_at);
    };

    (pivot, self.<a href="big_vector.md#0x0_big_vector_alloc">alloc</a>(next))
}
</code></pre>



</details>

<a name="0x0_big_vector_node_insert"></a>

## Function `node_insert`

Like <code>slice_insert</code> but you know that <code>slice_id</code> points to an
interior node, and <code>depth</code> is the depth of its children, not
itself.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_node_insert">node_insert</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, slice_id: u64, depth: u8, key: u128, val: E): (u128, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_node_insert">node_insert</a>&lt;E: store&gt;(
    self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    slice_id: u64,
    depth: u8,
    key: u128,
    val: E,
): (u128, u64) {
    <b>let</b> node: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;u64&gt; = df::borrow_mut(&<b>mut</b> self.id, slice_id);
    <b>let</b> off = node.bisect_right(key);

    <b>let</b> child = node.vals[off];
    <b>let</b> (key, val) = self.<a href="big_vector.md#0x0_big_vector_slice_insert">slice_insert</a>(child, depth, key, val);

    // The recursive call didn't introduce an extra slice, so no
    // work needed <b>to</b> accommodate it.
    <b>if</b> (val == <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>return</b> (0, <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>)
    };

    // Re-borrow the current node, after the recursive call.
    <b>let</b> node: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;u64&gt; = df::borrow_mut(&<b>mut</b> self.id, slice_id);

    // The extra slice can be accommodated in the current node
    // without splitting it.
    <b>if</b> (node.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>() &lt; self.max_fan_out) {
        node.keys.<a href="big_vector.md#0x0_big_vector_insert">insert</a>(key, off);
        node.vals.<a href="big_vector.md#0x0_big_vector_insert">insert</a>(val, off + 1);
        <b>return</b> (0, <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>)
    };

    <b>let</b> split_at = node.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>() / 2;
    <b>let</b> <b>mut</b> next = <a href="big_vector.md#0x0_big_vector_Slice">Slice</a> {
        prev: slice_id,
        next: node.next,
        keys: node.keys.pop_until(split_at),
        vals: node.vals.pop_until(split_at),
    };

    // SAFETY: `node` is guaranteed <b>to</b> have a key <b>to</b> pop after
    // having `next` split off from it, because:
    //
    //    split_at
    //  = <a href="big_vector.md#0x0_big_vector_length">length</a>(node.vals) / 2
    // &gt;= self.max_fan_out  / 2
    // &gt;= <a href="big_vector.md#0x0_big_vector_MIN_FAN_OUT">MIN_FAN_OUT</a> / 2
    // &gt;= 4 / 2
    //  = 2
    //
    // Meaning there will be at least 2 elements left in the key
    // <a href="dependencies/move-stdlib/vector.md#0x1_vector">vector</a> after the split -- one <b>to</b> pop here, and then one <b>to</b>
    // leave behind <b>to</b> ensure the remaining node is at least
    // binary (not vestigial).
    <b>let</b> pivot = node.keys.pop_back();
    <b>if</b> (key &lt; pivot) {
        node.keys.<a href="big_vector.md#0x0_big_vector_insert">insert</a>(key, off);
        node.vals.<a href="big_vector.md#0x0_big_vector_insert">insert</a>(val, off + 1);
    } <b>else</b> {
        next.keys.<a href="big_vector.md#0x0_big_vector_insert">insert</a>(key, off - split_at);
        next.vals.<a href="big_vector.md#0x0_big_vector_insert">insert</a>(val, off - split_at + 1);
    };

    (pivot, self.<a href="big_vector.md#0x0_big_vector_alloc">alloc</a>(next))
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_remove"></a>

## Function `slice_remove`

Remove <code>key</code> from the slice at ID <code>slice_id</code> with depth
<code>depth</code>, in <code>self</code>.

<code>prev_id</code> and <code>next_id</code> are the IDs of slices either side of
<code>slice_id</code> that share the same parent, to be used for
redistribution and merging.

Aborts if <code>key</code> does not exist within the slice.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_remove">slice_remove</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, prev_id: u64, prev_key: u128, slice_id: u64, next_key: u128, next_id: u64, depth: u8, key: u128): (E, u8, u128)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_remove">slice_remove</a>&lt;E: store&gt;(
    self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    prev_id: u64,
    prev_key: u128,
    slice_id: u64,
    next_key: u128,
    next_id: u64,
    depth: u8,
    key: u128,
): (E, /* RM_FIX */ u8, /* key */ u128) {
    <b>if</b> (depth == 0) {
        self.<a href="big_vector.md#0x0_big_vector_leaf_remove">leaf_remove</a>(
            prev_id,
            prev_key,
            slice_id,
            next_key,
            next_id,
            key,
        )
    } <b>else</b> {
        self.<a href="big_vector.md#0x0_big_vector_node_remove">node_remove</a>(
            prev_id,
            prev_key,
            slice_id,
            next_key,
            next_id,
            depth - 1,
            key,
        )
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_leaf_remove"></a>

## Function `leaf_remove`

Like <code>slice_remove</code> but you know that <code>slice_id</code> points to a
leaf.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_leaf_remove">leaf_remove</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, prev_id: u64, prev_key: u128, slice_id: u64, next_key: u128, next_id: u64, key: u128): (E, u8, u128)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_leaf_remove">leaf_remove</a>&lt;E: store&gt;(
    self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    prev_id: u64,
    prev_key: u128,
    slice_id: u64,
    next_key: u128,
    next_id: u64,
    key: u128,
): (E, /* RM_FIX */ u8, /* key */ u128) {
    <b>let</b> leaf: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt; = df::borrow_mut(&<b>mut</b> self.id, slice_id);
    <b>let</b> off = leaf.bisect_left(key);

    <b>if</b> (off &gt;= leaf.keys.<a href="big_vector.md#0x0_big_vector_length">length</a>()) {
        <b>abort</b> <a href="big_vector.md#0x0_big_vector_ENotFound">ENotFound</a>
    };

    <b>if</b> (key != leaf.keys[off]) {
        <b>abort</b> <a href="big_vector.md#0x0_big_vector_ENotFound">ENotFound</a>
    };

    leaf.keys.<a href="big_vector.md#0x0_big_vector_remove">remove</a>(off);
    <b>let</b> val = leaf.vals.<a href="big_vector.md#0x0_big_vector_remove">remove</a>(off);

    <b>let</b> remaining = leaf.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>();
    <b>let</b> min_slice_size = self.max_slice_size / 2;
    <b>if</b> (remaining &gt;= min_slice_size) {
        <b>return</b> (val, <a href="big_vector.md#0x0_big_vector_RM_FIX_NOTHING">RM_FIX_NOTHING</a>, 0)
    };

    // Try redistribution <b>with</b> a neighbour
    <b>if</b> (prev_id != <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>let</b> prev: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt; = df::borrow(&self.id, prev_id);
        <b>if</b> (prev.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>() &gt; min_slice_size) {
            <b>return</b> (
                val,
                <a href="big_vector.md#0x0_big_vector_RM_FIX_STEAL_L">RM_FIX_STEAL_L</a>,
                self.<a href="big_vector.md#0x0_big_vector_slice_redistribute">slice_redistribute</a>&lt;E, E&gt;(
                    prev_id,
                    prev_key,
                    slice_id,
                ),
            )
        }
    };

    <b>if</b> (next_id != <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>let</b> next: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;E&gt; = df::borrow(&self.id, next_id);
        <b>if</b> (next.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>() &gt; min_slice_size) {
            <b>return</b> (
                val,
                <a href="big_vector.md#0x0_big_vector_RM_FIX_STEAL_R">RM_FIX_STEAL_R</a>,
                self.<a href="big_vector.md#0x0_big_vector_slice_redistribute">slice_redistribute</a>&lt;E, E&gt;(
                    slice_id,
                    next_key,
                    next_id,
                ),
            )
        }
    };

    // Try merging <b>with</b> a neighbour
    <b>if</b> (prev_id != <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        self.<a href="big_vector.md#0x0_big_vector_slice_merge">slice_merge</a>&lt;E, E&gt;(prev_id, prev_key, slice_id);
        <b>return</b> (val, <a href="big_vector.md#0x0_big_vector_RM_FIX_MERGE_L">RM_FIX_MERGE_L</a>, 0)
    };

    <b>if</b> (next_id != <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        self.<a href="big_vector.md#0x0_big_vector_slice_merge">slice_merge</a>&lt;E, E&gt;(slice_id, next_key, next_id);
        <b>return</b> (val, <a href="big_vector.md#0x0_big_vector_RM_FIX_MERGE_R">RM_FIX_MERGE_R</a>, 0)
    };

    // Neither neighbour exists, must be the root -- check whether
    // it's empty.
    <b>if</b> (remaining == 0) {
        (val, <a href="big_vector.md#0x0_big_vector_RM_FIX_EMPTY">RM_FIX_EMPTY</a>, 0)
    } <b>else</b> {
        (val, <a href="big_vector.md#0x0_big_vector_RM_FIX_NOTHING">RM_FIX_NOTHING</a>, 0)
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_node_remove"></a>

## Function `node_remove`

Like <code>slice_remove</code> but you know that <code>slice_id</code> points to an
interior node, and <code>depth</code> refers to the depth of its child
nodes.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_node_remove">node_remove</a>&lt;E: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, prev_id: u64, prev_key: u128, slice_id: u64, next_key: u128, next_id: u64, depth: u8, key: u128): (E, u8, u128)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_node_remove">node_remove</a>&lt;E: store&gt;(
    self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    prev_id: u64,
    prev_key: u128,
    slice_id: u64,
    next_key: u128,
    next_id: u64,
    depth: u8,
    key: u128
): (E, /* RM_FIX */ u8, /* key */ u128) {
    <b>let</b> node: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;u64&gt; = df::borrow(&self.id, slice_id);
    <b>let</b> off = node.bisect_right(key);

    <b>let</b> child_id = node.vals[off];

    <b>let</b> (child_prev_id, child_prev_key) = <b>if</b> (off == 0) {
        (<a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>, 0)
    } <b>else</b> (
        node.vals[off - 1],
        node.keys[off - 1],
    );

    <b>let</b> (child_next_id, child_next_key) = <b>if</b> (off == node.keys.<a href="big_vector.md#0x0_big_vector_length">length</a>()) {
        (<a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>, 0)
    } <b>else</b> (
        node.vals[off + 1],
        node.keys[off],
    );

    <b>let</b> (val, rm_fix, pivot) = self.<a href="big_vector.md#0x0_big_vector_slice_remove">slice_remove</a>(
        child_prev_id,
        child_prev_key,
        child_id,
        child_next_key,
        child_next_id,
        depth,
        key,
    );

    // Re-borrow node mutably after recursive call, <b>to</b> perform
    // fix-ups.
    <b>let</b> node: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;u64&gt; = df::borrow_mut(&<b>mut</b> self.id, slice_id);

    <b>if</b> (rm_fix == <a href="big_vector.md#0x0_big_vector_RM_FIX_NOTHING">RM_FIX_NOTHING</a>) {
        <b>return</b> (val, <a href="big_vector.md#0x0_big_vector_RM_FIX_NOTHING">RM_FIX_NOTHING</a>, 0)
    } <b>else</b> <b>if</b> (rm_fix == <a href="big_vector.md#0x0_big_vector_RM_FIX_STEAL_L">RM_FIX_STEAL_L</a>) {
        *(&<b>mut</b> node.keys[off - 1]) = pivot;
        <b>return</b> (val, <a href="big_vector.md#0x0_big_vector_RM_FIX_NOTHING">RM_FIX_NOTHING</a>, 0)
    } <b>else</b> <b>if</b> (rm_fix == <a href="big_vector.md#0x0_big_vector_RM_FIX_STEAL_R">RM_FIX_STEAL_R</a>) {
        *(&<b>mut</b> node.keys[off]) = pivot;
        <b>return</b> (val, <a href="big_vector.md#0x0_big_vector_RM_FIX_NOTHING">RM_FIX_NOTHING</a>, 0)
    } <b>else</b> <b>if</b> (rm_fix == <a href="big_vector.md#0x0_big_vector_RM_FIX_MERGE_L">RM_FIX_MERGE_L</a>) {
        node.keys.<a href="big_vector.md#0x0_big_vector_remove">remove</a>(off - 1);
        node.vals.<a href="big_vector.md#0x0_big_vector_remove">remove</a>(off);
    } <b>else</b> <b>if</b> (rm_fix == <a href="big_vector.md#0x0_big_vector_RM_FIX_MERGE_R">RM_FIX_MERGE_R</a>) {
        node.keys.<a href="big_vector.md#0x0_big_vector_remove">remove</a>(off);
        node.vals.<a href="big_vector.md#0x0_big_vector_remove">remove</a>(off + 1);
    } <b>else</b> {
        <b>abort</b> <a href="big_vector.md#0x0_big_vector_EBadRemove">EBadRemove</a>
    };

    <b>let</b> remaining = node.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>();
    <b>let</b> min_fan_out = self.max_fan_out / 2;
    <b>if</b> (remaining &gt;= min_fan_out) {
        <b>return</b> (val, <a href="big_vector.md#0x0_big_vector_RM_FIX_NOTHING">RM_FIX_NOTHING</a>, 0)
    };

    // Try redistribution <b>with</b> a neighbour
    <b>if</b> (prev_id != <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>let</b> prev: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;u64&gt; = df::borrow(&self.id, prev_id);
        <b>if</b> (prev.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>() &gt; min_fan_out) {
            <b>return</b> (
                val,
                <a href="big_vector.md#0x0_big_vector_RM_FIX_STEAL_L">RM_FIX_STEAL_L</a>,
                self.<a href="big_vector.md#0x0_big_vector_slice_redistribute">slice_redistribute</a>&lt;E, u64&gt;(
                    prev_id,
                    prev_key,
                    slice_id,
                ),
            )
        }
    };

    <b>if</b> (next_id != <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>let</b> next: &<a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;u64&gt; = df::borrow(&self.id, next_id);
        <b>if</b> (next.vals.<a href="big_vector.md#0x0_big_vector_length">length</a>() &gt; min_fan_out) {
            <b>return</b> (
                val,
                <a href="big_vector.md#0x0_big_vector_RM_FIX_STEAL_R">RM_FIX_STEAL_R</a>,
                self.<a href="big_vector.md#0x0_big_vector_slice_redistribute">slice_redistribute</a>&lt;E, u64&gt;(
                    slice_id,
                    next_key,
                    next_id,
                )
            )
        }
    };

    // Try merging <b>with</b> a neighbour
    <b>if</b> (prev_id != <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        self.<a href="big_vector.md#0x0_big_vector_slice_merge">slice_merge</a>&lt;E, u64&gt;(prev_id, prev_key, slice_id);
        <b>return</b> (val, <a href="big_vector.md#0x0_big_vector_RM_FIX_MERGE_L">RM_FIX_MERGE_L</a>, 0)
    };

    <b>if</b> (next_id != <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        self.<a href="big_vector.md#0x0_big_vector_slice_merge">slice_merge</a>&lt;E, u64&gt;(slice_id, next_key, next_id);
        <b>return</b> (val, <a href="big_vector.md#0x0_big_vector_RM_FIX_MERGE_R">RM_FIX_MERGE_R</a>, 0)
    };

    // Neither neighbour exists, must be the root. As we are
    // dealing <b>with</b> an interior node, it is considered "empty"
    // when it <b>has</b> only one child (which can replace it), and it
    // is an error for it <b>to</b> be completely empty.
    <b>if</b> (remaining == 0) {
        <b>abort</b> <a href="big_vector.md#0x0_big_vector_EBadRemove">EBadRemove</a>
    } <b>else</b> <b>if</b> (remaining == 1) {
        (val, <a href="big_vector.md#0x0_big_vector_RM_FIX_EMPTY">RM_FIX_EMPTY</a>, 0)
    } <b>else</b> {
        (val, <a href="big_vector.md#0x0_big_vector_RM_FIX_NOTHING">RM_FIX_NOTHING</a>, 0)
    }
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_redistribute"></a>

## Function `slice_redistribute`

Redistribute the elements in <code>left_id</code> and <code>right_id</code>
separated by <code>pivot</code>, evenly between each other. Returns the
new pivot element between the two slices.

Aborts if left and right are not adjacent slices.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_redistribute">slice_redistribute</a>&lt;E: store, F: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, left_id: u64, pivot: u128, right_id: u64): u128
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_redistribute">slice_redistribute</a>&lt;E: store, F: store&gt;(
    self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    left_id: u64,
    pivot: u128,
    right_id: u64,
): u128 {
    // Remove the slices from `self` <b>to</b> make it easier <b>to</b>
    // manipulate both of them simultaneously.
    <b>let</b> left: <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;F&gt; = df::remove(&<b>mut</b> self.id, left_id);
    <b>let</b> right: <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;F&gt; = df::remove(&<b>mut</b> self.id, right_id);

    <b>assert</b>!(left.next == right_id, <a href="big_vector.md#0x0_big_vector_ENotAdjacent">ENotAdjacent</a>);
    <b>assert</b>!(right.prev == left_id, <a href="big_vector.md#0x0_big_vector_ENotAdjacent">ENotAdjacent</a>);

    <b>let</b> is_leaf = left.is_leaf();
    <b>let</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a> {
        prev: lprev,
        next: lnext,
        keys: <b>mut</b> lkeys,
        vals: <b>mut</b> lvals,
    } = left;

    <b>let</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a> {
        prev: rprev,
        next: rnext,
        keys: rkeys,
        vals: rvals,
    } = right;

    <b>let</b> old_l_len = lvals.<a href="big_vector.md#0x0_big_vector_length">length</a>();
    <b>let</b> old_r_len = rvals.<a href="big_vector.md#0x0_big_vector_length">length</a>();
    <b>let</b> total_len = old_l_len + old_r_len;
    <b>let</b> new_l_len = total_len / 2;
    <b>let</b> new_r_len = total_len - new_l_len;

    // Detect whether the redistribution is left-<b>to</b>-right or right-<b>to</b>-left.
    <b>let</b> left_to_right = <b>if</b> (new_l_len &lt; old_l_len) {
        <b>true</b>
    } <b>else</b> <b>if</b> (new_r_len &lt; old_r_len) {
        <b>false</b>
    } <b>else</b> {
        <b>abort</b> <a href="big_vector.md#0x0_big_vector_EBadRedistribution">EBadRedistribution</a>
    };

    // Redistribute values
    <b>let</b> (lvals, rvals)  = <b>if</b> (left_to_right) {
        <b>let</b> <b>mut</b> mvals = lvals.pop_until(new_l_len);
        mvals.append(rvals);
        (lvals, mvals)
    } <b>else</b> {
        <b>let</b> <b>mut</b> mvals = rvals;
        <b>let</b> rvals = mvals.pop_n(new_r_len);
        lvals.append(mvals);
        (lvals, rvals)
    };

    // Redistribute keys and <b>move</b> pivot.
    //
    // The pivot moves from the left side <b>to</b> the right side of the
    // middle section depending on whether the keys are from left
    // <b>to</b> right or vice versa.
    //
    // The pivot also changes from inclusive <b>to</b> exclusive based on
    // whether the slices in question are leaves or not.
    //
    // When handling interior nodes, the previous pivot needs <b>to</b>
    // be incorporated during this process.
    <b>let</b> (lkeys, pivot, rkeys) = <b>if</b> (is_leaf && left_to_right) {
        <b>let</b> <b>mut</b> mkeys = lkeys.pop_until(new_l_len);
        <b>let</b> pivot = mkeys[0];
        mkeys.append(rkeys);
        (lkeys, pivot, mkeys)
    } <b>else</b> <b>if</b> (is_leaf && !left_to_right) {
        <b>let</b> <b>mut</b> mkeys = rkeys;
        <b>let</b> rkeys = mkeys.pop_n(new_r_len);
        <b>let</b> pivot = rkeys[0];
        lkeys.append(mkeys);
        (lkeys, pivot, rkeys)
    } <b>else</b> <b>if</b> (!is_leaf && left_to_right) {
        // [left, new-pivot, mid] <b>old</b>-pivot [right]
        // ... becomes ...
        // [left] new-pivot [mid, <b>old</b>-pivot, right]
        <b>let</b> <b>mut</b> mkeys = lkeys.pop_until(new_l_len);
        mkeys.push_back(pivot);
        mkeys.append(rkeys);
        <b>let</b> pivot = lkeys.pop_back();
        (lkeys, pivot, mkeys)
    } <b>else</b> /* !is_leaf && !left_to_right */ {
        // [left] <b>old</b>-pivot [mid, new-pivot, right]
        // ... becomes ...
        // [left, <b>old</b>-pivot, mid] new-pivot [right]
        lkeys.push_back(pivot);
        <b>let</b> <b>mut</b> mkeys = rkeys;
        <b>let</b> rkeys = mkeys.pop_n(new_r_len - 1);
        <b>let</b> pivot = mkeys.pop_back();
        lkeys.append(mkeys);
        (lkeys, pivot, rkeys)
    };

    // Add the slices back <b>to</b> self.
    df::add(&<b>mut</b> self.id, left_id, <a href="big_vector.md#0x0_big_vector_Slice">Slice</a> {
        prev: lprev,
        next: lnext,
        keys: lkeys,
        vals: lvals,
    });

    df::add(&<b>mut</b> self.id, right_id, <a href="big_vector.md#0x0_big_vector_Slice">Slice</a> {
        prev: rprev,
        next: rnext,
        keys: rkeys,
        vals: rvals,
    });

    pivot
}
</code></pre>



</details>

<a name="0x0_big_vector_slice_merge"></a>

## Function `slice_merge`

Merge the <code>right_id</code> slice into <code>left_id</code> (represented by
their IDs). Assumes that <code>left_id</code> and <code>right_id</code> are adjacent
slices, separated by <code>pivot</code>, and aborts if this is not the
case.

Upon success, <code>left_id</code> contains all the elements of both
slices, and the <code>right_id</code> slice has been removed from the
vector.


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_merge">slice_merge</a>&lt;E: store, F: store&gt;(self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">big_vector::BigVector</a>&lt;E&gt;, left_id: u64, pivot: u128, right_id: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="big_vector.md#0x0_big_vector_slice_merge">slice_merge</a>&lt;E: store, F: store&gt;(
    self: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_BigVector">BigVector</a>&lt;E&gt;,
    left_id: u64,
    pivot: u128,
    right_id: u64,
) {
    <b>let</b> right: <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;F&gt; = df::remove(&<b>mut</b> self.id, right_id);
    <b>let</b> left: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;F&gt; = df::borrow_mut(&<b>mut</b> self.id, left_id);

    <b>assert</b>!(left.next == right_id, <a href="big_vector.md#0x0_big_vector_ENotAdjacent">ENotAdjacent</a>);
    <b>assert</b>!(right.prev == left_id, <a href="big_vector.md#0x0_big_vector_ENotAdjacent">ENotAdjacent</a>);

    <b>if</b> (!left.is_leaf()) {
        left.keys.push_back(pivot);
    };

    <b>let</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a> { prev: _, next, keys, vals } = right;
    left.keys.append(keys);
    left.vals.append(vals);

    left.next = next;
    <b>if</b> (next != <a href="big_vector.md#0x0_big_vector_NO_SLICE">NO_SLICE</a>) {
        <b>let</b> next: &<b>mut</b> <a href="big_vector.md#0x0_big_vector_Slice">Slice</a>&lt;F&gt; = df::borrow_mut(&<b>mut</b> self.id, next);
        next.prev = left_id;
    }
}
</code></pre>



</details>
