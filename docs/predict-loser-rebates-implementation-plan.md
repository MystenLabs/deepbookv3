# Predict Loser Rebates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add expiry-local loser rebates funded by live trading fees, remove expiry-level insurance and revenue fee reserves, and move all non-rebate fees into the main pool at compaction.

**Architecture:** Each expiry accumulates all trade fees in one unified `fee_balance`. The expiry also tracks raw rebate-eligible fee basis as a second measure inside `StrikeMatrix`, while each `PredictManager` tracks the user's per-position fee basis. At settlement or compaction, the market uses the aggregate fee-basis measure to reserve only the remaining loser rebate liability and transfers all other fees to `PoolVault.idle_balance`.

**Tech Stack:** Sui Move 2024, Predict Move package under `packages/predict`, existing `StrikeMatrix`, `ExpiryMarket`, `PredictManager`, `ProtocolConfig`, and Predict simulations.

**Testing Scope:** Per explicit user instruction, this implementation plan does not add unit tests. It may delete obsolete tests that reference removed modules. Verification relies on Move build, existing test suites if still present, simulation smoke checks when simulation code changes, symbol audits, and code review.

---

## Design

### User-Facing Behavior

- Users still pay one dynamic trade fee quoted by the existing pricing path.
- Mint fees attach rebate eligibility to the minted position.
- Live redeem fees enter the expiry fee pool but do not create rebate eligibility.
- Live redeemed quantity loses rebate eligibility pro rata.
- After settlement, losing position redemptions receive a rebate equal to `raw_fee_basis * settlement_loss_rebate_rate`, rounded down.
- Rebate rounding dust is pool-owned.
- Pro-rata fee-basis removal during live redeem rounds up, so repeated tiny redemptions cannot leave excess rebate basis attached to dust positions.

### Fee Custody

`ExpiryMarket` owns one unified DUSDC fee balance:

```move
fee_balance: Balance<DUSDC>
```

This balance is intentionally dumb. It does not split insurance, revenue, LP fees, or rebates during live trading. It only stores fee cash.

At compaction:

```text
remaining_rebate_liability = settlement_loss_rebate_rate * remaining_losing_fee_basis
fee_surplus = fee_balance - remaining_rebate_liability
```

The expiry keeps `remaining_rebate_liability` in `fee_balance`. The `fee_surplus` is transferred directly into `PoolVault.idle_balance`.

### Rebate Accounting

Use raw fee basis, not pre-multiplied rebate credit.

```text
rebate = raw_fee_basis * settlement_loss_rebate_rate
```

The rate is snapshotted into each expiry at creation:

```move
settlement_loss_rebate_rate: u64
```

The admin setter updates the template used by future expiries. It must not mutate existing expiry rebate rates.

### Aggregate And User Ledgers

There are two ledgers by design:

- `PredictManager`: per-user, per-range quantity and raw rebate-eligible fee basis.
- `StrikeMatrix`: expiry-wide aggregate quantity and raw rebate-eligible fee basis.

Both ledgers are updated in the same trade or redeem transaction.

The manager ledger lets a user redeem the right rebate. The matrix ledger lets expiry valuation and compaction compute aggregate rebate liability without iterating over all managers.

### StrikeMatrix Measures

Extend `StrikeMatrix` to track two interval measures over the same range book:

- position quantity, used for payout liability and option value
- raw rebate fee basis, used for rebate liability and fee NAV

The fee-basis measure needs these package APIs:

```move
public(package) fun total_fee_basis(matrix: &StrikeMatrix): u64
public(package) fun fee_basis_live_value(matrix: &StrikeMatrix, curve: &vector<CurvePoint>): u64
public(package) fun fee_basis_settled_value(matrix: &StrikeMatrix, settlement: u64): u64
public(package) fun min_fee_basis_settled_value(matrix: &StrikeMatrix): u64
```

`fee_basis_live_value` is not option payout value. It is the probability-weighted amount of attached fee basis expected to end on winning positions. This lets expiry valuation reserve expected loser rebates:

```text
expected_winning_fee_basis = matrix.fee_basis_live_value(curve)
expected_losing_fee_basis = total_fee_basis - expected_winning_fee_basis
expected_rebate_liability = expected_losing_fee_basis * settlement_loss_rebate_rate
fee_nav = fee_balance - expected_rebate_liability
```

`min_fee_basis_settled_value` gives a worst-case reserve:

```text
max_rebate_liability =
  (total_fee_basis - min_fee_basis_settled_value) * settlement_loss_rebate_rate
```

This is analogous to `max_payout`, but it is not the same number. Existing `max_payout` uses position quantity. Fee basis can be distributed differently from quantity.

### Expiry Valuation

Live expiry NAV includes fee NAV:

```text
expiry_nav =
  lp_cash_balance
  - option_value
  + fee_balance
  - expected_rebate_liability
```

For settled-but-uncompacted expiries, replace expected rebate liability with exact remaining rebate liability:

```text
winning_fee_basis = matrix.fee_basis_settled_value(settlement)
losing_fee_basis = matrix.total_fee_basis() - winning_fee_basis
rebate_liability = losing_fee_basis * settlement_loss_rebate_rate
```

### Settled Redeem Before Compaction

No separate settlement-finalization step is required.

A settled redeem before compaction should:

- remove position quantity from `PredictManager`
- remove raw fee basis from `PredictManager`
- remove the same quantity and fee basis from `StrikeMatrix`
- pay normal settled payout from `lp_cash_balance`
- pay rebate from `fee_balance` only if the redeemed range loses

Compaction can run after settled redemptions over the remaining open positions and remaining fee basis.

### Compaction

Compaction leaves only remaining liabilities in the expiry:

- payout liability in `lp_cash_balance`
- loser rebate liability in `fee_balance`

All surplus LP cash and all non-rebate fee cash are returned as pool-owned DUSDC and joined into `PoolVault.idle_balance`.

The expiry no longer stores protocol fee or insurance fee balances.

### Admin Config

Replace fee-share config with one template:

```move
settlement_loss_rebate_rate: u64
```

Bounds:

```text
0 <= settlement_loss_rebate_rate <= FLOAT_SCALING
```

Default:

```text
0
```

Defaulting to zero preserves a conservative launch mode where no loser rebates are paid until governance opts in.

---

## File Structure

### Modify

- `packages/predict/sources/config/config_constants.move`
  - Add settlement loss rebate rate default, min, max, and assertion.
- `packages/predict/sources/config/fee_config.move`
  - Replace fee-share fields with `settlement_loss_rebate_rate`.
- `packages/predict/sources/protocol_config.move`
  - Add `set_template_settlement_loss_rebate_rate`.
- `packages/predict/sources/registry.move`
  - Add template settlement loss rebate rate admin entrypoint.
- `packages/predict/sources/helper/strike_matrix.move`
  - Add raw fee-basis measure alongside quantity.
- `packages/predict/sources/predict_manager.move`
  - Store per-position raw rebate fee basis and expose package helpers for pro-rata removal.
- `packages/predict/sources/expiry_market.move`
  - Replace `FeeReserve` with unified `fee_balance`, snapshot `settlement_loss_rebate_rate`, attach mint fees to positions, remove fee basis on live and settled redeem, include fee NAV in valuation, and return non-rebate fees at compaction.
- `packages/predict/sources/plp.move`
  - Remove protocol and insurance fee balances and route compaction fee surplus into `idle_balance`.
- `packages/predict/simulations/src/runtime.ts`
  - Update Move calls and event parsing if affected by entrypoint or event changes.
- `packages/predict/simulations/src/shared.ts`
  - Update fee event summaries if affected.
- `packages/predict/simulations/src/sim.ts`
  - Update simulation accounting if it assumes LP/protocol/insurance fee splits.

### Delete

- `packages/predict/sources/accounting/fee_reserve.move`
- `packages/predict/tests/accounting/fee_reserve_tests.move`

### Do Not Create

- No new files under `packages/predict/tests/**`.
- No new unit-test modules for this implementation.

---

## Implementation Plan

### Task 1: Replace Fee Share Config With Loser Rebate Rate

**Files:**
- Modify: `packages/predict/sources/config/config_constants.move`
- Modify: `packages/predict/sources/config/fee_config.move`
- Modify: `packages/predict/sources/protocol_config.move`
- Modify: `packages/predict/sources/registry.move`
- Delete: `packages/predict/tests/accounting/fee_reserve_tests.move`

- [ ] **Step 1: Update config constants**

In `packages/predict/sources/config/config_constants.move`, add:

```move
const EInvalidSettlementLossRebateRate: u64 = 22;

public(package) macro fun default_settlement_loss_rebate_rate(): u64 { 0 }
public(package) macro fun min_settlement_loss_rebate_rate(): u64 { 0 }
public(package) macro fun max_settlement_loss_rebate_rate(): u64 {
    deepbook_predict::constants::float_scaling!()
}

public(package) fun assert_settlement_loss_rebate_rate(value: u64) {
    assert!(
        value >= min_settlement_loss_rebate_rate!() && value <= max_settlement_loss_rebate_rate!(),
        EInvalidSettlementLossRebateRate,
    );
}
```

Keep existing fee-share constants for this additive phase. They are removed later when `FeeReserve` is replaced.

- [ ] **Step 2: Update `fee_config.move`**

Replace the three fee-share fields with:

```move
/// Fee policy template snapshotted into future expiry markets.
public struct FeeConfig has store {
    /// Fraction of losing positions' raw fee basis paid back after settlement.
    settlement_loss_rebate_rate: u64,
}
```

Expose:

```move
public(package) fun settlement_loss_rebate_rate(config: &FeeConfig): u64 {
    config.settlement_loss_rebate_rate
}

public(package) fun new(): FeeConfig {
    FeeConfig {
        settlement_loss_rebate_rate: config_constants::default_settlement_loss_rebate_rate!(),
    }
}

public(package) fun set_settlement_loss_rebate_rate(config: &mut FeeConfig, value: u64) {
    config_constants::assert_settlement_loss_rebate_rate(value);
    config.settlement_loss_rebate_rate = value;
}
```

Update `destroy_for_testing` to destructure only `settlement_loss_rebate_rate`.

- [ ] **Step 3: Update protocol and registry setters**

In `protocol_config.move`, replace `set_fee_shares` with:

```move
public(package) fun set_template_settlement_loss_rebate_rate(config: &mut ProtocolConfig, value: u64) {
    config.assert_not_valuation_in_progress();
    config.fee_config.set_settlement_loss_rebate_rate(value);
}
```

In `registry.move`, replace `set_fee_shares` with:

```move
/// Set the settlement loss rebate rate template used by future expiry markets.
public fun set_template_settlement_loss_rebate_rate(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.set_template_settlement_loss_rebate_rate(value);
}
```

- [ ] **Step 4: Remove obsolete fee reserve test file**

Delete `packages/predict/tests/accounting/fee_reserve_tests.move` because its target module will be removed.

- [ ] **Step 5: Build-check config changes**

Run:

```bash
sui move build --path packages/predict
```

Expected: build may still fail from references to old fee reserve symbols until later tasks are complete. Confirm there are no syntax errors in the files changed by this task before proceeding.

- [ ] **Step 6: Commit**

```bash
git add packages/predict/sources/config/config_constants.move packages/predict/sources/config/fee_config.move packages/predict/sources/protocol_config.move packages/predict/sources/registry.move packages/predict/tests/accounting/fee_reserve_tests.move
git commit -m "predict: add loser rebate fee config"
```

### Task 2: Add Fee-Basis Accounting To StrikeMatrix

**Files:**
- Modify: `packages/predict/sources/helper/strike_matrix.move`
- Modify: `packages/predict/sources/expiry_market.move`

- [ ] **Step 1: Extend StrikeNode**

Add fee-basis fields alongside quantity fields:

```move
fee_start: u64,
fee_end: u64,
agg_fee_start: u64,
agg_feek_start: u64,
agg_fee_end: u64,
agg_feek_end: u64,
```

Initialize them to zero in `empty_page`.

- [ ] **Step 2: Extend PageSummary**

Add fee-basis summary fields:

```move
total_fee_start: u64,
total_fee_end: u64,
best_fee_prefix_start: u64,
best_fee_prefix_end: u64,
worst_fee_prefix_start: u64,
worst_fee_prefix_end: u64,
```

`best_fee_prefix_*` is the maximum possible winning fee basis. `worst_fee_prefix_*` is the minimum possible winning fee basis.

- [ ] **Step 3: Update range mutation APIs**

Change `insert_range` and `remove_range` to accept fee basis:

```move
public(package) fun insert_range(
    matrix: &mut StrikeMatrix,
    lower: u64,
    higher: u64,
    qty: u64,
    fee_basis: u64,
)

public(package) fun remove_range(
    matrix: &mut StrikeMatrix,
    lower: u64,
    higher: u64,
    qty: u64,
    fee_basis: u64,
)
```

Quantity must remain nonzero. Fee basis may be zero.

- [ ] **Step 4: Add fee-basis read APIs**

Add:

```move
public(package) fun total_fee_basis(matrix: &StrikeMatrix): u64
public(package) fun fee_basis_live_value(matrix: &StrikeMatrix, curve: &vector<CurvePoint>): u64
public(package) fun fee_basis_settled_value(matrix: &StrikeMatrix, settlement: u64): u64
public(package) fun min_fee_basis_settled_value(matrix: &StrikeMatrix): u64
```

Use names that make receiver syntax clear at call sites:

```move
let expected_winning_fee_basis = strike_matrix.fee_basis_live_value(&curve);
```

- [ ] **Step 5: Generalize update and evaluation internals**

Keep quantity behavior unchanged. Add fee-basis equivalents of:

- boundary delta application
- segment accumulation
- live evaluation
- settled evaluation
- page summary recomputation
- page summary merge

Use pair comparisons for both maximum and minimum prefix scores. The maximum comparator mirrors existing `prefix_is_better`. The minimum comparator should choose the lower signed value:

```move
fun prefix_is_worse(
    candidate_start: u64,
    candidate_end: u64,
    worst_start: u64,
    worst_end: u64,
): bool {
    candidate_start + worst_end <= candidate_end + worst_start
}
```

- [ ] **Step 6: Update existing callers temporarily**

Update current `expiry_market.move` calls to compile while Task 4 is not complete:

```move
insert_range(lower, higher, quantity, 0)
remove_range(lower, higher, quantity, 0)
```

Task 4 replaces the zeros with real fee basis.

- [ ] **Step 7: Build-check matrix changes**

Run:

```bash
sui move build --path packages/predict
```

Expected: build may still fail from old fee reserve references until Task 4. Confirm all `StrikeMatrix` type errors are resolved before proceeding.

- [ ] **Step 8: Commit**

```bash
git add packages/predict/sources/helper/strike_matrix.move packages/predict/sources/expiry_market.move
git commit -m "predict: track rebate fee basis in strike matrix"
```

### Task 3: Track Per-Position Fee Basis In PredictManager

**Files:**
- Modify: `packages/predict/sources/predict_manager.move`
- Modify: `packages/predict/sources/expiry_market.move`

- [ ] **Step 1: Add position value struct**

Replace `positions: Table<RangeKey, u64>` with:

```move
public struct Position has store {
    quantity: u64,
    rebate_fee_basis: u64,
}
```

Keep public `position(manager, key): u64` returning only quantity for compatibility.

Add:

```move
public fun rebate_fee_basis(self: &PredictManager, key: RangeKey): u64
```

- [ ] **Step 2: Update position increase helper**

Change `increase_position`:

```move
public(package) fun increase_position(
    self: &mut PredictManager,
    key: RangeKey,
    quantity: u64,
    rebate_fee_basis: u64,
)
```

It should accumulate both quantity and rebate fee basis.

- [ ] **Step 3: Add fee-basis removal preview**

Add:

```move
public(package) fun fee_basis_to_remove(
    self: &PredictManager,
    key: RangeKey,
    quantity: u64,
): u64
```

Rules:

- assert the position exists and has enough quantity
- full removal returns all remaining rebate fee basis
- partial removal uses `deepbook_predict::math::mul_div_round_up(rebate_fee_basis, quantity, position_quantity)`

- [ ] **Step 4: Update position decrease helper**

Change `decrease_position`:

```move
public(package) fun decrease_position(
    self: &mut PredictManager,
    key: RangeKey,
    quantity: u64,
    rebate_fee_basis: u64,
)
```

It should assert `rebate_fee_basis == self.fee_basis_to_remove(key, quantity)` before mutating. Remove the table entry when both remaining quantity and remaining rebate basis are zero.

- [ ] **Step 5: Update current call sites temporarily**

Update current `expiry_market.move` calls:

```move
manager.increase_position(key, quantity, 0);
let removed_fee_basis = manager.fee_basis_to_remove(key, quantity);
manager.decrease_position(key, quantity, removed_fee_basis);
```

Task 4 wires real mint fees into the increase path.

- [ ] **Step 6: Build-check manager changes**

Run:

```bash
sui move build --path packages/predict
```

Expected: build may still fail from old fee reserve references until Task 4. Confirm all `PredictManager` type errors are resolved before proceeding.

- [ ] **Step 7: Commit**

```bash
git add packages/predict/sources/predict_manager.move packages/predict/sources/expiry_market.move
git commit -m "predict: track position rebate fee basis"
```

### Task 4: Replace FeeReserve With Unified Expiry Fee Balance

**Files:**
- Delete: `packages/predict/sources/accounting/fee_reserve.move`
- Modify: `packages/predict/sources/expiry_market.move`
- Modify: `packages/predict/sources/plp.move`

- [ ] **Step 1: Update ExpiryMarket state**

Replace:

```move
fee_reserve: FeeReserve,
```

with:

```move
/// Unified fee cash used for loser rebates until compaction releases surplus.
fee_balance: Balance<DUSDC>,
/// Rebate rate snapshotted from fee config at expiry creation.
settlement_loss_rebate_rate: u64,
/// Remaining loser rebate liability after compaction.
compacted_rebate_liability: u64,
```

Add package getters needed by valuation, compaction, and simulation code. Avoid public getters unless a PTB or external composition path needs them.

- [ ] **Step 2: Update creation**

In `create_and_share`, initialize:

```move
fee_balance: balance::zero(),
settlement_loss_rebate_rate: config.fee_config().settlement_loss_rebate_rate(),
compacted_rebate_liability: 0,
```

Remove `fee_reserve` imports.

- [ ] **Step 3: Update mint**

After quote:

```text
principal_amount = fair_price * quantity
fee_amount = fee_rate * quantity
```

Mutation order:

1. Insert range with `quantity` and `fee_amount`.
2. Increase manager position with `quantity` and `fee_amount`.
3. Withdraw `principal_amount + fee_amount`.
4. Split `fee_amount` into `fee_balance`.
5. Join principal into `lp_cash_balance`.

Update `FeeAccrued` to:

```move
public struct FeeAccrued has copy, drop, store {
    expiry_market_id: ID,
    total_fee: u64,
    rebate_fee_basis: u64,
}
```

For mint, `rebate_fee_basis = total_fee`.

- [ ] **Step 4: Update live redeem**

Before removing matrix state:

```move
let removed_fee_basis = manager.fee_basis_to_remove(key, quantity);
```

Then:

1. Remove range with `quantity` and `removed_fee_basis`.
2. Quote live redeem using post-removal liability.
3. Decrease manager position with the same `removed_fee_basis`.
4. Split live redeem fee into `fee_balance`.
5. Deposit payout net of fee into manager.

Emit `FeeAccrued` with `rebate_fee_basis = 0`.

- [ ] **Step 5: Update settled redeem**

Settled redeem:

1. Compute payout.
2. Compute `removed_fee_basis`.
3. Remove manager and matrix state.
4. Pay payout from `lp_cash_balance`.
5. If the range loses, pay `math::mul(removed_fee_basis, settlement_loss_rebate_rate)` from `fee_balance`.
6. Deposit payout plus rebate into manager.

Use a private helper for the binary settlement outcome:

```move
fun range_loses(settlement: u64, key: &RangeKey): bool {
    !(settlement > key.lower_strike() && settlement <= key.higher_strike())
}
```

- [ ] **Step 6: Update compacted redeem**

Compacted redeem:

1. Use `compacted_settlement` to decide whether range loses.
2. Compute and remove manager fee basis.
3. Reduce `compacted_liability` by payout.
4. If losing, reduce `compacted_rebate_liability` by rebate.
5. Pay payout from `lp_cash_balance` and rebate from `fee_balance`.

Assert `compacted_rebate_liability >= rebate` before subtracting.

- [ ] **Step 7: Update valuation**

Add fee NAV to `read_valuation`.

Live:

```text
expected_winning_fee_basis = strike_matrix.fee_basis_live_value(curve)
expected_losing_fee_basis = strike_matrix.total_fee_basis() - expected_winning_fee_basis
expected_rebate_liability = expected_losing_fee_basis * settlement_loss_rebate_rate
fee_nav = fee_balance - expected_rebate_liability
```

Settled:

```text
winning_fee_basis = strike_matrix.fee_basis_settled_value(settlement)
losing_fee_basis = strike_matrix.total_fee_basis() - winning_fee_basis
rebate_liability = losing_fee_basis * settlement_loss_rebate_rate
fee_nav = fee_balance - rebate_liability
```

Compacted:

```text
fee_nav = fee_balance - compacted_rebate_liability
```

Assert `fee_balance >= rebate_liability` before subtracting.

- [ ] **Step 8: Update compaction**

Compute:

```text
settled_liability = strike_matrix.settled_value(settlement)
winning_fee_basis = strike_matrix.fee_basis_settled_value(settlement)
losing_fee_basis = strike_matrix.total_fee_basis() - winning_fee_basis
rebate_liability = losing_fee_basis * settlement_loss_rebate_rate
fee_surplus = fee_balance - rebate_liability
lp_surplus = lp_cash_balance - settled_liability
```

After consuming dense matrix state:

```text
lp_cash_balance == settled_liability
fee_balance == rebate_liability
compacted_liability = settled_liability
compacted_rebate_liability = rebate_liability
```

Return one combined `Balance<DUSDC>` containing `lp_surplus + fee_surplus`.

- [ ] **Step 9: Update PoolVault**

Remove:

```move
protocol_fee_balance
insurance_fee_balance
```

Remove their public getters.

Change `compact_expiry_market` so returned compaction cash joins only:

```move
vault.idle_balance.join(returned_pool_cash);
```

- [ ] **Step 10: Delete FeeReserve module**

Delete `packages/predict/sources/accounting/fee_reserve.move`.

- [ ] **Step 11: Build-check expiry changes**

Run:

```bash
sui move build --path packages/predict
```

Expected: PASS or a small remaining set of references handled in Task 5. Do not proceed with unresolved accounting or type errors in `expiry_market.move`, `plp.move`, or `predict_manager.move`.

- [ ] **Step 12: Commit**

```bash
git add packages/predict/sources/expiry_market.move packages/predict/sources/plp.move packages/predict/sources/accounting/fee_reserve.move
git commit -m "predict: settle loser rebates from unified fee pool"
```

### Task 5: Update Existing References And Simulations

**Files:**
- Modify: `packages/predict/simulations/src/runtime.ts`
- Modify: `packages/predict/simulations/src/shared.ts`
- Modify: `packages/predict/simulations/src/sim.ts`

- [ ] **Step 1: Search for removed symbols**

Run:

```bash
rg -n "fee_reserve|FeeReserve|set_fee_shares|lp_fee|protocol_fee|insurance_fee|protocol_fee_balance|insurance_fee_balance" packages/predict
```

Expected: no matches outside generated build artifacts and this implementation document.

- [ ] **Step 2: Update simulation event parsing if needed**

If simulation code reads `FeeAccrued`, change it to expect:

```text
expiry_market_id
total_fee
rebate_fee_basis
```

Remove assumptions about LP/protocol/insurance fee shares.

- [ ] **Step 3: Update simulation calls if Move signatures changed**

Audit `packages/predict/simulations/src/runtime.ts` for stale `typeArguments` or argument lists for changed Move entrypoints.

- [ ] **Step 4: Run script verification if simulation files changed**

Run:

```bash
pnpm run lint
```

If simulation execution paths changed, also run:

```bash
cd packages/predict/simulations && bash run.sh --setup --skip-analysis
```

For execution-path changes that affect trade, redeem, settlement, or compaction simulation calls, also run:

```bash
cd packages/predict/simulations && SIM_MAX_ROWS=1 bash run.sh --skip-analysis
```

- [ ] **Step 5: Commit**

```bash
git add packages/predict/simulations
git commit -m "predict: update simulations for loser rebate fees"
```

### Task 6: Full Verification And Review

**Files:**
- Modify: any Move files requiring formatting after previous tasks

- [ ] **Step 1: Format changed files**

Run the repo formatter:

```bash
pnpm run prettier:fix
```

- [ ] **Step 2: Build Predict**

Run:

```bash
sui move build --path packages/predict
```

Expected: PASS with no Move compiler errors.

- [ ] **Step 3: Run existing Predict tests only if they remain in the package**

This plan does not add unit tests. If existing tests remain and are not obsolete from removed modules, run:

```bash
sui move test --path packages/predict --gas-limit 100000000000
```

Expected: PASS with zero failures. If failures come from tests whose target module was intentionally removed, delete those obsolete tests rather than adding replacement tests.

- [ ] **Step 4: Search for obsolete concepts**

Run:

```bash
rg -n "insurance fee|protocol fee|fee reserve|FeeReserve|set_fee_shares|lp_fee_share|protocol_fee_share|insurance_fee_share" packages/predict/sources packages/predict/tests packages/predict/simulations
```

Expected: no matches except comments intentionally explaining removed behavior. Prefer no matches.

- [ ] **Step 5: Manual accounting review**

Review these invariants in the final diff:

- Mint sends principal to `lp_cash_balance` and fee to `fee_balance`.
- Mint attaches raw fee basis to both manager and matrix.
- Live redeem removes fee basis from both manager and matrix using the same rounded-up value.
- Live redeem fee enters `fee_balance` with no new rebate basis.
- Settled losing redeem pays `removed_fee_basis * settlement_loss_rebate_rate`, rounded down.
- Settled winning redeem pays no rebate.
- Compaction leaves exact payout liability in `lp_cash_balance`.
- Compaction leaves exact remaining loser rebate liability in `fee_balance`.
- Compaction moves all other DUSDC into `PoolVault.idle_balance`.
- Expiry valuation includes fee NAV net of expected live or exact settled rebate liability.

- [ ] **Step 6: Commit final formatting or cleanup**

```bash
git add packages/predict
git commit -m "predict: verify loser rebate accounting"
```

---

## Rule Compliance Review

### Rules The Plan Follows

- **Move comments:** Comments are scoped to module responsibility, accounting units, and non-obvious sequencing.
- **Config rules:** `settlement_loss_rebate_rate` is admin-tunable, bounded in `config_constants`, stored in `FeeConfig`, and snapshotted into each expiry. Runtime logic reads the expiry snapshot, not the default.
- **Naming and API rules:** The admin setter is named as a template setter because it affects future expiries only. The plan avoids generic event names and uses `expiry_market_id`.
- **Validation rules:** Flow-level checks stay in `ExpiryMarket`; math/data-structure checks stay in `StrikeMatrix` and `PredictManager`.
- **Fee event ownership:** `ExpiryMarket` owns trade fee accrual and emits the fee event.
- **Compaction rules:** Compaction remains pool-coordinated, unregisters active expiry through `PoolVault`, and leaves no free LP cash or non-rebate fee surplus in the expiry.
- **Scripts rules:** Simulation calls and event parsing are explicitly audited, with setup and end-to-end smoke checks when simulation execution paths change.

### Explicit Rule Exception

The existing Predict guidance says public flow changes should add or update unit tests. The user explicitly instructed: "don't write any unit tests as part of this implementation." That direct instruction overrides the default rule for this plan.

The plan compensates with:

- Move build verification
- existing test-suite execution if applicable
- simulation smoke checks if simulation paths change
- symbol audits for removed fee concepts
- manual accounting invariant review

### Rules To Update

No repo rule update is needed.

Reason: this is a one-off user-directed exception to normal test coverage expectations, not a new general convention for Predict work. The current `.claude/rules/unit-tests.md` guidance should remain in force for future Predict changes unless the user explicitly gives the same no-unit-tests instruction again.
