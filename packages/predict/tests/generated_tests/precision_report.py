#!/usr/bin/env python3
"""
Run predict Move tests and report all failures with any available context.

Captures:
- assert_eq! failures: extracts actual vs expected values and computes gaps
- assert!/abort failures: reports the abort location and code
- Groups by failure type for easy triage

Usage: cd packages/predict && python3 tests/generated_tests/precision_report.py
"""

import re
import subprocess


def run_tests() -> str:
    result = subprocess.run(
        ["sui", "move", "test", "--gas-limit", "100000000000"],
        capture_output=True,
        text=True,
    )
    return result.stdout + result.stderr


def parse_assert_eq_failures(output: str) -> list[dict]:
    """Parse assert_eq! failures from interleaved debug output + FAIL lines."""
    lines = output.splitlines()
    failures = []
    i = 0

    while i < len(lines):
        if '[debug] "Assertion failed:"' in lines[i]:
            actual_line = lines[i + 1] if i + 1 < len(lines) else ""
            neq_line = lines[i + 2] if i + 2 < len(lines) else ""
            expected_line = lines[i + 3] if i + 3 < len(lines) else ""

            actual_m = re.search(r"\[debug\]\s+(\d+)", actual_line)
            expected_m = re.search(r"\[debug\]\s+(\d+)", expected_line)

            if actual_m and expected_m and '"!="' in neq_line:
                actual = int(actual_m.group(1))
                expected = int(expected_m.group(1))

                test_name = "unknown"
                for j in range(i + 4, min(i + 10, len(lines))):
                    fail_m = re.match(r"\[\s*FAIL\s*\]\s+(.*)", lines[j])
                    if fail_m:
                        test_name = fail_m.group(1).strip()
                        break

                diff = abs(actual - expected)
                rel = diff / expected * 100 if expected != 0 else float("inf")

                failures.append({
                    "test": test_name,
                    "actual": actual,
                    "expected": expected,
                    "diff": diff,
                    "rel_pct": rel,
                    "type": "assert_eq",
                })

                i += 4
                continue

        i += 1

    return failures


def parse_failure_blocks(output: str) -> list[dict]:
    """Parse the detailed failure blocks at the end of test output.

    These look like:
    ┌── test_name ──────
    │ error[E11001]: test failure
    │     ┌─ ./path/to/file.move:LINE:COL
    │     │
    │ ... │     code or assert
    │     │     ^^^^^ ...aborted with code N originating in module M...
    │
    └──────────────────
    """
    failures = []
    lines = output.splitlines()
    i = 0

    while i < len(lines):
        # Match: ┌── test_name ──────
        block_start = re.match(r"[│\s]*┌──\s+(\S+)\s+──", lines[i])
        if block_start:
            test_name = block_start.group(1)
            block_lines = []
            i += 1

            # Collect until └──
            while i < len(lines) and "└──" not in lines[i]:
                block_lines.append(lines[i])
                i += 1

            block_text = "\n".join(block_lines)

            # Extract source location
            loc_m = re.search(r"┌─\s+(\S+):(\d+):(\d+)", block_text)
            location = f"{loc_m.group(1)}:{loc_m.group(2)}" if loc_m else "unknown"

            # Extract abort code if present
            code_m = re.search(r"aborted with code (\d+)", block_text)
            abort_code = int(code_m.group(1)) if code_m else None

            # Extract originating module
            module_m = re.search(r"originating in the module (\S+)", block_text)
            module = module_m.group(1) if module_m else "unknown"

            failures.append({
                "test": test_name,
                "location": location,
                "abort_code": abort_code,
                "module": module,
            })

        i += 1

    return failures


def print_report(
    assert_eq_failures: list[dict],
    all_failure_blocks: list[dict],
    total_pass: int,
    total_fail: int,
):
    print(f"Tests: {total_pass} passed, {total_fail} failed\n")

    if total_fail == 0:
        print("All tests pass.")
        return

    # Build set of tests that had assert_eq! failures (with values)
    eq_test_names = {f["test"] for f in assert_eq_failures}

    # Other failures: tests in failure blocks but NOT in assert_eq set
    other_failures = [
        f for f in all_failure_blocks if f["test"] not in eq_test_names
    ]

    # === assert_eq! precision gaps ===
    if assert_eq_failures:
        # Deduplicate
        seen = set()
        unique = []
        for f in assert_eq_failures:
            key = (f["test"], f["actual"], f["expected"])
            if key not in seen:
                seen.add(key)
                unique.append(f)

        unique.sort(key=lambda f: f["diff"], reverse=True)

        print(f"{'='*95}")
        print(f"  PRECISION GAPS — {len(unique)} assert_eq! failures with values")
        print(f"{'='*95}")
        print(f"{'Gap':>6}  {'Rel%':>10}  {'Actual':>15}  {'Expected':>15}  Test")
        print(f"{'-'*6}  {'-'*10}  {'-'*15}  {'-'*15}  {'-'*40}")

        for f in unique:
            short = f["test"].replace("deepbook_predict::", "")
            print(
                f"{f['diff']:>6}  {f['rel_pct']:>10.6f}  "
                f"{f['actual']:>15,}  {f['expected']:>15,}  {short}"
            )

        print(f"\n  Max gap: {unique[0]['diff']} units  |  "
              f"Median: {unique[len(unique)//2]['diff']} units")
        print()

    # === Other failures (aborts, assert!, etc.) ===
    if other_failures:
        print(f"{'='*95}")
        print(f"  OTHER FAILURES — {len(other_failures)} tests aborted")
        print(f"{'='*95}")
        print(f"  {'Test':<55} {'Location':<25} {'Module'}")
        print(f"  {'-'*55} {'-'*25} {'-'*30}")

        for f in other_failures:
            code_str = f"code={f['abort_code']}" if f["abort_code"] is not None else ""
            print(f"  {f['test']:<55} {f['location']:<25} {f['module']} {code_str}")

        print()

    # === Summary ===
    print(f"{'='*95}")
    print(f"  SUMMARY: {total_pass} passed, {total_fail} failed "
          f"({len(assert_eq_failures)} precision, {len(other_failures)} other)")
    print(f"{'='*95}\n")


def main():
    print("Running sui move test...\n")
    output = run_tests()

    total_pass = len(re.findall(r"\[\s*PASS\s*\]", output))
    total_fail = len(re.findall(r"\[\s*FAIL\s*\]", output))

    assert_eq_failures = parse_assert_eq_failures(output)
    all_failure_blocks = parse_failure_blocks(output)

    print_report(assert_eq_failures, all_failure_blocks, total_pass, total_fail)


if __name__ == "__main__":
    main()
