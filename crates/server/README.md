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