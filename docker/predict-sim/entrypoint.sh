#!/usr/bin/env bash

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

# Report failure on exit.
report_failure() {
    local exit_code=$?
    if [ "$exit_code" -eq 0 ]; then return; fi
    callback "failure" -d "{\"error\": \"sim exited with code ${exit_code}\"}"
}
trap report_failure EXIT

set -euo pipefail

callback "started"

SIM_DIR="/workspace/repo/packages/predict/simulations"

# Install simulation dependencies.
cd "${SIM_DIR}"
npm install
cd /workspace/repo

# Run the full localnet simulation (setup + sim, skip python analysis).
bash "${SIM_DIR}/run.sh" --skip-analysis

# Find results.
LATEST_RUN=$(ls -td "${SIM_DIR}"/runs/*/ 2>/dev/null | head -1)
if [ -z "${LATEST_RUN}" ] || [ ! -f "${LATEST_RUN}/artifacts/results.json" ]; then
    echo "ERROR: results.json not found after localnet run" >&2
    exit 1
fi

RESULTS="${LATEST_RUN}/artifacts/results.json"
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
