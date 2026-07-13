# Full-Pool Flush Object-Cache Ceiling — 2026-07-07

**Item:** C-1 · **Instrument:** `tree-node-sweep` / `tree-node-cumulative` / `batch-max-markets` (localnet harness) · **Date:** 2026-07-07

Status: measured finding that corrects C-1's binding wall. The pool-total flush is
bounded by the Sui object-runtime cached-objects limit (1,000 dynamic-field child
objects per transaction), NOT the 5M computation cap the 2026-07-01 model assumed.
The compute figures in `c1-price-memo-2026-07-01.md` stand for the single market;
this record supersedes the "flush is computation-bound" conclusion for the pool total.

## The wall

The flush is one atomic PTB (`generate_lifecycle_proof` → `start_pool_valuation` →
`value_expiry` per active market → `finish_flush`). Each `value_expiry` walks its
market's payout tree (`walk_linear` loads every `Table<tick,PayoutNode>` node) and
liquidation book (`correction_value` scans `Table<pageid,OrderIdPage>` pages). Every
loaded Table entry is a dynamic-field child object, and the Sui object runtime caches
loaded children **for the whole transaction** — the cache does not reset between PTB
commands. The cap is `object_runtime_max_num_cached_objects = 1,000` (a protocol
constant, taken as network-invariant). On the 1,001st distinct child the flush aborts
`MEMORY_LIMIT_EXCEEDED` (sub status 5) inside `0x2::dynamic_field::borrow_child_object`
— a framework-level error whose plain-English cause is in the dry-run's
`executionErrorSource`: `Object runtime cached objects limit (1000 entries) reached`.

The driver is distinct payout-tree nodes. A node exists per distinct strike tick
(`insert_range` creates one only for a new boundary; pos-inf is not stored), so
`node_count` = distinct ticks, independent of order count — the tree aggregates all
orders at a boundary into one `PayoutTerms`. Liquidation-book pages
(`ceil(leveraged_orders / 64)`) are a minor second contributor; 1× orders create
zero pages (`insert_order` is a no-op for unleveraged orders).

## Method

Three localnet campaigns, all `SIM_GAS_BUDGET=50000000000`, real-data oracle stream,
prod cadence set (1m/5m/1h, window 3). The correctness signal is the dry-run
`executionErrorSource` on each saved failed-flush artifact (now surfaced live by the
keeper and by the `analyze` bug oracle — the change that made this legible).

## batch-max-markets — the repro (`ts/strategies/batchMaxMarkets.ts`)

Pool-total fill across the live set, allocation caps raised so capital does not bound
the book first. The keeper flush succeeded 4× (compute climbing 160M → 844M → 1,243M →
1,936M MIST) then aborted 6× with the cached-objects limit at ~2.1–2.7e9 MIST —
**42–53% of the 5M compute cap**. Decisive detail: a 9-market flush *succeeded*
(1,936M) while a later 8-market flush *failed* — the wall is total dynamic-field
count (dominated by the growing 1h market's distinct ticks), not market count and not
compute.

## tree-node-sweep — causation (`ts/strategies/treeNodeSweep.ts`)

One market, 1× orders (zero leverage pages), distinct strikes swept wide so tree nodes
are the only child that grows. Isolates node count as the single variable.

| locked-market node count | keeper flush |
| --- | --- |
| 708 | success (588M MIST compute) |
| 982 | abort — `cached objects limit (1000 entries)` |

Six independent flush failures; `mintCapAborts` (the tree's own `EMaxPayoutTreeNodes`
at 1,000, `strike_payout_tree:1`) were separate and later — so the flush abort is the
object-cache limit, not the node cap. With zero pages present, the abort is assigned
to tree-node count alone.

## tree-node-cumulative — scoping (`ts/strategies/treeNodeCumulative.ts`)

Two 1× markets filled to ~600 nodes each; neither approaches 1,000 alone. The keeper
flush aborted at **586 + 586 = 1,172** combined (abort at PTB command 4, after several
`value_expiry` commands accumulated). A per-command reset would have valued each 586-node
market fine; it did not. **The cache is cumulative across the flush PTB** — so C-1's wall
is the sum of tree nodes across all active markets, not the max of any single one.

## Why a unit test cannot reproduce this

A `sui move test` loaded 1,100 dynamic-field children in one test transaction without
aborting: the object-runtime cached-objects limit is a full-node execution-layer check
that the Move test VM does not enforce. Reproduction is localnet-only; the deterministic
record is the saved failed-flush artifacts of these three runs.

## Capacity law

`sum_over_active_markets(distinct_ticks + ceil(leveraged_orders / 64) + base_children)
< 1,000 dynamic-field children per flush PTB`, dominated by distinct strike ticks.
Fix direction lives on open-items C-1; no Move change landed with this record.
