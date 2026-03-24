#!/usr/bin/env python3
"""
Run predict Move tests and report precision gaps between contract output
and scipy ground-truth expected values.

Usage: cd packages/predict && python3 tests/generated_tests/precision_report.py
"""

import re
import subprocess
import sys


def run_tests() -> str:
    result = subprocess.run(
        ["sui", "move", "test", "--gas-limit", "100000000000"],
        capture_output=True,
        text=True,
    )
    return result.stdout + result.stderr


def parse_failures(output: str) -> list[dict]:
    """Parse interleaved debug output + FAIL lines into structured records."""
    lines = output.splitlines()
    failures = []
    i = 0

    while i < len(lines):
        # Look for "Assertion failed:" pattern
        if '[debug] "Assertion failed:"' in lines[i]:
            # Next lines: actual, "!=", expected
            actual_line = lines[i + 1] if i + 1 < len(lines) else ""
            neq_line = lines[i + 2] if i + 2 < len(lines) else ""
            expected_line = lines[i + 3] if i + 3 < len(lines) else ""

            actual_m = re.search(r"\[debug\]\s+(\d+)", actual_line)
            expected_m = re.search(r"\[debug\]\s+(\d+)", expected_line)

            if actual_m and expected_m and '"!="' in neq_line:
                actual = int(actual_m.group(1))
                expected = int(expected_m.group(1))

                # Find the next FAIL line to get the test name
                test_name = "unknown"
                for j in range(i + 4, min(i + 10, len(lines))):
                    fail_m = re.match(r"\[\s*FAIL\s*\]\s+(.*)", lines[j])
                    if fail_m:
                        test_name = fail_m.group(1).strip()
                        break

                diff = abs(actual - expected)
                # Relative error (avoid div by zero)
                rel = diff / expected * 100 if expected != 0 else float("inf")

                failures.append({
                    "test": test_name,
                    "actual": actual,
                    "expected": expected,
                    "diff": diff,
                    "rel_pct": rel,
                })

                i += 4
                continue

        i += 1

    return failures


def print_report(failures: list[dict]):
    # Deduplicate by (test, actual, expected) since some tests have multiple assertions
    seen = set()
    unique = []
    for f in failures:
        key = (f["test"], f["actual"], f["expected"])
        if key not in seen:
            seen.add(key)
            unique.append(f)

    unique.sort(key=lambda f: f["diff"], reverse=True)

    total = len(unique)
    if total == 0:
        print("All tests pass — no precision gaps detected.")
        return

    print(f"\n{'='*90}")
    print(f"  PRECISION REPORT — {total} assertion failures")
    print(f"{'='*90}")
    print(f"{'Gap':>6}  {'Rel%':>10}  {'Actual':>15}  {'Expected':>15}  Test")
    print(f"{'-'*6}  {'-'*10}  {'-'*15}  {'-'*15}  {'-'*40}")

    for f in unique:
        short = f["test"].replace("deepbook_predict::", "")
        print(
            f"{f['diff']:>6}  {f['rel_pct']:>10.6f}  "
            f"{f['actual']:>15,}  {f['expected']:>15,}  {short}"
        )

    print(f"\n{'='*90}")
    print(f"  Max gap: {unique[0]['diff']} units  |  "
          f"Median gap: {unique[len(unique)//2]['diff']} units  |  "
          f"Total failures: {total}")
    print(f"{'='*90}\n")


def main():
    print("Running sui move test...\n")
    output = run_tests()

    # Print pass/fail summary
    passes = len(re.findall(r"\[\s*PASS\s*\]", output))
    fails = len(re.findall(r"\[\s*FAIL\s*\]", output))
    print(f"Tests: {passes} passed, {fails} failed\n")

    failures = parse_failures(output)
    print_report(failures)


if __name__ == "__main__":
    main()
