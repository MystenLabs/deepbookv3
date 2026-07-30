#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREDICT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--skip-analysis" ]; }; then
  echo "run.sh is the external benchmark adapter; use: bash run.sh --skip-analysis" >&2
  echo "For local work use: python3 -m harness parity|campaign|live|smoke" >&2
  exit 2
fi

cd "$PREDICT_DIR"
exec env PYTHONPATH="$PREDICT_DIR" python3 -m harness benchmark \
  --legacy-runs-dir "$SCRIPT_DIR/runs"
