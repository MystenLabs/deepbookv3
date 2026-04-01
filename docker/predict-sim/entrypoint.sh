#!/usr/bin/env bash
set -euo pipefail

echo "=== predict-sim (localnet) ==="
echo "SHA: ${SIM_SHA:-HEAD}"
echo "Callback: ${CALLBACK_URL:-none}"

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
