---
paths:
  - "packages/venue/**"
---

# Venue

Read this before a devnet publish or an end-to-end venue trade. The [PredictSync technical design](https://app.notion.com/p/3d06d9dcb4e981a79cfee3c51dfce82e) is the design source. Agreed behavior goes on a decision row there, and the package matches that row. A difference that is not yet agreed stays on [5.7 Assumptions and differences](https://app.notion.com/p/3e96d9dcb4e981a398ecd04fd5e4939e). Live object ids belong on [5.6 Devnet ready](https://app.notion.com/p/3e86d9dcb4e981bd922ad7ce086f50f5).

- The admin address is `0x0fe362f6d347b3cdae01d67ab415bbf614e4e6a5f8c875199c22ff6abe328f9f`. If it needs gas, ask the user to fund that address at http://faucet.sui.io/?network=devnet.
- Leave the CLI on devnet. Put the chain id from `sui client chain-identifier` in `[environments]` for venue, account, and fixed_math.
- The enclave dependency stays the Nautilus git revision. `[dep-replacements.devnet]` compiles that revision with its mainnet environment. If the build still reports that enclave has no devnet environment, publish from a temporary local copy that only adds the environment, then restore the git dependency and the lock. Do not edit the checkout under `~/.move`.
- A struct layout change needs a new package. Clear `[published.devnet]` before `sui client publish --with-unpublished-dependencies packages/venue`. That command bundles account, fixed_math, and enclave into the venue package id. Leave USDC published. A protocol-version warning is not a failed publish.
- Replace the 5.6 Devnet objects section and both keeper `config.devnet.yaml` files, in deepbook-services and sui-operations. Drop the previous package's ids.
- The test desk lives in deepbook-services at `venue/desk` on the `venue/devnet` branch. It does not belong in this repository.
- Dogfood leaves `enclave_required` off. `publish_with_key` creates a market with no enclave. The publisher cap writes each mid through `publish_mid` and the result through `settle_as_publisher`. Turn `enclave_required` on only when Settle must take the Nautilus signature. Keep the claim window at the admin minimum unless it was lowered.
- Open spends the trader account. Rebalance before open so the market holds backing. Prices use a 1e9 scale. Devnet USDC has 6 decimals. `deposit_funds` takes the accumulator root `0x0000000000000000000000000000000000000000000000000000000000000acc` and clock `0x6`.
- Mids are not signed. A result signature is checked only when `enclave_required` is on. That timestamp is newer than `last_signed_ms` and no later than clock `0x6`. The index type id is the dynamic field name from type creation. `sui client ptb` has no `--json`. Read the receipt with `sui client tx-block --json <digest>`.
- Run `sui move test --path packages/venue --gas-limit 100000000000` in the main session.
