# Predict Testnet integration

This guide connects applications and backend services to the `predict-testnet-8-21` deployment. Predict is deployed on Sui Testnet only, and its interfaces may change before a mainnet release.

## Choose the right surface

| Consumer question                                                                                | Source                                                                                                                                                    |
| ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Which packages, shared objects, coin types, units, and oracle objects belong to this deployment? | [`deployment.testnet.json`](./deployment.testnet.json)                                                                                                    |
| How do I construct transactions or read current on-chain state?                                  | [`@mysten/deepbook-v3/predict`](https://github.com/MystenLabs/ts-sdks/blob/main/packages/deepbook-v3/PREDICT.md) over the public Sui Testnet gRPC service |
| Which markets, events, positions, account records, and oracle observations have been indexed?    | The public read APIs below                                                                                                                                |
| How does the protocol behave?                                                                    | [Predict protocol documentation](../docs/README.md)                                                                                                       |

The deployment manifest is the stable identity record for this branch. Its configuration values are an audited initial snapshot; applications must read mutable protocol and cadence state from the shared objects on-chain.

The public read APIs are indexed views, not transaction authorities or immutable deployment records. Check each service's `/status` response before relying on recent data.

## TypeScript SDK

Install the public SDK and its Sui peer dependency:

```sh
npm install @mysten/deepbook-v3 @mysten/sui
```

The SDK's Testnet configuration is generated from this deployment's manifest. Assert the deployment name at startup because a later SDK release can intentionally move Testnet to a newer deployment.

```ts
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { getDeployment, predict } from "@mysten/deepbook-v3/predict";

const deployment = getDeployment("testnet");
if (deployment.deployment !== "predict-testnet-8-21") {
    throw new Error(`Expected predict-testnet-8-21, received ${deployment.deployment}`);
}

const client = new SuiGrpcClient({
    network: "testnet",
    baseUrl: "https://fullnode.testnet.sui.io:443",
}).$extend(predict({ network: "testnet" }));

const markets = await client.predict.read.markets();
```

Use the [SDK quickstart](https://github.com/MystenLabs/ts-sdks/blob/main/packages/deepbook-v3/PREDICT.md#quickstart) for account creation, deposits, quotes, mints, redemptions, claims, and PLP requests. SDK transaction methods return transactions for the caller's wallet or signer; the SDK never signs or handles keys.

## Public read APIs

Every endpoint below is a read-only JSON `GET` endpoint with permissive browser CORS.

| Service  | Base URL                                                                                                 | Primary data                                                                              |
| -------- | -------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Predict  | [`https://predict-server-v4.testnet.mystenlabs.com`](https://predict-server-v4.testnet.mystenlabs.com)   | Markets, market state, positions, vault state, protocol events, and indexed configuration |
| Propbook | [`https://propbook-server-v4.testnet.mystenlabs.com`](https://propbook-server-v4.testnet.mystenlabs.com) | Oracle bindings, Pyth observations, and Block Scholes spot, forward, and SVI observations |
| Account  | [`https://account-server-v4.testnet.mystenlabs.com`](https://account-server-v4.testnet.mystenlabs.com)   | Account custody state, balances, activity, portfolio, and app authorizations              |

These hostnames are operational Testnet endpoints associated with this deployment. They are not part of the audited manifest and may be replaced or retired independently of the on-chain packages.

### Discover active markets

```sh
curl 'https://predict-server-v4.testnet.mystenlabs.com/markets?active=true&limit=50'
```

The response is an array of future, unsettled market-creation records ordered by expiry. Use `expiry_market_id` for market-scoped reads, `pool_vault_id` for vault reads, and `propbook_underlying_id` to join the market to Propbook.

```sh
MARKET_ID='0x...'
curl "https://predict-server-v4.testnet.mystenlabs.com/markets/${MARKET_ID}/state"
curl "https://predict-server-v4.testnet.mystenlabs.com/markets/${MARKET_ID}/open-interest"
```

Market state returns the creation record plus the latest reference tick, mint-pause state, and settlement when those components exist.

### Read oracle bindings and observations

```sh
curl 'https://propbook-server-v4.testnet.mystenlabs.com/oracle-bindings'
```

The bindings connect a market's `propbook_underlying_id` and oracle kind to the object ID used by the observation endpoints. The same IDs are available under `underlyings` in the deployment manifest. Run the following commands from this directory:

```sh
PYTH_ORACLE_ID="$(jq -r '.underlyings.BTC.pythFeed' deployment.testnet.json)"
VALUE_STORE_ID="$(jq -r '.underlyings.BTC.blockScholesValueStore' deployment.testnet.json)"
SVI_STORE_ID="$(jq -r '.underlyings.BTC.blockScholesSviStore' deployment.testnet.json)"

curl "https://propbook-server-v4.testnet.mystenlabs.com/oracles/${PYTH_ORACLE_ID}/pyth/latest"
curl "https://propbook-server-v4.testnet.mystenlabs.com/oracles/${VALUE_STORE_ID}/block-scholes/spot?limit=10"
curl "https://propbook-server-v4.testnet.mystenlabs.com/oracles/${VALUE_STORE_ID}/block-scholes/forward?limit=10"
curl "https://propbook-server-v4.testnet.mystenlabs.com/oracles/${SVI_STORE_ID}/block-scholes/svi?limit=10"
```

Use each observation's source timestamp to judge vendor freshness and its checkpoint timestamp to judge when it landed on Sui. Do not sort observations by source timestamp alone because an older source observation can land later.

### Read account and position state

Account API paths use the shared Account wrapper object ID, not the wallet owner address. The SDK derives it with `client.predict.wrapperIdFor(owner)`.

```sh
ACCOUNT_WRAPPER_ID='0x...'
curl "https://account-server-v4.testnet.mystenlabs.com/accounts/${ACCOUNT_WRAPPER_ID}/portfolio"
curl "https://account-server-v4.testnet.mystenlabs.com/accounts/${ACCOUNT_WRAPPER_ID}/balances"
curl "https://predict-server-v4.testnet.mystenlabs.com/accounts/${ACCOUNT_WRAPPER_ID}/positions?status=open&limit=100"
```

An open position whose market state includes a settlement is claimable; claimability is derived from the position and market together rather than represented by a separate position status.

### Page raw protocol events

Discover the allowlisted event resources and filter profiles at [`/events`](https://predict-server-v4.testnet.mystenlabs.com/events), then page one resource:

```sh
curl 'https://predict-server-v4.testnet.mystenlabs.com/events/market-created?limit=100'
```

Raw event pages are ordered oldest-first by `(checkpoint_timestamp_ms, checkpoint, tx_index, event_index)`. The first page fixes a checkpoint snapshot; continue with the opaque `page.next_cursor` and repeat any resource filters unchanged until `page.has_next_page` is false.

`from_ms` is an inclusive checkpoint-timestamp lower bound and `to_ms` is an exclusive upper bound. Named history endpoints instead use `start_time` and `end_time` in Unix seconds, so do not reuse one endpoint family's timestamps in the other.

### Check freshness

```sh
curl 'https://predict-server-v4.testnet.mystenlabs.com/status'
curl 'https://propbook-server-v4.testnet.mystenlabs.com/status'
curl 'https://account-server-v4.testnet.mystenlabs.com/status'
```

Each response reports the latest on-chain checkpoint, every indexed pipeline's checkpoint and time lag, and the maximum lag. Treat a non-`OK` status or an unexpectedly old required pipeline as incomplete recent data rather than as an empty application state.

## Data conventions

-   Postgres `NUMERIC` values serialize as JSON strings. Parse monetary, quantity, probability, price, rate, and large identifier fields with decimal or bigint tooling rather than `parseFloat`.
-   The manifest owns the exact unit constants for this deployment. Probabilities, prices, and rates use the manifest's fixed-point scale; DUSDC-denominated amounts use the quote coin decimals.
-   On-chain and event timestamps use Unix milliseconds unless an endpoint explicitly documents Unix seconds. Raw event windows use `from_ms` and `to_ms`; named history windows use `start_time` and `end_time` in seconds.
-   Object IDs and addresses are full-length hex strings. Packed order IDs are decimal u256 strings and are unique only inside one expiry market, so identify a position by `(expiry_market_id, order_id)`.
-   Named history feeds are generally newest-first. Raw event pages deliberately use ascending snapshot pagination; preserve the full event ordering tuple when merging resources.
-   Unknown identifiers return `null` components, empty arrays, or `null` point lookups depending on the endpoint. They do not generally return 404.

## Scope

There are no writable REST endpoints. Submit transactions through the SDK or generated Move bindings, and use Sui Testnet as the execution authority.

This guide covers the `predict-testnet-8-21` Testnet deployment only. It does not define API availability guarantees, a mainnet deployment, wallet UX, key custody, or a stable REST versioning policy.
