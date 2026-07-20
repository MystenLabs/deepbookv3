#!/usr/bin/env python3
"""Build Predict and accept only the exact debt-controller known-RED set."""

from __future__ import annotations

import subprocess
import sys

import check_predeploy_debt as debt


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    process = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(process.stdout, end="")
    return process


def main() -> int:
    link_errors = debt.current_known_red_errors()
    if link_errors:
        for error in link_errors:
            print(f"ERROR: {error}")
        return 1

    build = run(
        [
            "sui",
            "move",
            "build",
            "--path",
            str(debt.PREDICT),
            "--warnings-are-errors",
        ]
    )
    if build.returncode != 0:
        print("ERROR: warning-strict Predict build failed")
        return 1

    test = run(
        [
            "sui",
            "move",
            "test",
            "--path",
            str(debt.PREDICT),
            "--gas-limit",
            "100000000000",
        ]
    )
    expected = {row.test for row in debt.load_known_red_manifest()}
    errors = debt.known_red_acceptance_errors(test.returncode, test.stdout, expected)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(f"Predict known-RED gate: ok ({len(expected)} exact failing tests)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
