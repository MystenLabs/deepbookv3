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

The server exposes Hermes-like HTTP GET routes backed by authenticated Pyth Pro
[Router API](https://pyth-lazer-0.dourolabs.app/docs/openapi.json) requests:

- `GET /pyth/v2/updates/price/latest`
- `GET /pyth/v2/updates/price/:publish_time`

Both routes accept repeatable numeric Pyth Pro feed IDs in `ids[]`, plus
`parsed=true` and optional `ignore_invalid_price_ids=true`. The historical path
uses a Unix timestamp in seconds; the server converts it to the microsecond
timestamp required by Pyth Pro. Responses deliberately provide only the parsed,
Hermes-like price fields used by DeepBook. They do not contain signed Hermes or
Pyth Pro binary payloads and are not intended for on-chain price updates.

Configure the server with:

- `PYTH_PRO_API_KEY` — bearer token for Pyth Pro. It is read directly from the
  environment and must remain in deployment secrets.
- `PYTH_PRO_URL` — optional Router API base URL; defaults to
  `https://pyth-lazer-0.dourolabs.app/v1`.
- `PYTH_PRO_FEED_IDS` — comma-separated numeric feed IDs the public routes are
  allowed to serve and the background task refreshes. Other IDs are rejected
  unless `ignore_invalid_price_ids=true`.
- `PYTH_PRO_POLL_INTERVAL_MS` — latest refresh interval; defaults to `1000`.
- `PYTH_PRO_MAX_STALENESS_MS` — maximum age of the latest successful snapshot;
  defaults to `5000`.
- `PYTH_PRO_HISTORY_CACHE_TTL_SECS` — historical entry lifetime; defaults to
  `86400`.
- `PYTH_PRO_HISTORY_CACHE_MAX_ENTRIES` — maximum historical
  `(feed_id, timestamp_us)` entries per process; defaults to `10000`.

One background task requests all configured latest feeds in a single Pyth Pro
call every polling interval, then atomically publishes the parsed snapshot.
Latest HTTP requests only read that snapshot and never call Pyth. Historical
prices use a bounded Moka cache keyed by numeric feed ID and microsecond
timestamp. A request containing several IDs fetches all cache misses in one
Pyth Pro call, and concurrent requests for the same timestamp share the load.
Errors and rate limits are not cached.

The familiar route and query shape is intended to make migration simple, but
the parsed-only response is not a drop-in replacement for
`@pythnetwork/hermes-client`; callers should use a normal HTTP client.

### Run locally

With the server's Postgres database available at `DATABASE_URL`, start it from
the repository root:

```bash
export DATABASE_URL="postgres://postgres:postgrespw@localhost:5432/deepbook"
export PYTH_PRO_API_KEY="<your-api-key>"
export PYTH_PRO_FEED_IDS="1,2"
cargo run -p deepbook-server
```

Keep the real API key in your local environment or secret manager; do not add
it to the repository. The latest-price route returns `503` until the first
background refresh succeeds.

Example, using numeric Pyth Pro feed IDs `1` and `2`:

```bash
curl \
  "http://localhost:9008/pyth/v2/updates/price/latest?ids[]=1&ids[]=2&parsed=true"

curl \
  "http://localhost:9008/pyth/v2/updates/price/1700000000?ids[]=1&parsed=true"
```
