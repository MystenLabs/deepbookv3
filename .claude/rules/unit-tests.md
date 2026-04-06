---
paths:
  - "packages/**/tests/**"
---

# Unit Test Rules

These rules exist because Claude repeatedly wrote tests that confirmed buggy behavior instead of catching it. Every rule below addresses a specific failure mode observed in past sessions.

## Philosophy

The purpose of unit tests is to **define correct behavior and catch bugs**. A test that passes on first write is suspicious. A test suite where everything is green on the first run is a test suite that isn't testing anything.

## Rules

### 1. Never compute expected values using contract functions

This is the most common mistake. If the test uses the same code path as the production code to derive the expected value, it will pass even when the code is wrong.

```move
// BAD — circular logic. If calculate_fee is wrong, this still passes.
let fee = calculate_fee(1000, 30);
let expected = 1000 * 30 / 10000; // same formula as the contract
assert_eq!(fee, expected);

// GOOD — expected value independently derived (by hand, Python script, or reference impl)
// 0.3% of 1000 = 3
assert_eq!(calculate_fee(1000, 30), 3);
```

**Where to get expected values:**
- Hand calculation with comments showing the work
- `generate_constants.py` (scipy-backed ground truth for math/oracle tests)
- Real-world data from Block Scholes CSVs in `predict_research/`
- A reference implementation in a different language

### 2. Never adjust expected values to make tests pass

When a test fails, that means it found a bug. Do not change the expected value to match the contract output. Leave the test failing. The developer decides whether to fix the contract or accept the deviation.

```move
// BAD — you ran the test, got 500_000_002, and wrote:
assert_eq!(normal_cdf(0, false), 500_000_002);
// Φ(0) = 0.5 exactly. The correct assertion is:
assert_eq!(normal_cdf(0, false), 500_000_000);
// If this fails, that's a real precision bug — don't hide it.
```

### 3. Every test must assert output values

A test that only verifies "doesn't abort" is not a test. Every `#[test]` function must have at least one `assert!` or `assert_eq!` that checks a return value or state change.

```move
// BAD — tests nothing, will pass even if deposit is silently broken
#[test]
fun deposit_adds_funds() {
    let mut pm = create_predict_manager(ctx);
    pm.deposit(coin::mint_for_testing(1000, ctx));
    destroy(pm);
}

// GOOD — verifies the state change actually happened
#[test]
fun deposit_adds_funds() {
    let mut pm = create_predict_manager(ctx);
    pm.deposit(coin::mint_for_testing(1000, ctx));
    assert_eq!(pm.balance<SUI>(), 1000);
    destroy(pm);
}
```

### 4. Cover every abort code with an `expected_failure` test

For every `const E*` error constant in a source module, there must be at least one test that triggers it. Untested abort codes are untested error paths.

```move
#[test, expected_failure(abort_code = predict::EOracleSettled)]
fun mint_against_settled_oracle_aborts() {
    // ... setup settled oracle ...
    predict.mint(settled_oracle, strike, amount, ctx);
    abort // will differ from EOracleSettled if we reach here
}
```

### 5. Every test must call the function under test

A test that only validates test data (checking generated inputs are above a threshold, verifying vector lengths, asserting constants match) is not a test. Every test function must call the contract function it claims to test and assert on the result.

```move
// BAD — tests the generator, not the contract
#[test]
fun exp_overflow_cases_valid() {
    gs::overflow_cases().do!(|x| {
        assert!(x > 23_638_153_699); // never calls math::exp()
    });
}

// GOOD — tests the contract
#[test, expected_failure(abort_code = math::EExpOverflow)]
fun exp_overflow_aborts() {
    math::exp(23_638_153_700, false);
    abort
}
```

### 6. Don't test weaker properties already covered by exact assertions

If a scenario runner asserts exact contract output at every strike point against scipy, a separate test asserting a weaker property (monotonicity, ordering, complement summing to 1) on the same data is redundant. The exact assertion subsumes the weaker one — if the contract breaks monotonicity, the exact values won't match.

```move
// BAD — run_oracle_scenario(0) already asserts exact values at every strike.
// If monotonicity breaks, the exact assertions catch it first.
#[test]
fun live_up_monotonically_decreasing_with_strike() {
    let s = get_scenario(0);
    let points = s.strike_points();
    assert!(points[3].expected_up() > points[2].expected_up()); // also tests generator, not contract
}

// GOOD — the scenario runner IS the test for this property
#[test]
fun scenario_std() { run_oracle_scenario(0); }
```

### 7. Import constants from the constants module — don't duplicate

If a value exists in the `constants` module, import it. Hardcoded duplicates with "must stay in sync" comments are a code smell. Use macro aliases for frequently-used macros (macros can't be used in `const` initializers).

```move
// BAD — duplicates constants module, will silently drift
const MS_PER_YEAR: u64 = 31_536_000_000;
const STALENESS_THRESHOLD_MS: u64 = 30_000;

// GOOD — import and alias
use deepbook_predict::{constants, constants::float_scaling as float};
clock.set_for_testing(10_000 + constants::staleness_threshold_ms!() + 1);
let prices = new_price_data(50 * float!(), 51 * float!());
```

### 8. Name all constants — no magic numbers in test bodies

Raw numeric literals make tests unreadable and unverifiable. Define every constant with a name that explains what it represents.

```move
// BAD
assert_eq!(math::ln(2_000_000_000), 693_147_181);

// GOOD
const LN2: u64 = 693_147_181; // ln(2) * 1e9, from generate_constants.py
assert_eq!(math::ln(2 * FLOAT), LN2);
```

### 9. Test edge cases and boundaries

Bugs live at boundaries. Every test file should include:
- **Zero values**: zero amount, zero shares, zero price
- **Max values**: u64 max, maximum allowed config values
- **Exact boundaries**: strike == settlement, expiry == now, amount that yields exactly 1 share
- **Rounding direction**: verify truncation vs round-up behavior with small values where 1 unit matters
- **Off-by-one**: values just inside and just outside valid ranges

### 10. Use `assert_eq!`, never `assert_approx`

In smart contracts, 1 unit of precision loss can mean an exploit. Do not use approximate assertions or range checks. Every expected value must be exact.

```move
// BAD — hides up to 200M units of error
assert!(up > 390_000_000 && up < 410_000_000);

// GOOD — exact value, independently verified
assert_eq!(up, 399_512_345);
```

### 11. Use `generate_constants.py` for math-heavy tests

For any test involving math operations (ln, exp, normal_cdf, SVI pricing, binary option prices), the expected values must come from `generate_constants.py`, which uses scipy as ground truth. Do not hand-compute complex math — use the script, commit the constants, and reference the script in comments.

### 12. Production-behavior tests must use production-valid fixtures

If a test claims to model a real protocol scenario, its fixture must be valid under production creation and validation rules. Do not silently bypass oracle/grid/range/tick constraints just to make a scenario compile or pass. If the scenario cannot exist in production, it should fail immediately during setup.

- **Production-behavior tests** should go through production-like constructors and flows, and should fail fast when inputs would be rejected in real usage.
- **Pure math/internal tests** may use permissive helpers, but those helpers must be explicitly named as non-production fixtures (for example `create_unbounded_test_oracle`) so they cannot be confused with real oracle setup.
- Do not add test-only error codes or bypass paths just to validate a helper constructor itself unless the helper is the thing being intentionally tested.

```move
// BAD — hides an impossible production state behind a permissive helper
let oracle = oracle::create_test_oracle(...); // unconstrained strike grid
predict::mint(&mut predict, &mut manager, &oracle, key, quantity, &clock, ctx);

// GOOD — production-behavior test uses production-valid fixture rules
let oracle = oracle::create_test_oracle_with_grid(
    b"BTC".to_string(),
    svi,
    prices,
    0,
    expiry,
    0,
    min_strike,
    max_strike,
    tick_size,
    ctx,
);
predict::mint(&mut predict, &mut manager, &oracle, key, quantity, &clock, ctx);
```

### 13. Shared-object tests should capture IDs and use `take_shared_by_id`

When a test creates a shared object in `test_scenario`, capture its ID immediately and use that ID in later transactions. Do not rely on ambient `take_shared<T>()` when the object identity is already known.

- Good:
  - setup helper returns `predict_id`, `registry_id`, `manager_id`, `oracle_id`
  - later transactions use `take_shared_by_id<T>(id)`
  - shared objects are returned with `return_shared(...)` before `next_tx(...)`
- Bad:
  - tests repeatedly call `take_shared<T>()` and depend on there being only one shared object of that type in scope

This matches the established DeepBook core pattern and avoids brittle inventory/order assumptions in `test_scenario`.

### 14. Keep shared protocol setup scenario-driven; keep pure units local

Use `test_scenario` plus real entrypoints to build shared protocol state, and use local values only for genuinely pure/internal units.

- Shared protocol tests should:
  - create and wire shared objects through production-like flows
  - use helper modules to compose those flows
  - assert over real multi-tx state transitions
- Pure unit tests may stay local:
  - math helpers
  - small value types
  - internal data structures like trees or caches

Do not create standalone non-droppable protocol owners in tests and let them fall out of scope. If a type does not have `drop`, either:
- own it through another object that the test already consumes or destroys, or
- explicitly destroy it through a real destroy path.

## Move Test Syntax

### Merge `#[test]` and `#[expected_failure(...)]`

```move
// bad!
#[test]
#[expected_failure]
fun value_passes_check() {
    abort
}

// good!
#[test, expected_failure]
fun value_passes_check() {
    abort
}
```

### Do Not Clean Up `expected_failure` Tests

```move
// bad! clean up is not necessary
#[test, expected_failure(abort_code = my_app::EIncorrectValue)]
fun try_take_missing_object_fail() {
    let mut test = test_scenario::begin(@0);
    my_app::call_function(test.ctx());
    test.end();
}

// good! easy to see where test is expected to fail
#[test, expected_failure(abort_code = my_app::EIncorrectValue)]
fun try_take_missing_object_fail() {
    let mut test = test_scenario::begin(@0);
    my_app::call_function(test.ctx());

    abort // will differ from EIncorrectValue
}
```

### Do Not Prefix Tests With `test_` in Testing Modules

```move
// bad! the module is already called _tests
module my_package::my_module_tests;

#[test]
fun test_this_feature() { /* ... */ }

// good! better function name as the result
#[test]
fun this_feature_works() { /* ... */ }
```

### Do Not Use `TestScenario` Where Not Necessary

```move
// bad! no need, only using ctx
let mut test = test_scenario::begin(@0);
let nft = app::mint(test.ctx());
app::destroy(nft);
test.end();

// good! there's a dummy context for simple cases
let ctx = &mut tx_context::dummy();
app::mint(ctx).destroy();
```

### Do Not Use Abort Codes in `assert!` in Tests

```move
// bad! may match application error codes by accident
assert!(is_success, 0);

// good!
assert!(is_success);
```

### Use `assert_eq!` Whenever Possible

```move
// bad! old-style code
assert!(result == b"expected_value", 0);

// good! will print both values if fails
use std::unit_test::assert_eq;

assert_eq!(result, expected_value);
```

### Use "Black Hole" `destroy` Function

```move
// bad!
nft.destroy_for_testing();
app.destroy_for_testing();

// good! - no need to define special functions for cleanup
use sui::test_utils::destroy;

destroy(nft);
destroy(app);
```
