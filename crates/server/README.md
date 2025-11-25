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

**Example Response:**
```json
{
  "status": "healthy",
  "latest_onchain_checkpoint": 12345678,
  "current_time_ms": 1732567890000,
  "max_checkpoint_lag": 5,
  "max_time_lag_seconds": 12,
  "pipelines": [
    {
      "pipeline": "deepbook_indexer",
      "indexed_checkpoint": 12345678,
      "indexed_epoch": 500,
      "indexed_timestamp_ms": 1732567878000,
      "checkpoint_lag": 5,
      "time_lag_seconds": 12
    }
  ]
}
```

**Status Values:**
- `healthy` - Indexer is synced and up-to-date (checkpoint lag < 100, time lag < 60 seconds)
- `degraded` - Indexer is behind or experiencing delays

This endpoint is useful for monitoring the indexer's synchronization status and detecting stale data.