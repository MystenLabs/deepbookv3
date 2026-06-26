# SDK Decisions

This is the settled-decision log for the Python SDK. Update it when SDK behavior
changes in a way future agents should not re-litigate.

## D001 - RPC Is The Live Source Of Truth

The SDK reads live Predict state from Sui JSON-RPC objects. The Predict indexer is
used for history and health, not as the authoritative live state source.

Reason: the protocol state lives on-chain, while the indexer can lag or be unavailable.

## D002 - Indexer Fails Open

`PredictIndexerClient.health()` and `markets()` degrade instead of raising for normal
transport or malformed-response failures.

Reason: `predict-sdk status` should remain useful during indexer outages.

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
