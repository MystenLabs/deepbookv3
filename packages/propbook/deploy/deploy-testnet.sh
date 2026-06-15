#!/usr/bin/env bash
#
# End-to-end testnet deploy for Propbook + its Pyth and Block Scholes oracle lanes.
#
# Does, in order:
#   1. Publish fixed_math            (leaf)
#   2. Publish block_scholes_oracle  (leaf, stub BS verifier)
#   3. Publish propbook              (creates the shared OracleRegistry + RegistryAdminCap)
#   4. create_and_share_pyth_feed              -> shared PythFeed
#   5. create_and_share_block_scholes_feed     -> shared BlockScholesFeed
#   6. bind_pyth_to_underlying  + bind_block_scholes_to_underlying  (admin-gated)
#   7. Read back + verify, then write deployment.testnet.json
#
# Create + bind only: NO observation writes. The Pyth live-write path
# (parse_and_verify_le_ecdsa_update -> pyth_feed::update) is intentionally out of
# scope until the pyth_lazer State id + a signed Lazer payload source are wired in.
#
# Idempotent/resumable: every produced id is persisted to deployment.testnet.json
# (grouped) and reused on re-run. Package publishes are additionally short-circuited
# by each package's committed Published.toml. Delete deployment.testnet.json (and the
# relevant Published.toml) to force a clean redeploy.
#
# The deployer is whatever `sui client active-address` is; the active env MUST be
# testnet. wormhole + pyth_lazer are linked on-chain via propbook's existing
# [dep-replacements.testnet] block — they are never published here.

set -euo pipefail

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROPBOOK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_DIR="$(cd "$PROPBOOK_DIR/.." && pwd)"
FIXED_MATH_DIR="$PACKAGES_DIR/fixed_math"
BS_ORACLE_DIR="$PACKAGES_DIR/block_scholes_oracle"
STATE_JSON="$SCRIPT_DIR/deployment.testnet.json"

# --- Config (env-overridable) ---
EXPECTED_ENV="testnet"
GAS_BUDGET="${GAS_BUDGET:-500000000}"
# propbook's only inputs for the create+bind slice: three u32 identifiers.
PROPBOOK_UNDERLYING_ID="${PROPBOOK_UNDERLYING_ID:-1}"   # canonical "BTC" handle (governance-chosen)
PYTH_SOURCE_ID="${PYTH_SOURCE_ID:-1}"                   # Pyth Lazer feed id (1 = BTC/USD on Lazer)
BS_SOURCE_ID="${BS_SOURCE_ID:-1}"                       # Block Scholes source id (governance-chosen)

SUI="${SUI_BINARY:-$(command -v sui)}"

# --- State (deployment.testnet.json): grouped/nested; the file IS the state ---
# Field naming: package -> *_package_id, signed-data verifier -> *_verifier_package_id,
# shared object -> *_shared_object_id, owned cap -> *_object_id. Group membership +
# ordering below is the single source of truth for the emitted JSON layout.
STATE_PY_GROUPS=$(cat <<'PY'
TOP = ["network", "deployer"]
GROUPS = {
    "packages": ["fixed_math_package_id", "propbook_package_id"],
    "verifier_packages": [
        "block_scholes_verifier_package_id",
        "pyth_lazer_verifier_package_id",
        "wormhole_verifier_package_id",
    ],
    "shared_objects": [
        "oracle_registry_shared_object_id",
        "pyth_feed_shared_object_id",
        "block_scholes_feed_shared_object_id",
        "pyth_lazer_state_shared_object_id",
        "wormhole_state_shared_object_id",
    ],
    "capabilities": ["registry_admin_cap_object_id"],
    "bindings": [
        "propbook_underlying_id", "pyth_source_id", "bs_source_id",
        "pyth_bound", "block_scholes_bound",
    ],
}
PY
)
state_get() {  # key -> value (empty if absent), searching top-level + every group
  [ -f "$STATE_JSON" ] || { echo ""; return; }
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); key=sys.argv[2]
if key in d and not isinstance(d[key], dict):
    print(d[key]); sys.exit()
for v in d.values():
    if isinstance(v, dict) and key in v:
        print(v[key]); sys.exit()
print("")' "$STATE_JSON" "$1"
}
set_state() {  # key value : upsert into its group, rewrite in stable grouped order
  python3 - "$STATE_JSON" "$1" "$2" <<PY
import json, os, re, sys
$STATE_PY_GROUPS
path, key, raw = sys.argv[1], sys.argv[2], sys.argv[3]
val = int(raw) if re.fullmatch(r"-?\d+", raw) else raw
d = json.load(open(path)) if os.path.exists(path) else {}
if key in TOP:
    d[key] = val
else:
    grp = next((g for g, ks in GROUPS.items() if key in ks), "other")
    if not isinstance(d.get(grp), dict):
        d[grp] = {}
    d[grp][key] = val
out = {}
for k in TOP:
    if k in d:
        out[k] = d[k]
for g, ks in GROUPS.items():
    sub = d.get(g)
    if isinstance(sub, dict) and sub:
        out[g] = {k: sub[k] for k in ks if k in sub}
        for k, v in sub.items():
            out[g].setdefault(k, v)
for k, v in d.items():
    if k not in out and k not in TOP:
        out[k] = v
with open(path, "w") as f:
    json.dump(out, f, indent=2)
    f.write("\n")
PY
}

# --- JSON extraction helpers (operate on `sui --json` output on stdin) ---
extract_published_package_id() {
  python3 -c '
import json, sys
d = json.load(sys.stdin)
pub = [c for c in d.get("objectChanges", []) if c.get("type") == "published"]
print(pub[-1]["packageId"] if pub else "")'
}
extract_created_object_id() {  # args: substrings that must all appear in objectType
  python3 -c '
import json, sys
needles = sys.argv[1:]
d = json.load(sys.stdin)
for c in d.get("objectChanges", []):
    ot = c.get("objectType", "")
    if c.get("type") == "created" and all(n in ot for n in needles):
        print(c["objectId"]); break' "$@"
}
published_toml_id() {  # arg: package dir -> testnet published-at, or empty
  local toml="$1/Published.toml"
  [ -f "$toml" ] || { echo ""; return; }
  python3 -c '
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"\[published\.testnet\](.*?)(\n\[|\Z)", t, re.S)
if not m:
    print(""); sys.exit()
pa = re.search(r"published-at\s*=\s*\"(0x[0-9a-fA-F]+)\"", m.group(1))
print(pa.group(1) if pa else "")' "$toml"
}

require() { [ -n "${1:-}" ] || { echo "ERROR: $2" >&2; exit 1; }; }

# Link propbook's already-on-chain git deps (pyth_lazer, wormhole). This toolchain
# resolves a dependency's published address from a Published.toml inside the dep's
# resolved git-cache dir, NOT from the manifest's `published-at` override — so a
# direct dep like pyth_lazer is otherwise reported "unpublished" at publish time.
# We synthesize that Published.toml from propbook's committed [dep-replacements.testnet]
# (addresses) + Move.lock (pinned rev/subdir) so publish links the on-chain packages
# instead of trying to republish them. Requires the deps to be fetched first (build).
link_onchain_deps() {
  local chain_id; chain_id="$("$SUI" client chain-identifier)"
  python3 - "$PROPBOOK_DIR/Move.toml" "$PROPBOOK_DIR/Move.lock" "$chain_id" "$HOME/.move/git" <<'PY'
import glob, os, re, sys
toml, lock, chain_id, gitcache = sys.argv[1:5]
T = open(toml).read(); L = open(lock).read()
m = re.search(r"\[dep-replacements\.testnet\]([\s\S]*)$", T)
blk = m.group(1) if m else ""
wrote = []
for dm in re.finditer(r"(\w+)\s*=\s*\{([^}]*)\}", blk):
    name, body = dm.group(1), dm.group(2)
    pa = re.search(r'published-at\s*=\s*"(0x[0-9a-fA-F]+)"', body)
    oi = re.search(r'original-id\s*=\s*"(0x[0-9a-fA-F]+)"', body)
    if not (pa and oi):
        continue
    pin = re.search(rf"\[pinned\.testnet\.{name}\]\s*source = \{{([^}}]*)\}}", L)
    if not pin:
        print(f"  [warn] {name}: no pinned source in Move.lock"); continue
    rev = re.search(r'rev = "([0-9a-fA-F]+)"', pin.group(1))
    sub = re.search(r'subdir = "([^"]+)"', pin.group(1))
    if not rev:
        print(f"  [warn] {name}: no pinned rev"); continue
    pat = os.path.join(gitcache, f"*{rev.group(1)}*", sub.group(1) if sub else "", "Move.toml")
    hits = glob.glob(pat)
    if not hits:
        print(f"  [warn] {name}: git cache not found ({pat}); run a build first"); continue
    with open(os.path.join(os.path.dirname(hits[0]), "Published.toml"), "w") as f:
        f.write("[published.testnet]\n"
                f'chain-id = "{chain_id}"\n'
                f'published-at = "{pa.group(1)}"\n'
                f'original-id = "{oi.group(1)}"\n'
                "version = 1\n")
    wrote.append(name)
print("    linked on-chain deps:", ", ".join(wrote) if wrote else "(none)")
PY
}

# === 0. Preflight ===========================================================
echo "==> Preflight"
ACTIVE_ENV="$("$SUI" client active-env)"
ACTIVE_ADDR="$("$SUI" client active-address)"
[ "$ACTIVE_ENV" = "$EXPECTED_ENV" ] || {
  echo "ERROR: active env is '$ACTIVE_ENV', expected '$EXPECTED_ENV'. Run: sui client switch --env $EXPECTED_ENV" >&2
  exit 1
}
GAS_TOTAL="$("$SUI" client gas --json 2>/dev/null | python3 -c 'import json,sys; print(sum(int(c["mistBalance"]) for c in json.load(sys.stdin)))' 2>/dev/null || echo 0)"
echo "    env=$ACTIVE_ENV  deployer=$ACTIVE_ADDR  gas=$((GAS_TOTAL / 1000000000)).$(printf '%09d' $((GAS_TOTAL % 1000000000)) | cut -c1-2) SUI"
[ "$GAS_TOTAL" -gt 0 ] || { echo "ERROR: deployer has no gas." >&2; exit 1; }
echo "    propbook underlying=$PROPBOOK_UNDERLYING_ID  pyth_source=$PYTH_SOURCE_ID  bs_source=$BS_SOURCE_ID"

set_state network "$EXPECTED_ENV"
set_state deployer "$ACTIVE_ADDR"
set_state propbook_underlying_id "$PROPBOOK_UNDERLYING_ID"
set_state pyth_source_id "$PYTH_SOURCE_ID"
set_state bs_source_id "$BS_SOURCE_ID"

# Verify propbook builds before spending gas on leaf publishes (also fetches deps).
echo "==> Building propbook (resolves leaves + on-chain pyth/wormhole)"
"$SUI" move build --path "$PROPBOOK_DIR" >/dev/null 2>&1 || echo "    (build deferred until leaves are published)"

# === 1-2. Publish leaf packages =============================================
ensure_leaf() {  # dir, state_key, label
  local dir="$1" key="$2" label="$3"
  local cur; cur="$(state_get "$key")"
  if [ -n "$cur" ]; then echo "    [skip] $label = $cur"; return; fi
  local existing; existing="$(published_toml_id "$dir")"
  if [ -n "$existing" ]; then set_state "$key" "$existing"; echo "    [reuse Published.toml] $label = $existing"; return; fi
  echo "    publishing $label ..."
  local out; out="$("$SUI" client publish --skip-dependency-verification --gas-budget "$GAS_BUDGET" --json "$dir")"
  local pid; pid="$(echo "$out" | extract_published_package_id)"
  require "$pid" "$label publish returned no packageId"
  set_state "$key" "$pid"; echo "    [done] $label = $pid"
}
echo "==> Phase 1: fixed_math"
ensure_leaf "$FIXED_MATH_DIR" fixed_math_package_id "fixed_math"
echo "==> Phase 2: block_scholes_oracle (BS verifier stub)"
ensure_leaf "$BS_ORACLE_DIR" block_scholes_verifier_package_id "block_scholes_verifier"

# === 3. Publish propbook ====================================================
echo "==> Phase 3: propbook"
if [ -n "$(state_get propbook_package_id)" ] && [ -n "$(state_get oracle_registry_shared_object_id)" ] && [ -n "$(state_get registry_admin_cap_object_id)" ]; then
  echo "    [skip] propbook = $(state_get propbook_package_id)"
else
  existing="$(published_toml_id "$PROPBOOK_DIR")"
  if [ -n "$existing" ] && [ -z "$(state_get oracle_registry_shared_object_id)" ]; then
    echo "ERROR: propbook already published ($existing) but registry ids are missing from $STATE_JSON." >&2
    echo "       Restore the deployment json, or delete $PROPBOOK_DIR/Published.toml to republish." >&2
    exit 1
  fi
  link_onchain_deps
  echo "    publishing propbook ..."
  OUT="$("$SUI" client publish --skip-dependency-verification --allow-dirty --gas-budget "$GAS_BUDGET" --json "$PROPBOOK_DIR")"
  PKG="$(echo "$OUT" | extract_published_package_id)";              require "$PKG" "propbook publish returned no packageId"
  REG="$(echo "$OUT" | extract_created_object_id registry::OracleRegistry)";  require "$REG" "OracleRegistry not created"
  CAP="$(echo "$OUT" | extract_created_object_id registry::RegistryAdminCap)"; require "$CAP" "RegistryAdminCap not created"
  set_state propbook_package_id "$PKG"
  set_state oracle_registry_shared_object_id "$REG"
  set_state registry_admin_cap_object_id "$CAP"
  echo "    [done] propbook = $PKG"
  echo "           OracleRegistry = $REG"
  echo "           RegistryAdminCap = $CAP"
fi

PKG="$(state_get propbook_package_id)"
REG="$(state_get oracle_registry_shared_object_id)"
CAP="$(state_get registry_admin_cap_object_id)"

# === 4. Create feeds (permissionless) =======================================
echo "==> Phase 4: create + share feeds"
if [ -n "$(state_get pyth_feed_shared_object_id)" ]; then
  echo "    [skip] PythFeed = $(state_get pyth_feed_shared_object_id)"
else
  OUT="$("$SUI" client call --package "$PKG" --module registry --function create_and_share_pyth_feed \
    --args "$REG" "$PYTH_SOURCE_ID" --gas-budget "$GAS_BUDGET" --json)"
  FID="$(echo "$OUT" | extract_created_object_id pyth_feed::PythFeed)"; require "$FID" "PythFeed not created"
  set_state pyth_feed_shared_object_id "$FID"; echo "    [done] PythFeed = $FID"
fi
if [ -n "$(state_get block_scholes_feed_shared_object_id)" ]; then
  echo "    [skip] BlockScholesFeed = $(state_get block_scholes_feed_shared_object_id)"
else
  OUT="$("$SUI" client call --package "$PKG" --module registry --function create_and_share_block_scholes_feed \
    --args "$REG" "$BS_SOURCE_ID" --gas-budget "$GAS_BUDGET" --json)"
  FID="$(echo "$OUT" | extract_created_object_id block_scholes_feed::BlockScholesFeed)"; require "$FID" "BlockScholesFeed not created"
  set_state block_scholes_feed_shared_object_id "$FID"; echo "    [done] BlockScholesFeed = $FID"
fi

PYTH_FEED="$(state_get pyth_feed_shared_object_id)"
BS_FEED="$(state_get block_scholes_feed_shared_object_id)"

# === 5. Bind feeds to the canonical underlying (admin-gated) =================
echo "==> Phase 5: bind feeds to underlying $PROPBOOK_UNDERLYING_ID"
if [ "$(state_get pyth_bound)" = "1" ]; then
  echo "    [skip] pyth already bound"
else
  "$SUI" client call --package "$PKG" --module registry --function bind_pyth_to_underlying \
    --args "$REG" "$CAP" "$PYTH_FEED" "$PROPBOOK_UNDERLYING_ID" --gas-budget "$GAS_BUDGET" --json >/dev/null
  set_state pyth_bound 1; echo "    [done] pyth bound"
fi
if [ "$(state_get block_scholes_bound)" = "1" ]; then
  echo "    [skip] block_scholes already bound"
else
  "$SUI" client call --package "$PKG" --module registry --function bind_block_scholes_to_underlying \
    --args "$REG" "$CAP" "$BS_FEED" "$PROPBOOK_UNDERLYING_ID" --gas-budget "$GAS_BUDGET" --json >/dev/null
  set_state block_scholes_bound 1; echo "    [done] block_scholes bound"
fi

# === 5b. Record linked on-chain dep references (for the later live-write phase) ==
echo "==> Phase 5b: record on-chain dep references (pyth_lazer / wormhole verifiers + States)"
# Verifier package ids come from propbook's [dep-replacements.testnet]; State object
# ids come from Pyth's committed contract manifest in the git cache. Reference-only;
# the create+bind slice does not consume them, but the Pyth live-write will.
REFS="$(python3 - "$PROPBOOK_DIR/Move.toml" "$HOME/.move" <<'PY'
import glob, json, os, re, sys
toml, move_home = sys.argv[1], sys.argv[2]
T = open(toml).read()
blk = re.search(r"\[dep-replacements\.testnet\]([\s\S]*)$", T)
out = {}
if blk:
    for name, key in (("pyth_lazer", "pyth_lazer_verifier_package_id"),
                      ("wormhole", "wormhole_verifier_package_id")):
        m = re.search(rf"{name}\s*=\s*\{{([^}}]*)\}}", blk.group(1))
        pa = m and re.search(r'published-at\s*=\s*"(0x[0-9a-fA-F]+)"', m.group(1))
        if pa:
            out[key] = pa.group(1)
hits = glob.glob(os.path.join(move_home, "*pyth-crosschain*sui-testnet*", "contract_manager",
                               "src", "store", "contracts", "SuiLazerContracts.json"))
if hits:
    for c in json.load(open(hits[0])):
        if c.get("chain") == "sui_testnet":
            if c.get("stateId"):         out["pyth_lazer_state_shared_object_id"] = c["stateId"]
            if c.get("wormholeStateId"): out["wormhole_state_shared_object_id"] = c["wormholeStateId"]
for k, v in out.items():
    print(f"{k} {v}")
PY
)"
while read -r k v; do [ -n "$k" ] && set_state "$k" "$v"; done <<< "$REFS"
echo "    recorded: $(echo "$REFS" | awk '{print $1}' | paste -sd, -)"

# === 6. Verify ==============================================================
echo "==> Phase 6: verify"
verify_feed_source() {  # object_id, field, expected, label
  local got; got="$("$SUI" client object "$1" --json 2>/dev/null | python3 -c '
import json, sys
v = json.load(sys.stdin).get("content", {}).get(sys.argv[1], "")
print(int(float(v)) if v != "" else "")' "$2")"
  if [ "$got" = "$3" ]; then echo "    [ok] $4 $2=$got"; else
    echo "    [FAIL] $4 $2=$got expected=$3" >&2; return 1; fi
}
verify_feed_source "$PYTH_FEED" pyth_source_id "$PYTH_SOURCE_ID" "PythFeed"
verify_feed_source "$BS_FEED" bs_source_id "$BS_SOURCE_ID" "BlockScholesFeed"
verify_binding() {  # function, expected_feed_id, label
  local got; got="$("$SUI" client call --package "$PKG" --module registry --function "$1" \
    --args "$REG" "$PROPBOOK_UNDERLYING_ID" --dev-inspect --json 2>/dev/null | python3 -c '
import json, sys
co = json.load(sys.stdin).get("command_outputs") or [{}]
rv = co[0].get("returnValues") or []
print(rv[0].get("json", "") if rv else "")' 2>/dev/null || echo "")"
  if [ "$got" = "$2" ]; then echo "    [ok] $3 -> $got"; else
    echo "    [FAIL] $3 getter returned '$got' (expected $2)" >&2; return 1; fi
}
verify_binding propbook_pyth_id_for_underlying "$PYTH_FEED" "pyth binding"
verify_binding propbook_block_scholes_id_for_underlying "$BS_FEED" "block_scholes binding"

# === Done ===================================================================
echo ""
echo "==> Propbook testnet deployment complete."
echo "    State: $STATE_JSON"
python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k,v in d.items():
    if isinstance(v,dict):
        print(f"      [{k}]")
        for kk,vv in v.items(): print(f"        {kk} = {vv}")
    else:
        print(f"      {k} = {v}")' "$STATE_JSON"
