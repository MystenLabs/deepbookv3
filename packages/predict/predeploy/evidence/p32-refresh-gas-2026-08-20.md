# P-32 inventory-grid refresh cost, 2026-08-20

**Item:** P-32

**Revision:** `8277c28cf29ae7160470ba25d140e28b5163fd3f` plus the uncommitted frozen-grid implementation, the two pricing constant-factor fixes, and the harness grid lane that records this run.

**Instrument:** two independent `capacity-tree` campaigns with `KEEPER_INVENTORY_GRID=1`, retained instances `capacity-tree-aug20-154939-53024` and `capacity-tree-aug20-154712-46999`, each `--timeout 1500`, real-data oracle stream, prod cadence set (1m/5m/1h, window 3), keeper budget 15,000,000,000 MIST.

## Question

P-32 asked for the computation cost of one `refresh_inventory_grid` at a full book, measured against the 5,000M-unit per-transaction computation cap, on the assumption that the refresh's distinct dynamic-field footprint is bounded by the payout-tree node count the NAV flush already meets. Neither `initialize_inventory_grid` nor `refresh_inventory_grid` had a TypeScript caller, so the run also required a boundary generator and PTB builders.

## Method

The keeper cuts a grid for every market at least two hours from expiry on the tick it is rolled, then re-cuts the same markets each tick, tracing the computation cost of each call. The trader is unchanged `capacity-tree`: it locks the farthest market and fills its payout tree with distinct strikes. Refresh cost is joined to tree size per market by timestamp, because no on-chain read reports a tree's node count. Every mint in this run used a distinct strike, so tree nodes and orders are the same number.

Boundaries are the 1%-to-99% quantiles of the settlement distribution, produced by log-space bisection on the float SVI port in `harness/ts/pricer.ts`. A float generator is adequate for a check the contract performs in fixed point: scoring float-derived boundaries with the contract-faithful mirror in `simulations/python_replay.py` puts the worst bucket-mass error at 141 to 5,472 of 1e9 across every expiry in a captured snapshot, against a tolerance of 100,000.

## Result: computation is not the constraint

- `initialize_inventory_grid` on an empty book costs 11,200,000 MIST, or 0.2% of the 5,000,000,000 MIST cap. It only verifies the 101-boundary probability ladder, so it does not grow with the book.
- Refresh computation against tree size: 333,200,000 at 96 nodes, 521,100,000 at 204, 1,150,000,000 at 636, 1,415,000,000 at 864, 1,533,000,000 at 952, and 1,561,000,000 at 972. The largest success is 31% of the computation cap.
- The least-squares fit is 1,384,090 MIST per node on a 226,491,152 MIST base, which would reach the computation cap at about 3,448 nodes.

The second campaign reproduces this on a separate localnet: the same 11,200,000 initialize, 353,400,000 at 108 nodes rising to 1,532,000,000 at 956, a fitted 1,348,057 per node on a 260,934,893 base, and a projected crossing at about 3,515 nodes. Both runs peak at 31% of the cap, and the two slopes agree within 3%.

That crossing is never reached in either run. From roughly 1,000 nodes the refresh fails instead — 48 times in the first campaign at a recorded computation cost of 1,588,000,000 MIST, 32% of the cap, so the transaction died with about two thirds of its computation budget unused.

## Result: the failure is the object-cache ceiling, and it coincides with the tree's own cap

The failure surfaces as `0x2::dynamic_field::borrow_child_object` with abort code 0. Attribution needs care, because that same framework location carries two very different causes: the object-runtime cached-objects limit of 1,000 dynamic-field children per transaction, and a genuine missing dynamic field. The dry-run `executionErrorSource` that normally separates them is empty for every artifact in this run (see Limits), so the attribution rests on three other pieces of evidence.

- A missing field is ruled out for this code path. `refresh_reads_every_boundary_of_a_many_node_payout_tree` runs the same refresh over a 200-node tree and returns the analytically known tail — every one of the five tail buckets equals the whole book, because each order is `(lower, +inf]` and every lower tick sits below the fifth-highest boundary. The same test at 500 nodes exhausts the Move test VM's own step budget rather than aborting. `sui move test` does not enforce the object-cache limit, so a structural read error would have appeared at any size and did not.
- The 22 keeper flush failures in this same run have the identical shape and the same empty error source, and the flush at a large tree is the established C-1 object-cache wall recorded in `c1-object-cache-flush-2026-07-07.md`.
- The refresh's distinct-child count is dominated by `walk_linear` loading every node of the tree, so its footprint reaches 1,000 children at almost exactly the observed failure point.
- Both campaigns fail the same way at the same size, 70 and 73 occurrences, so this is a reproducible property of the call rather than one localnet's state.

The consequence is structural rather than a matter of tuning. `constants::max_payout_tree_nodes` is 1,000, so the cache ceiling and the largest tree the contract will accept are the same number, and the refresh additionally loads the pricer's oracle children and the transaction's base children. A market at its permitted maximum therefore cannot be refreshed in a single transaction, and reducing computation per node does not move a ceiling that counts distinct children loaded rather than work done per child.

## Result: off-chain boundaries are not operable against a live pricer

`inventory_grid:2` (`EInvalidBucketMass`) aborted 23 cuts in the first campaign and 16 in the second, on markets whose grid the same generator had already cut successfully.

The cause is spot movement between the snapshot the generator reads and the oracle observation the contract prices against when the transaction executes. Scoring a fixed boundary ladder at a drifted spot on the captured 2.91-hour surface, the first bucket leaves tolerance at about 0.25 basis points of drift, roughly $1.81 on a $72,584 forward, and 46 of 100 buckets are outside tolerance at one basis point. The budget is that small because an equal-mass bucket is narrow: at that horizon the central 1% bucket spans $13.73, or 1.89 basis points of the forward. Spot moved several basis points per second in this run, so most cuts missed.

Clock skew is second-order by comparison. Holding spot fixed and moving only the pricing timestamp, the far markets stay inside tolerance at ten seconds of skew (39,022 worst error) while 1m-cadence markets fail at two seconds — which is why the grid lane is restricted to markets at least two hours out, and why near-expiry cadences cannot be gridded from off-chain boundaries at this tolerance at all.

## Limits

The dry-run `executionErrorSource` was absent from all 100 saved artifacts in the first run, including the flush failures whose cause is already established. The gRPC dry-run instead returns a structured `status.error` with `cleverError: "[Undefined]"`, and `runtime.ts` reads only `executionErrorSource`, so the plain-English VM cause that the harness rules identify as the thing that makes these aborts legible was unavailable. That is a harness regression, not a finding about the grid, and it is why the object-cache attribution above is corroborated rather than read directly. It also drove both campaigns to FAIL with `VACUOUS: declared wall 'cached objects limit' never reached` — the wall was reached in both runs and simply could not be evidenced, because the analyzer only admits `capacity-tree`'s declared wall when an artifact proves it.

Roughly 40% of cuts in each run were deferred by localnet RPC contention rather than by the contract (`provided version doesn't match`, validator rejections), an artifact of a keeper re-cutting every eligible market every tick. Those are excluded from the cost curve and do not bear on the ceiling.

This measures one refresh shape: 100 buckets, one market per cut, tree nodes as the only growing child, and a keeper re-cutting every tick, which is denser than any cadence a production keeper would run. It does not measure the per-trade quote and apply cost at a nonzero rate, which is a separate and much smaller path, and it does not measure a chunked refresh. The reported per-node slope is fitted over six attributed samples spanning 96 to 972 nodes and is used only to show that the computation cap is not what binds. The `inventory_grid:2` aborts are a property of supplying boundaries from off-chain against a live pricer and say nothing about the charge formula.
