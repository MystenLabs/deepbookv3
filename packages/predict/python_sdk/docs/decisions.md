# SDK Decisions

This is the settled-decision log for the Python SDK. Update it when SDK behavior
changes in a way future agents should not re-litigate.

## D001 - Indexer Is The Data Plane

The SDK reads all observe/monitor data — markets, market/vault/config state, positions,
PnL, and oracle freshness — from the indexer services (predict-server + the oracle
service), not from Sui object reads. Reads default to the indexer; there is no
chain-read fallback on the observe path.

Reason: the indexers are operated as a high-availability public good and serve
per-entity aggregates (a manager's positions, history) that a point-in-time object read
cannot. Clients still fail open — observe commands surface "unavailable" rather than
crashing — and trading still works when the indexer is down (it only needs the chain).
(This reverses the original RPC-as-source-of-truth stance.)

## D002 - Chain Is The Execution Plane

The chain is used only for execution: dry-run pricing (D004), transaction submission,
and the refs a transaction needs (shared initial versions, owned coin refs, gas price/
coin), plus the one live value the indexer does not carry — a market's `reference_tick`,
read on the trade path. Custody balance (checked before a withdraw) is also a chain read.

Reason: you cannot build a transaction from indexed data, and a write must never be
gated on lagging data. Mintability is enforced by the dry-run, so a stale observe read
can never cause a bad write.

## D003 - Write Commands Dry-Run By Default

CLI write commands require `--execute` to submit. Without it, they validate and price
through Sui dry-run only.

Reason: this lowers the risk of accidental on-chain writes and lets users inspect gas,
entry probability, and premium before committing.

## D004 - Dry-Run Mint Is The Pricer

The SDK does not maintain an off-chain Predict pricing implementation. Candidate range
prices are discovered by dry-running `mint_exact_quantity` and reading `OrderMinted`.

Reason: contract math and oracle gating are the source of truth.

## D005 - PyNaCl Ships In The Base Package

PyNaCl is a normal dependency in `pyproject.toml`, not an optional `tx` extra.

Reason: the SDK is packaged as a full observe/trade client. Signing is part of the
default package contract, while the Textual dashboard remains optional.

## D006 - Tests Are Offline By Default

The standard SDK test suite uses fake transports/readers/actions and deterministic
local keys. It must not require testnet RPC, private keys, or funded wallets.

Reason: contributors and agents need fast, repeatable verification.

## D007 - BCS Scope Stays Narrow

`bcs.py` is a hand-rolled encoder for the transaction shapes this SDK builds. It is not
a general-purpose Sui BCS library.

Reason: keeping the scope narrow makes it easier to audit and test.

## D008 - SDK Reads The Canonical Deployment Manifest

`load_testnet_config()` reads `packages/predict/deployment/deployment.testnet.json`
(the deploy tooling's output) as the single source of wiring, applying an SDK-side
`servers` overlay (the manifest does not carry service URLs). Wheels bundle a copy at
`predict_sdk/deployments/testnet.json` via a hatchling force-include; editable / in-repo
runs read the repo artifact directly.

Reason: the previous hand-copied Python literal drifted from the canonical manifest
(`servers` existed only in the copy). One source removes that drift.

## D009 - Config Is Single-Asset Today, Multi-Asset-Shaped

The deployment manifest wires one asset (BTC_USD). The `assets` dict + `asset(name)`
API is intentionally kept multi-asset-shaped so adding assets later needs no API
change; `from_dict` builds the single wired asset.

Reason: documents the shape so it is not "simplified" away or mistaken for a bug.

## D010 - Status Display Drops Live-Only Fields

`status()` omits fields the indexer does not serve: per-market `cash_balance` /
`payout_liability`, the `valuation_in_progress` gate, the pool queue counts, and the
`unfunded` slot state. Oracle freshness shows two feeds (pyth + block-scholes surface),
matching the config thresholds and the oracle service.

Reason: these are live-only chain values. Since mintability is enforced by the dry-run
(D002), dropping them from the display is safe and keeps the read path indexer-only.
