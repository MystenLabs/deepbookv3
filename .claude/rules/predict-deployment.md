---
paths:
  - "packages/predict/deployment/**"
---

# Predict deployment

- Keep the resumable operator journal and the integration manifest separate. `deployment.testnet.state.json` is mode-`0600`, gitignored execution state; `deployment.testnet.json` is the stable public consumer surface.
- Generate the integration manifest only from a `complete` deployment state after the final target-chain audit succeeds. A partial, failed, ambiguous, or in-flight run must not update the manifest.
- The manifest may contain stable package/object/coin/oracle/writer identities, the replay checkpoint, units, and initial configuration pinned to exact shared-object versions and digests. A transaction checkpoint may be recorded only as a verification fence, not as an assertion that object values were read at that checkpoint. Transaction receipts, deployer/bootstrap accounts, temporary markets, balances, rebalances, and upgrade/admin/metadata capabilities stay in operator state.
- Treat an interrupted broadcast as a state-machine recovery, not a fresh deploy. Resume from the same source commit, signer, client environment, `Published.toml` identities, and journal; if the submitted digest is unknown, fail closed and reconcile on-chain history before retrying.
- Mutable protocol and cadence policy is chain-owned. The manifest describes the initial verified snapshot; services must read live values from the shared objects.
- Run `./node_modules/.bin/tsc -p packages/predict/deployment/tsconfig.json` and `node --import tsx --test packages/predict/deployment/deploy.test.ts` after changing the script or manifest.
