# predict-bench

Gas benchmarking service for the Predict protocol. Runs simulations against different SHAs and exposes results as Prometheus metrics for Grafana.

## Architecture

```
                          ┌─────────────────────────────────────────────────────────────┐
                          │                    predict-bench (Rust/Axum)                 │
                          │                                                             │
  ┌──────────────┐  POST  │  ┌───────────┐    ┌───────────┐    ┌──────────────────────┐ │
  │ Manual call  │───────▶│  │           │    │           │    │     Runner           │ │
  │ (curl / CI)  │        │  │  Auth     │───▶│  Job      │───▶│                      │ │
  └──────────────┘        │  │  Middleware│    │  Queue    │    │  docker run          │ │
                          │  │           │    │  (mpsc)   │    │  predict-sim:latest   │ │
  ┌──────────────┐  POST  │  │           │    │           │    │         │             │ │
  │ GitHub       │───────▶│  │  Webhook  │───▶│           │    │         ▼             │ │
  │ push hook    │        │  │  Verify   │    │           │    │  ┌─────────────────┐  │ │
  └──────────────┘        │  └───────────┘    └───────────┘    │  │ predict-sim     │  │ │
                          │                                     │  │ container       │  │ │
                          │                                     │  │                 │  │ │
                          │                                     │  │ 1. git checkout │  │ │
                          │                                     │  │ 2. publish pkgs │  │ │
                          │                                     │  │ 3. run sim.ts   │  │ │
                          │                                     │  │ 4. write        │  │ │
                          │                                     │  │   results.json  │  │ │
                          │                                     │  └────────┬────────┘  │ │
                          │                                     │           │            │ │
                          │                                     │      /output vol      │ │
                          │                                     │           │            │ │
                          │  ┌──────────────────┐               │           ▼            │ │
                          │  │ Prometheus Gauges │◀──────────────│  Parse results.json   │ │
                          │  │                   │               └──────────────────────┘ │
                          │  │ mint_gas_total    │                                        │
                          │  │ mint_gas_min/max  │                                        │
                          │  │ update_prices_gas │                                        │
                          │  │ update_svi_gas    │                                        │
                          │  │ mint_latency_ms   │                                        │
                          │  │ run_status        │                                        │
                          │  │ ...               │                                        │
                          │  └────────┬─────────┘                                        │
                          │           │                                                   │
                          │     :9184/metrics                                             │
                          └───────────┼───────────────────────────────────────────────────┘
                                      │
                                      ▼
                          ┌──────────────────┐       ┌───────────┐
                          │  k8s Prometheus  │──────▶│  Grafana  │
                          │  agent (scrape)  │       │ dashboard │
                          └──────────────────┘       └───────────┘
```

## Request Flow

```
1. Request arrives
   POST /api/v1/benchmark { sha, package_id?, network }
   or
   POST /api/v1/webhook/github (push event)
         │
         ▼
2. Auth ─── Bearer token (manual) or HMAC-SHA256 (webhook)
         │
         ▼
3. Enqueue job ─── mpsc channel, sequential per network
         │
         ▼
4. Worker spawns predict-sim container
         │
         ├── Localnet: run.sh (start sui, publish, sim, teardown)
         │
         └── Testnet: sim.ts --execute-only (use provided RPC + package_id)
         │
         ▼
5. Container exits, results.json on shared volume
         │
         ▼
6. Parse results → update Prometheus gauges
   Labels: { sha, package_id, network }
         │
         ▼
7. k8s agent scrapes :9184/metrics → Grafana
```

## API

| Endpoint | Auth | Description |
|----------|------|-------------|
| `POST /api/v1/benchmark` | Bearer token | Trigger benchmark run |
| `GET /api/v1/benchmark/:run_id` | Bearer token | Check run status |
| `POST /api/v1/benchmark/:run_id/started` | Bearer token | Sim job reports start |
| `POST /api/v1/benchmark/:run_id/results` | Bearer token | Sim job posts results |
| `POST /api/v1/benchmark/:run_id/failure` | Bearer token | Sim job reports failure |
| `GET /api/v1/health` | None | Health check |
| `GET :9184/metrics` | None | Prometheus metrics (separate port) |

## Configuration

| Env Var | Required | Default | Description |
|---------|----------|---------|-------------|
| `BENCH_API_TOKENS` | Yes | — | Comma-separated bearer tokens |
| `BENCH_API_PORT` | No | 8080 | API server port |
| `BENCH_METRICS_ADDRESS` | No | 0.0.0.0:9184 | Metrics endpoint address |
| `BENCH_SIM_IMAGE` | No | predict-sim:latest | Docker image for simulation |
| `TESTNET_RPC_URL` | For testnet | — | Testnet RPC endpoint |
| `TESTNET_KEYSTORE_PATH` | For testnet | — | Path to funded keystore |
| `TESTNET_ACTIVE_ADDRESS` | For testnet | — | Testnet signer address |
| `GITHUB_WEBHOOK_SECRET` | For webhook | — | Webhook signature secret |

## Usage

```bash
# Build
cargo build -p predict-bench

# Run
BENCH_API_TOKENS=my-secret-token cargo run -p predict-bench

# Trigger a benchmark
curl -X POST http://localhost:8080/api/v1/benchmark \
  -H "Authorization: Bearer my-secret-token" \
  -H "Content-Type: application/json" \
  -d '{"sha": "cbf6fb5f", "network": "localnet"}'

# Check status
curl http://localhost:8080/api/v1/benchmark/<run_id>

# View metrics
curl http://localhost:9184/metrics | grep predict_bench
```
