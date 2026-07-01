# Predict Predeploy Audit and Stress Docs

This directory is the tracked source of truth for Predict work that must be
resolved, accepted, or disclosed before a value-bearing deployment.

It is intentionally separate from `packages/predict/docs/`, which explains the
protocol to technical users and evaluators. The files here are for the protocol
team: audit findings, stress-test results, predeploy gates, and policies that
future reviewers must preserve.

## Index

- `open-items.md` - current predeploy bug, gate, and follow-up tracker.
- `rounding-policy.md` - protocol-wide rounding and liveness rules.
- `oracle-calibration.md` - near-expiry oracle calibration finding and repro.
- `stress/capacity-and-gas-findings.md` - consolidated capacity model and cap
  recommendations.
- `stress/mint-batch-findings-2026-07-01.md` - localnet finding for batched
  mint/redeem PTB amplification.
- `stress/nav-stress-findings-2026-06-30.md` - localnet finding for NAV flush
  OOG below the current per-market leveraged-order cap.

## Update Rules

- Keep resolved issues out of `open-items.md`; the purpose is a live checklist.
- Keep raw generated audit reports and scratchpads ignored. Extract only durable
  findings or policy decisions into this directory.
- When a finding is accepted rather than fixed, say so explicitly and point to
  the public disclosure or design decision that carries it.
- When a stress result is superseded, update the consolidated stress doc first,
  then adjust the narrow dated finding only if its original conclusion changed.
