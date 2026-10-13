# Predict contract-parity simulation

This directory is the deterministic contract-parity engine. It executes the same scenario through a published localnet package and an independent Python model, then compares canonical economic records.

Every trade in the scenario is queued in the order-flow companion, `deepbook_predict_orders`, as described in the [delayed-execution concept page](../docs/concepts/delayed-execution.md). The localnet publishes the `predict_math` library, Predict, and the companion, whose publish shares the one `OrderDesk` with the launch policy. Setup allowlists the companion's `OrderFlow` witness with `protocol_config::set_order_flow`, adds the simulation address as a flush operator before the bootstrap flush, and creates the market's `MarketQueue` with `queue::create_and_share` right after the market.

Long-run economics, charts, and encoding experiments are research concerns and intentionally live outside this public repository.

## Run

From `packages/predict`:

```bash
python3 -m harness parity \
  --source simulations/data/synthetic_oracle_fixture.csv \
  --seed 0 \
  --max-rows 20
```

The checked-in synthetic fixture makes the complete 20-row parity case reproducible without private data. `--source` may instead point to an oracle snapshot containing the required source columns; additional named dataset columns are ignored. A row limit below 20 is rejected by action-coverage validation because it would skip current contract flows.

The external benchmark worker calls:

```bash
python3 -m harness benchmark \
  --source /path/to/scenario_dataset.csv \
  --results-output /path/to/results.json
```

The task passes the generated scenario to the TypeScript executor as an explicit argument, honors `SIM_MAX_ROWS`, runs the independent replay and parity comparison, retains the canonical instance artifacts, and copies `results.json` to the requested delivery path.

## Outputs

Every run retains:

- `scenario.csv` — the exact generated scenario executed by both engines
- `run-manifest.json` — source revision, dirty flag, source/config/scenario hashes, seed, row limit, command, chain id, and package ids
- `local_trace.json` — transaction receipts, gas, and events; a step that spans several transactions (oracle refresh, enqueue, commit and resolve, or the queue's `settle_step` calls and `cleanup`) aggregates every leg's gas, events, and object changes into one logical trace step, and its last transaction supplies the digest and effects. A queued trade step records its order's τ as `pricingTimestampMs`, because the fill is priced at that tick.
- `local_data.json` — canonical localnet economic records
- `python_data.json` — canonical Python-model records
- `state.json` — published simulation object ids

Failed transaction builds or executions additionally retain `failed_transactions/` with transaction-build, execution, and dry-run diagnostics.

The manifest status is atomically changed from `running` to `complete` or `failed`, so interrupted and failed retained runs remain machine-readable.

## Flow

```text
ignored oracle snapshot CSV
  → seeded scenario generator
  → shared initialized-localnet lifecycle
  → TypeScript localnet executor (gRPC)
  → actual local Pyth + Block Scholes verification/ingest path
  → queued trades: enqueue, then commit a locally signed Lazer price for τ and resolve
  → independent Python replay
  → parity projection and first-difference check
```

Each scenario row maps to these contract calls:

| Row | Calls |
| --- | --- |
| `mint` | Oracle refresh, then the companion's `queue::enqueue_exact_quantity` with `max_cost` equal to the quantity. A row with `commit_spot` then waits for τ, verifies a Lazer update for τ on the order's channel that carries that spot, and calls `queue::commit`, which takes the updates by value, and `queue::resolve` in one transaction. A row without `commit_spot` leaves the order waiting. |
| `redeem_open` | Oracle refresh, then `queue::enqueue_redeem_open` on the Open record holding the row's position, then the same commit and resolve. |
| `request_supply`, `request_withdraw`, `flush` | The LP queue and the staged flush, as before delayed execution. |
| `rebalance_expiry_cash` | Rebalances a live market toward required cash plus the waiting orders' cash need, or sweeps a settled one. |
| `settle` | Predict's `try_settle` with the exact expiry observation. It settles from the oracle alone, so the waiting order keeps waiting. |
| `settle_payout` | The queue's settlement walk, `queue::settle_step` once per transaction until `payout_progress` reports it complete: the first call refunds every waiting order at its deadline, the next pays every Open record, zero for a loser. Then `queue::cleanup` deletes every finished record. |

The executor fails the run if a queued order is not committed at its own τ, or if resolve reaches it at or past its deadline, because the replay prices every committed order at τ. It also fails on `OpenRecordPayoutSkipped`, a payout the market could not make, which the scenario never creates.

A queued fill never enters the account, so the scenario has no settled redemption: `redeem_settled` pays only positions that immediate mints left in accounts before the cutover, and a fresh publish has none.

The Block Scholes local fixture derives series identities through the published upstream `bs_sid` package, signs the canonical BCS batch, binds it to the published verifier package, normalizes the recoverable signature, calls the actual `bs_oracle` verifier, and passes the gated batch into Propbook ingest in the same transaction. It tests the trust boundary without claiming to consume the provider’s official stream.

## Configuration

`data/scenario_config.json` is the complete, versioned protocol and generator configuration. Missing, unknown, malformed, and unsupported fields fail before execution. Scenario generation is byte-deterministic for a fixed source, configuration, and seed. Changing any input is visible in the retained manifest hashes.

The generator writes fixed-point integers as decimal text and emits explicit mint, early-sell (`redeem_open`), LP request, flush, rebalance, settlement, and settlement-payout actions. The TypeScript executor records emitted transitions plus direct chain-state snapshots after every action, including Predict's waiting cash need (`order_flow_state`) and the queue's pending counts and payout progress. The Python replay independently models the same economics.

Mint rows use `strike` and `is_up` for above/below. An `is_up=true` row may also supply `higher_strike` to bound its upper side; both finite strikes must align to the configured tick grid and the upper strike must exceed the lower. `commit_spot` is the spot signed for the order's τ: for an ordinary fill it is the source's next observation, so the fill re-anchors the order's Block Scholes forward on a slightly moved spot. A mint may set `max_probability`, its entry-probability cap at τ. The generated round trip at steps 8–9 mints and closes a finite range, exercising separate boundary fees.

The scenario covers each queued outcome:

- Steps 1, 2, 8, 11, and 12 fill at τ. Step 3 sells part of the first position, which leaves the remainder Open in the sell's own record. Step 9 sells the whole round-trip position.
- Step 13 is placed near the money with a `max_probability` cap above its placement probability, then committed at a higher spot, so it misses the cap at τ and is refunded with reason 1. The order fee stays in market cash.
- Step 14 is never committed. The settlement walk refunds it with reason 5 and returns the order fee.
- Steps 15–17 settle the market, refund the waiting order and pay the winning and losing Open records through the queue's walk, clean up every record, and sweep the settled market's cash back to the pool.

The replay models the 0.02 USDC order fee, kept on refund reasons 1 and 2 and returned on every other reason, and the escrowed budget, of which a fill returns the unused part. It prices a committed order from its own volatility snapshot: the Block Scholes forward re-anchored on the committed spot, and the SVI rolled from its source time to τ, with the trading fee charged at τ. It applies the resolve checks in the contract's order: entry admission, the probability cap, the maximum-payout bound, the cost cap, then market cash. The completeness check requires the exact action sequence and the mint roles above. The parity comparison also requires each mint to show its role's outcome, because a fill that turned into a refund on both sides would still match: the ordinary mints fill, the capped mint is refunded at τ with the order fee kept, and the uncommitted mint only enqueues. It further requires a refund that returned the order fee, a payout walk that paid both a winner and a loser, and one cleanup that deleted the records the replay expects.

## Verification

```bash
python3 -m unittest discover -s simulations/tests -p 'test_*.py' -v
npm run build
npm test
```

The external Predict Gas Benchmark check runs a bounded end-to-end parity case because pure unit tests cannot validate package publication, transaction composition, event decoding, or the on-chain verifier boundary. Its `results.json` counts a mint as successful only when it filled. A mint refunded at τ or left waiting is listed under `rejectedMints`. A queued trade's gas and wall time cover the refresh, the enqueue, and the commit and resolve, including the wait for τ. The `settle_payout` row's gas covers both `settle_step` calls and the `cleanup`, whose storage rebate for the deleted records usually makes its net gas negative. The `settle` row's wall time includes the wait for expiry.
