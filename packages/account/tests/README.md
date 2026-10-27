# Account Property-Based Random Tests

This test suite ([`random_tests.move`](./random_tests.move)) provides property-based fuzz and invariant testing for the `account` package using Move's `#[random_test]` harness.

All amounts use **9-digit float scaling** (`FLOAT_SCALING = 1_000_000_000` or $10^9$), aligning with standard SUI token precision and fixed-point math conventions.

---

## Test Inventory

| Test Function | Type | Property / Invariant Verified |
| :--- | :---: | :--- |
| **`random_baseline_deposit_100_withdraw_80`** | `#[random_test]` | **Baseline Test:** Verifies exact `100.0` in and `80.0` out leaves strictly `20.0` balance. |
| **`random_deposit_and_withdraw_invariant`** | `#[random_test]` | **Conservation of Value:** Proves `remaining == deposit - withdraw` holds across all randomized amount pairs. |
| **`random_full_withdrawal_leaves_zero`** | `#[random_test]` | **Dust Boundary:** Proves that withdrawing 100% of a scaled balance leaves strictly `0` dust. |
| **`random_multiple_deposits_accumulate`** | `#[random_test]` | **Monotonic Accumulation:** Proves sequential deposits $A + B + C$ accumulate losslessly without overflow. |
| **`random_multi_coin_isolation`** | `#[random_test]` | **Bag Isolation:** Proves withdrawing from `COIN_A` leaves `COIN_B`'s stored balance completely untouched. |
| **`random_excessive_withdrawal_aborts`** | `#[random_test]` | **Overdraft Protection:** Asserts that withdrawing `deposit + excess` always aborts with `EBalanceTooLow`. |
| **`random_app_data_roundtrip`** | `#[random_test]` | **Storage Fidelity:** Proves arbitrary 64-bit scaled values attach, borrow, and detach from app slots losslessly. |

---

## Running the Tests

### Run all random tests with 100 iterations:
```bash
# From within packages/account:
sui move test random_tests --rand-num-iters 100 --gas-limit 100000000000

# Or from repository root:
sui move test --path packages/account random_tests --rand-num-iters 100 --gas-limit 100000000000
```

### Run a single test with debug prints:
```bash
# Run the baseline test:
sui move test random_baseline_deposit_100_withdraw_80 --rand-num-iters 1

# Or run the deposit/withdraw invariant test:
sui move test random_deposit_and_withdraw_invariant --rand-num-iters 1
```

### Reproduce a specific random run with a seed:
```bash
sui move test random_tests --rand-seed <SEED_NUMBER>
```

