# DeepBook Server

The DeepBook Server is a Rust application that provides a RESTful API for the DeepBook project. It allows users to interact with the DeepBook database and retrieve information about DeepBook events.

## Health & Status Endpoints

### `/` - Health Check
Basic health check endpoint that returns HTTP 200 OK if the server is running.

```bash
curl http://localhost:9008/
```

### `/status` - Indexer Status
Returns detailed information about the indexer's health, including checkpoint lag and synchronization status.

```bash
curl http://localhost:9008/status
```

**Query Parameters:**
- `max_checkpoint_lag` (optional, default: 100) - Maximum acceptable checkpoint lag for "healthy" status
- `max_time_lag_seconds` (optional, default: 60) - Maximum acceptable time lag in seconds for "healthy" status

**Examples:**
```bash
# Use default thresholds (checkpoint_lag < 100, time_lag < 60 seconds)
curl http://localhost:9008/status

# Custom thresholds: allow up to 500 checkpoint lag and 300 seconds time lag
curl "http://localhost:9008/status?max_checkpoint_lag=500&max_time_lag_seconds=300"

# Strict thresholds: only healthy if checkpoint_lag < 10 and time_lag < 5 seconds
curl "http://localhost:9008/status?max_checkpoint_lag=10&max_time_lag_seconds=5"
```

**Example Response:**
```json
{
  "status": "OK",
  "latest_onchain_checkpoint": 12345678,
  "current_time_ms": 1732567890000,
  "earliest_checkpoint": 12345673,
  "max_lag_pipeline": "deepbook_indexer",
  "pipelines": [
    {
      "pipeline": "deepbook_indexer",
      "indexed_checkpoint": 12345673,
      "indexed_epoch": 500,
      "indexed_timestamp_ms": 1732567878000,
      "checkpoint_lag": 5,
      "time_lag_seconds": 12,
      "latest_onchain_checkpoint": 12345678
    }
  ],
  "max_checkpoint_lag": 5,
  "max_time_lag_seconds": 12
}
```

**Response Fields:**
- `status` - Overall health: `"OK"` or `"UNHEALTHY"` (based on client-provided thresholds)
- `latest_onchain_checkpoint` - Latest checkpoint on the blockchain
- `current_time_ms` - Current server timestamp
- `earliest_checkpoint` - The lowest checkpoint across all pipelines (useful for alerting)
- `max_lag_pipeline` - Name of the pipeline with the highest checkpoint lag (useful for alerting)
- `pipelines` - Array of per-pipeline details
- `max_checkpoint_lag` - Maximum checkpoint lag across all pipelines
- `max_time_lag_seconds` - Maximum time lag in seconds across all pipelines

**Status Values:**
- `OK` - Indexer is synced and up-to-date (based on thresholds)
- `UNHEALTHY` - Indexer is behind or experiencing delays

This endpoint is useful for monitoring the indexer's synchronization status and detecting stale data.

## Pyth Pro price adapter

The server exposes Hermes- and TradingView-like HTTP GET routes backed by
authenticated Pyth Pro requests:

- `GET /pyth/updates/price/latest`
- `GET /pyth/updates/price/:publish_time`
- `GET /pyth/shims/tradingview/history`

The first two routes use the Pyth Pro
[Router API](https://pyth-lazer-0.dourolabs.app/docs/openapi.json). They accept
repeatable numeric Pyth Pro feed IDs in `ids[]`, plus
`parsed=true` and optional `ignore_invalid_price_ids=true`. The historical path
uses a Unix timestamp in seconds; the server converts it to the microsecond
timestamp required by Pyth Pro. Responses deliberately provide only the parsed,
Hermes-like price fields used by DeepBook. They do not contain signed Hermes or
Pyth Pro binary payloads and are not intended for on-chain price updates.

The chart-history route uses the Pyth Pro
[History API](https://docs.pyth.network/price-feeds/pro/api/history). It keeps
the app's existing TradingView query and response shape: `symbol`,
`resolution`, `from`, and `to` produce aligned `s`, `t`, `o`, `h`, `l`, `c`,
and `v` arrays. Symbols are case-insensitive, and bounds use Unix seconds.
Supported resolutions are `1`, `2`, `5`, `15`, `30`, `60`, `120`, `240`,
`360`, `720`, `D`, `W`, and `M`.

Configure the server with:

- `PYTH_PRO_API_KEY` — bearer token for Pyth Pro. It is read directly from the
  environment and must remain in deployment secrets.
- `PYTH_PRO_URL` — optional Router API base URL; defaults to
  `https://pyth-lazer-0.dourolabs.app/v1`.
- `PYTH_PRO_ALLOWED_FEED_IDS` — comma-separated numeric feed IDs the public
  price routes are allowed to serve. Other IDs are rejected unless
  `ignore_invalid_price_ids=true`.
- `PYTH_PRO_LATEST_CACHE_TTL_MS` — lifetime of the shared latest-price
  snapshot; defaults to `1000`.
- `PYTH_PRO_HISTORY_CACHE_TTL_SECS` — historical entry lifetime; defaults to
  `86400`.
- `PYTH_PRO_HISTORY_CACHE_MAX_ENTRIES` — maximum historical
  `(feed_id, timestamp_us)` entries per process; defaults to `10000`.
- `PYTH_PRO_HISTORY_URL` — optional History API base URL; defaults to
  `https://pyth.dourolabs.app/v1`.
- `PYTH_PRO_HISTORY_SYMBOLS` — comma-separated TradingView symbols the
  chart-history route may serve, such as `Crypto.BTC/USD,Crypto.ETH/USD`.
  Other symbols are rejected so the route cannot become an unrestricted proxy
  for the Pyth Pro quota.
- `PYTH_PRO_CHART_HISTORY_CACHE_TTL_SECS` — chart-history response lifetime;
  defaults to `60`.
- `PYTH_PRO_CHART_HISTORY_CACHE_MAX_ENTRIES` — maximum chart-history responses
  cached per process; defaults to `256`.
- `PYTH_PRO_CHART_HISTORY_MAX_RANGE_SECS` — absolute maximum `to - from` span
  accepted by the chart-history route; defaults to `7776000` (90 days).
  Requests are also limited to 2161 candles, so the effective default range is
  36 hours at 1-minute resolution, 3 days at 2-minute resolution, 7.5 days at
  5-minute resolution, 22.5 days at 15-minute resolution, 45 days at
  30-minute resolution, and 90 days at hourly or coarser resolutions.

Latest prices are loaded on demand. The first request after the cache TTL
expires fetches every allowed feed in one Pyth Pro call and stores the snapshot
in memory with its fetch time. Moka coalesces concurrent misses into that same
load, including requests for different feed subsets. Requests during the next
second reuse the snapshot and cached serialized response; no Pyth quota is
spent while the DeepBook server is idle. Historical prices use a separate
bounded Moka cache keyed by numeric feed ID and microsecond timestamp. A request
containing several IDs fetches all cache misses in one Pyth Pro call, and
concurrent requests for the same timestamp share the load.

The mainnet and testnet DeepBook deployments use the same allowlist: the union
of the Pyth feeds currently exposed by `@mysten/deepbook-v3` on either network.
This keeps the public proxy behavior consistent across both servers:

| SDK coin      | SDK network       | Pyth Pro feed ID |
| ------------- | ----------------- | ---------------: |
| DBTC          | Testnet           |                1 |
| USDC / DBUSDC | Mainnet / Testnet |                7 |
| SUI           | Mainnet / Testnet |               11 |
| DEEP          | Mainnet / Testnet |              173 |
| WAL           | Mainnet           |              624 |
| XBTC          | Mainnet           |             1598 |
| SUIUSDE       | Mainnet           |             2998 |
| USDSUI        | Mainnet           |             3049 |

The testnet SDK currently points its DEEP entry at a Hermes beta HFT feed.
Pyth Pro feed 446 is the direct HFT symbol match but is inactive, so the
testnet deployment uses the active DEEP/USD feed 173 for that coin instead.

Chart history uses a separate bounded Moka cache keyed by canonical
`(symbol, resolution, from, to)`. Symbol casing and minute-aligned query bounds
are normalized so equivalent requests share an entry. Moka coalesces concurrent
misses for the same key into one authenticated History API request. Successful
responses are cached as serialized bytes, so cache hits do not clone or
re-serialize the JSON. Requests exceeding the configured maximum range are
rejected before contacting Pyth, bounding upstream work and cached response
size. Errors and rate limits are not cached.

The familiar route and query shape is intended to make migration simple, but
the parsed-only response is not a drop-in replacement for
`@pythnetwork/hermes-client`; callers should use a normal HTTP client.

### Run locally

With the server's Postgres database available at `DATABASE_URL`, start it from
the repository root:

```bash
export DATABASE_URL="postgres://postgres:postgrespw@localhost:5432/deepbook"
export PYTH_PRO_API_KEY="<your-api-key>"
export PYTH_PRO_ALLOWED_FEED_IDS="1,7,11,173,624,1598,2998,3049"
export PYTH_PRO_HISTORY_SYMBOLS="Crypto.BTC/USD,Crypto.ETH/USD"
cargo run -p deepbook-server
```

Keep the real API key in your local environment or secret manager; do not add
it to the repository. The first latest-price request may take one upstream
round trip; requests sharing its cache window are served from memory.

Example, using numeric Pyth Pro feed IDs `1` and `7`:

```bash
curl \
  "http://localhost:9008/pyth/updates/price/latest?ids[]=1&ids[]=7&parsed=true"

curl \
  "http://localhost:9008/pyth/updates/price/1700000000?ids[]=1&parsed=true"

curl \
  "http://localhost:9008/pyth/shims/tradingview/history?symbol=Crypto.BTC%2FUSD&resolution=1&from=1704067200&to=1704070800"
```

### Live Pyth WebSocket (opt-in)

`GET /pyth/ws` upgrades to a parsed-only WebSocket. It reuses `PYTH_PRO_API_KEY` and `PYTH_PRO_ALLOWED_FEED_IDS`; the existing HTTP routes and their caches retain their behavior. Enable the relay with `PYTH_WS_ALLOWED_ORIGINS`, a comma-separated list of exact browser origins such as `https://app.example.com,http://localhost:5173` (no trailing slash or paths). Without origins, a key, or allowed feeds, the route returns HTTP 503 and opens no upstream connections. Missing or unlisted origins are rejected with HTTP 403. Origin checks restrict browser use; they do not authenticate scripts or grant data redistribution rights.

Each enabled server replica starts three authenticated upstream WebSockets, one to each Pyth Pro endpoint, subscribes to the allowlisted feeds on `fixed_rate@200ms`, and reconnects with exponential backoff and jitter. Browser count does not change upstream connection count. Frames are parsed JSON with no signed payload. Feeds unsupported on the 200 ms channel are ignored upstream and remain stale; verify the deployed feed allowlist's channel support before enabling. The relay forwards every advancing envelope, including repeated prices, and drops duplicate or older envelopes from redundant endpoints. It never samples the HTTP latest cache or substitutes server time for Pyth time.

Client messages:

```json
{"type":"subscribe","feed_ids":[1]}
{"type":"unsubscribe","feed_ids":[1]}
```

Server messages:

```json
{"type":"subscribed","feed_ids":[1],"rejected":[]}
{"type":"price","feed_id":1,"price":"9512345678901","exponent":-8,"timestamp_us":"1795025640000000","feed_update_us":"1795025639987000"}
{"type":"status","feed_id":1,"stale":false,"last_timestamp_us":"1795025640000000"}
{"type":"unsubscribed","feed_ids":[1]}
{"type":"error","code":"invalid_message","message":"expected subscribe or unsubscribe with feed_ids"}
```

A new subscription receives the latest cached price, if present, and current health before live frames. Duplicate subscriptions are idempotent. `rejected` lists disallowed feeds or feeds exceeding the connection's 16-feed cap. Price in USD is `price × 10^exponent`. `timestamp_us` is the Pyth envelope time on the 200 ms grid; `feed_update_us` is when Pyth generated the underlying price and can be older. Large integers are strings. Missing prices are skipped, never replaced by zero. A feed starts stale, becomes healthy with an advancing price frame, and becomes stale after two seconds without one; checks run every 100 ms. A cached price can be stale, so clients must honor the status message and also detect silence locally.

The server pings every 15 seconds and closes clients missing two pongs. Clients must subscribe to at least one allowed feed within ten seconds. Each socket accepts messages up to 4 KiB and at most ten text commands per second. Per replica, the relay caps connections at 4,096 and connections per client IP at 20. The shared broadcast buffer holds 128 events; lagging clients are disconnected rather than silently skipping frames. Writes have a five-second timeout. Clients should reconnect with jittered backoff, re-subscribe, and recover missed exact-expiry frames with `/pyth/updates/price/{publish_time}` (whole-second expiries). The socket offers no replay or delivery guarantee across disconnects.

`PYTH_WS_TRUSTED_PROXY_HOPS` defaults to `0`, using the TCP peer IP and ignoring `X-Forwarded-For`. Behind a trusted proxy, set this to the number of trusted entries counted from the right of `X-Forwarded-For`, including the desired client entry. For GKE's appended `..., client, load-balancer` suffix this is normally `2`; verify the actual header chain before rollout. Only enable header trust when network policy prevents bypassing the trusted proxy. Otherwise callers can spoof IP-based limits. A missing or malformed required forwarded entry is rejected. Connection caps are per process, not a distributed quota; apply edge rate limits as well.

Prometheus metrics (under the server's `deepbook_api` namespace) cover connected clients, subscriptions by feed, upstream disconnects by endpoint, duplicate/late frames, slow-client disconnects, and upstream envelope lag by feed. Alert on lag above five seconds and on missing lag series after startup. Upstream errors are deliberately not logged verbatim because handshake errors can contain credentials.

Before enabling in production, confirm Pyth quota and public streaming permissions, configure origins and the trusted proxy chain, verify frame timestamps against HTTP history, restart one upstream, test 1,000 browsers per replica with bounded memory, and hold a connection through the real gateway for at least 30 minutes. Check gateway behavior during upstream outages while pings continue. This PR does not change gateway policy, frontend subscriptions, on-chain oracle behavior, or keeper publishing; migrate consumers and decide the on-chain pricing implications before disabling any keeper lane. Roll back by removing `PYTH_WS_ALLOWED_ORIGINS` and restarting the server.
