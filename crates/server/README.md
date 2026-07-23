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

## Pyth Hermes proxy

The server exposes the two authenticated Pyth Hermes reads used by DeepBook
clients:

- `GET /pyth/v2/updates/price/latest`
- `GET /pyth/v2/updates/price/:publish_time`

The routes preserve Hermes query parameters, response bodies, status codes, and
the `Content-Type`, `Cache-Control`, and `Retry-After` response headers. Existing
`@pythnetwork/hermes-client` consumers can therefore use the DeepBook Server by
setting their Hermes base URL to `<deepbook-server>/pyth`.

Configure the server with:

- `PYTH_API_KEY` — Pyth API key injected into upstream requests as a bearer
  token. The proxy routes return HTTP 503 when it is absent. Authenticated
  Hermes access becomes mandatory on August 18, 2026.
- `PYTH_HERMES_URL` — optional upstream base URL; defaults to
  `https://pyth.dourolabs.app/hermes`.
- `PYTH_LATEST_CACHE_TTL_MS` — latest-price response lifetime; defaults to
  `1000` milliseconds.
- `PYTH_HISTORICAL_CACHE_TTL_SECS` — historical-price response lifetime;
  defaults to `300` seconds.
- `PYTH_CACHE_MAX_ENTRIES` — maximum responses cached per server process;
  defaults to `1024`. Set to `0` to disable response caching.

Requests are cached by their exact Hermes path and query string. Concurrent
identical cache misses share one upstream request (single-flight loading).
Only successful upstream responses are cached, so rate limits and service
errors are always retried on the next request. The cache is local to each
server process; deployments with multiple replicas maintain independent
caches.

The API key must stay in server/deployment secrets and must never be sent to a
browser. Example:

```bash
curl \
  "http://localhost:9008/pyth/v2/updates/price/latest?ids[]=0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43&parsed=true"
```
