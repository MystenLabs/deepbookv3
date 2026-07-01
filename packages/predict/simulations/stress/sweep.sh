#!/usr/bin/env bash
# Light capacity sweep: run a list of stress configs serially on ONE worktree, append results to CSV.
# Run two instances (WT1 offset 0, WT2 offset 200) in parallel for 2x throughput.
# Usage: sweep.sh <WT_SIM_DIR> <OFFSET> <CONFIG_FILE> <OUT_CSV>
# CONFIG_FILE lines: LABEL DUP BATCH SINGLE LEV FLUSHAFTER   (FLUSHAFTER="-" = default end-flush)
set -uo pipefail
WT="$1"; OFFSET="$2"; CFG="$3"; OUT="$4"
LOGDIR="$(dirname "$OUT")"
[ -f "$OUT" ] || echo "label,dup,batch,single,lev,flushafter,status,mint_max_u,flush_max_u,detail" > "$OUT"

while read -r LABEL DUP BATCH SINGLE LEV FLUSHAFTER; do
  [ -z "${LABEL:-}" ] && continue
  case "$LABEL" in \#*) continue;; esac
  env_flush=""; [ "$FLUSHAFTER" != "-" ] && env_flush="SIM_FLUSH_AFTER=$FLUSHAFTER"
  log="$LOGDIR/sweep_${LABEL}_off${OFFSET}.log"
  echo "[sweep off$OFFSET] $LABEL: dup=$DUP batch=$BATCH single=$SINGLE lev=$LEV flush=$FLUSHAFTER"
  ( cd "$WT" && env SIM_STRESS_MINT_DUPLICATES="$DUP" SIM_STRESS_MINT_BATCH_SIZE="$BATCH" \
      SIM_STRESS_SINGLE_STRIKE="$SINGLE" SIM_STRESS_LEVERAGE="$LEV" SIM_PORT_OFFSET="$OFFSET" $env_flush \
      bash run.sh --skip-analysis ) > "$log" 2>&1
  # Parse outcome
  inst="$(ls -td "$WT"/runs/*/ 2>/dev/null | head -1)"
  res="$inst/artifacts/results.json"
  status="?"; mintmax=""; flushmax=""; detail=""
  if [ -f "$res" ]; then
    read status mintmax flushmax detail < <(python3 - "$res" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
s=d.get("summary",{}); ba=s.get("byAction",{})
mm=int(ba.get("mint",{}).get("gas",{}).get("max",0))//1000
fm=int(ba.get("flush",{}).get("gas",{}).get("max",0))//1000
print("OK",mm,fm,f"mints={s.get('successfulMints')}")
PY
)
  else
    # failed before results — classify from log
    if grep -q "InsufficientGas" "$log"; then status="OOG"; detail="$(grep -m1 -oE 'flush_after_row_[0-9]+|command [0-9]+' "$log" | tr '\n' ' ')"
    elif grep -q "assert_mint_probability_and_leverage_policy" "$log"; then status="ABORT_levpolicy"; detail="strike-disallows-lev"
    elif grep -q "EMaxActiveLeveragedOrders\|MoveAbort.*liquidation_book.*4" "$log"; then status="ABORT_levcap"; detail="5000-cap"
    elif grep -q "MoveAbort" "$log"; then status="ABORT_other"; detail="$(grep -m1 -oE 'Identifier\("[a-z_]+"\), function: [0-9]+' "$log")"
    else status="FAIL"; detail="$(grep -m1 'Simulation failed' "$log" | head -c 120)"
    fi
  fi
  echo "$LABEL,$DUP,$BATCH,$SINGLE,$LEV,$FLUSHAFTER,$status,$mintmax,$flushmax,$detail" >> "$OUT"
  echo "  -> $status mint_max=$mintmax flush_max=$flushmax $detail"
done < "$CFG"
echo "[sweep off$OFFSET] DONE"
