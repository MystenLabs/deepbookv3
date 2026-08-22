# P-32 inline cell-array refresh and mint cost, 2026-08-21

**Item:** P-32

**Revision:** `8277c28cf29ae7160470ba25d140e28b5163fd3f` plus the uncommitted frozen-grid implementation, ratio boundaries, and the inline `inventory_cells` mirror.

**Instrument:** one `capacity-tree` campaign with `KEEPER_INVENTORY_GRID=1`, retained instance `capacity-tree-aug21-004952-59098`, `--timeout 600`, real-data oracle stream, prod cadence set (1m/5m/1h, window 3).

## Question

[`p32-refresh-gas-2026-08-20.md`](p32-refresh-gas-2026-08-20.md) showed a tree-walking refresh aborting at ~1,000 nodes against the object-runtime cached-objects limit, with computation at 31% of the 5,000M-unit cap and unused. [`p32-cell-array-sizing-2026-08-20.md`](p32-cell-array-sizing-2026-08-20.md) sized a 2,048-cell inline mirror as a substitute that reads zero children. This run asks whether that mirror, now in source, stays inside the computation cap on initialize, mint, and refresh — including at the permitted 1,000-node book — and whether per-trade writes of the 16 KB array are grossly expensive.

## Method

The keeper initializes a far-market grid on the roll tick and re-cuts it every subsequent tick, tracing `compGas` on `gridInit` and `gridRefresh`. The trader is unchanged `capacity-tree`: it locks the farthest advertised market and fills distinct strikes up to `max_payout_tree_nodes`. The configured inventory-impact rate remains zero, so quotes skip the capital walk and each mint still commits the order into the cell mirror. Refresh cost is joined to tree size by timestamp on the single locked market.

## Result: refresh at a full book is 13% of the computation cap and does not touch the object-cache ceiling

The campaign analyzer joined 30 successful refreshes. `gridInit` on an empty book cost 40,400,000 MIST (1% of the 5,000M-unit cap). Refresh computation rose with book size as the centering walk priced one digital per distinct snapped boundary, from 226,600,000 at 96 orders (4.5%) to a peak of 625,900,000 at 1,000 orders (13%). The fit is ~390,000 per order plus a 228M base and would only reach the cap near 12,000 orders, well past `max_payout_tree_nodes`. The object-runtime cached-objects limit that stopped the tree-walking refresh at this node count did not appear on this path: the refresh loads no payout-tree children.

Two cuts were deferred: one `inventory_grid:2` (`EInvalidBucketMass`) and one version-mismatch RPC. The mass-check abort is the verified-snapshot tolerance, not computation or object-cache; a later tick on the same market succeeded. The flush still aborted `dynamic_field:0` seven times at the C-1 ceiling, which is the tree walk this refresh no longer shares.

## Result: per-trade writes of the 16 KB mirror are not grossly expensive

Twelve-order mint batches averaged 460,194,936 MIST computation (9.2% of the cap, 38.3M per mint, 79 samples). At the 1,000-node ceiling the strategy steps down to two-order batches at 6,399,230 (0.13% of the cap, 3.2M per mint, 26 samples). No mint aborted on computation, object size, or object-cache. The rate is zero in this run, so these numbers are the apply-into-cells cost plus ordinary mint work, not the nonzero-rate quote walk.

## Reading

The cell-array refresh removes the object-cache blocker by construction and leaves a comfortable computation margin at the largest book the tree is allowed to reach. The remaining refresh abort class on this run is the mass check, already bounded by the ratio-boundary budget in [`p32-ratio-boundaries-2026-08-20.md`](p32-ratio-boundaries-2026-08-20.md). Per-trade write cost is not the gate it was feared to be at the default zero rate. Nonzero-rate quote cost (two full-lattice capital walks per quote) is unmeasured here because the configured rate is still zero.

## Limits

One campaign, one market, rate zero. Refresh-versus-node-count is timestamp-joined rather than read on-chain. Object size of the market after the 16 KB vector is not separately metered; it is bounded only by the fact that those transactions committed. The campaign analyzer exited fail: seven `dynamic_field:0` flush aborts plus a vacuous "declared wall never reached" because `capacity-tree` still names C-1's object-cache ceiling and gRPC left `executionErrorSource` empty, so the framework tag is not accepted as proof. That verdict is C-1's, not a refresh or mint failure.
