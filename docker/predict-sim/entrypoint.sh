#!/usr/bin/env bash

echo "=== predict-sim (localnet) ==="
echo "SHA: ${SIM_SHA:-HEAD}"
echo "Callback: ${CALLBACK_URL:-none}"

# Report failure to the callback URL on exit.
report_failure() {
    local exit_code=$?
    if [ "$exit_code" -eq 0 ]; then return; fi
    if [ -n "${CALLBACK_URL:-}" ] && [ -n "${BENCH_API_TOKEN:-}" ]; then
        # Replace /results with /failure on the callback URL.
        FAILURE_URL="${CALLBACK_URL%/results}/failure"
        curl -s -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${BENCH_API_TOKEN}" \
            -d "{\"error\": \"sim exited with code ${exit_code}\"}" \
            "${FAILURE_URL}" || true
    fi
}
trap report_failure EXIT

set -euo pipefail

# Report started to the callback URL.
if [ -n "${CALLBACK_URL:-}" ] && [ -n "${BENCH_API_TOKEN:-}" ]; then
    STARTED_URL="${CALLBACK_URL%/results}/started"
    curl -s -X POST \
        -H "Authorization: Bearer ${BENCH_API_TOKEN}" \
        "${STARTED_URL}" || true
fi

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
if [ -n "${CALLBACK_URL:-}" ]; then
    curl -sf -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${BENCH_API_TOKEN}" \
        -d @"${RESULTS}" \
        "${CALLBACK_URL}"
    echo "Results posted to ${CALLBACK_URL}"
else
    # Fallback: copy to /output volume (for local docker run).
    if [ -d /output ]; then
        cp "${RESULTS}" /output/results.json
        echo "Results written to /output/results.json"
    else
        cat "${RESULTS}"
    fi
fi
