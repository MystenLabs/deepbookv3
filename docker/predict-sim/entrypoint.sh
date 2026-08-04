#!/usr/bin/env bash

LOG_FILE="/tmp/sim.log"

echo "=== predict-sim (localnet) ==="
echo "SHA: ${SIM_SHA:-HEAD}"
echo "Callback: ${CALLBACK_BASE:-none}"

# Helper to POST to a callback endpoint.
callback() {
    local endpoint="$1"
    shift
    if [ -n "${CALLBACK_BASE:-}" ] && [ -n "${BENCH_API_TOKEN:-}" ]; then
        curl -s -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${BENCH_API_TOKEN}" \
            "$@" \
            "${CALLBACK_BASE}/${endpoint}" || true
    fi
}

# JSON-escape a string for safe embedding.
json_escape() {
    node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(d)))'
}

# Report failure with logs on exit.
report_failure() {
    local exit_code=$?
    if [ "$exit_code" -eq 0 ]; then return; fi
    LOGS=$(tail -100 "$LOG_FILE" 2>/dev/null | json_escape)
    callback "failure" -d "{\"error\": \"sim exited with code ${exit_code}\", \"logs\": ${LOGS}}"
    return "$exit_code"
}
trap report_failure EXIT

set -euo pipefail

# Tee all output to log file, including input-contract failures.
exec > >(tee -a "$LOG_FILE") 2>&1

if [ -z "${SCENARIO_PATH:-}" ]; then
    echo "ERROR: SCENARIO_PATH is required" >&2
    exit 2
fi
if [ ! -f "${SCENARIO_PATH}" ]; then
    echo "ERROR: scenario source does not exist: ${SCENARIO_PATH}" >&2
    exit 1
fi

callback "started"

PREDICT_DIR="/workspace/repo/packages/predict"
RESULTS="/tmp/predict-benchmark-results.json"

# Install the shared Predict development-system dependencies.
cd "${PREDICT_DIR}"
npm install
cd /workspace/repo

# Run the localnet benchmark flow. The benchmark service owns the downloaded
# source path and passes it with SIM_MAX_ROWS in the job environment.
PYTHONPATH="${PREDICT_DIR}" python3 -m harness benchmark \
    --source "${SCENARIO_PATH}" \
    --results-output "${RESULTS}"

if [ ! -f "${RESULTS}" ]; then
    echo "ERROR: results.json not found after localnet run" >&2
    exit 1
fi

echo "Results at ${RESULTS}"

# Post results to callback URL if provided.
if [ -n "${CALLBACK_BASE:-}" ]; then
    callback "results" -d @"${RESULTS}"
    echo "Results posted"
else
    if [ -d /output ]; then
        cp "${RESULTS}" /output/results.json
        echo "Results written to /output/results.json"
    else
        cat "${RESULTS}"
    fi
fi
