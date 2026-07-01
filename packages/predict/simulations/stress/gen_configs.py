#!/usr/bin/env python3
"""Generate 100 stress configs to break the protocol; partition across 6 worktrees.
Config line: LABEL DUP BATCH SINGLE LEV FLUSHAFTER  (sweep.sh format)."""
import random, math, os
random.seed(42)
OUT = os.path.dirname(os.path.abspath(__file__))
cfgs = []
def add(label, dup, batch, single, lev, flush):
    # speed guard: keep PTB count <= 250 so no single sim runs > ~4 min
    ptbs = math.ceil(dup / batch)
    if ptbs > 250:
        batch = max(batch, math.ceil(dup / 250))
    cfgs.append((label, dup, batch, single, lev, flush))

# 1. Flush-OOG boundary (single-strike lev2, end flush) — the brick surface (10)
for dup in [3000,3200,3400,3600,3800,4000,4200,4400,4600,4900]:
    add(f"floog{dup}", dup, 50, 1, 2, "-")
# 2. Batch-amplification curve (single lev2, early flush) (10)
for b in [1,2,3,5,8,15,25,40,75,100]:
    add(f"bcur{b}", 600, b, 1, 2, "1")
# 3. Lev-cap probes (3)
for dup in [5000,5100,5200]:
    add(f"levcap{dup}", dup, 50, 1, 2, "1")
# 4. Node/tree dim (multi-strike lev1) (8)
for dup,b in [(1000,1),(1000,10),(1000,50),(2000,10),(2000,50),(4000,25),(4000,50),(500,1)]:
    add(f"node{dup}b{b}", dup, b, 0, 1, "-")
# 5. Flush-timing (single lev2) (4)
for f in ["1","10","20","40"]:
    add(f"ftime{f}", 2000, 50, 1, 2, f)
# 6. Leverage=3 (admission-dependent; abort-prone but state-building when admitted) (3)
for dup in [500,1000,2000]:
    add(f"lev3_{dup}", dup, 25, 1, 3, "-")
# 7. Edge cases (7)
add("single1mint", 1, 1, 1, 2, "-")
add("batchgtdup", 50, 100, 1, 2, "-")
add("b100_1ptb", 100, 100, 1, 2, "-")
add("dup1_lev1", 1, 1, 0, 1, "-")
add("hugebatch_lowdup", 200, 100, 1, 2, "1")
add("multi_lev1_big", 4000, 50, 0, 1, "-")
add("single_lev1_big", 4000, 50, 1, 1, "-")
# subtotal = 45
# 8. RANDOM FUZZ — corner/unexpected-abort catcher (fill to 100)
i = 0
while len(cfgs) < 100:
    bucket = random.random()
    if bucket < 0.4: dup = random.randint(1,300)
    elif bucket < 0.75: dup = random.randint(300,2500)
    else: dup = random.randint(2500,5200)
    batch = random.choice([1,2,5,10,25,40,50,75,100])
    single = random.choice([0,1])
    lev = random.choice([1,1,2,2,2,3])           # bias lev<=2
    if lev > 1 and random.random() < 0.55: single = 1  # lev>1 multi aborts often
    flush = random.choice(["-","-","1", str(random.randint(1,40))])
    add(f"fuzz{i}", dup, batch, single, lev, flush); i += 1
cfgs = cfgs[:100]

# write master + 6 round-robin chunks (balances fast/slow per worktree)
with open(f"{OUT}/configs_all.txt","w") as f:
    for c in cfgs: f.write(" ".join(map(str,c))+"\n")
POOL = ["w0","w200","w300","w400","w500","w600"]
chunks = {p: [] for p in POOL}
for idx,c in enumerate(cfgs):
    chunks[POOL[idx % 6]].append(c)
for p,cl in chunks.items():
    with open(f"{OUT}/cfg_pool_{p}.txt","w") as f:
        for c in cl: f.write(" ".join(map(str,c))+"\n")
print(f"generated {len(cfgs)} configs")
slow = sum(1 for c in cfgs if math.ceil(c[1]/c[2])>150)
print(f"per-worktree: {[len(chunks[p]) for p in POOL]}  (slow>150PTB: {slow})")
print("sample:", cfgs[0], cfgs[10], cfgs[45], cfgs[-1])
