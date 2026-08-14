# Predict Predeploy Open Items

Updated 2026-08-05. This is the live work register governed by the [predeploy lifecycle and update rules](./README.md#lifecycle).

## Deploy Gates

### S-7: Predict cannot resolve a mainnet publication graph

**Severity:** Deploy gate.

Neither `packages/predict/Move.toml` nor `packages/propbook/Move.toml` could
link a mainnet publish: several of the external dependency identities a mainnet
publish needs do not exist. `[dep-replacements.mainnet]` now carries the
resolvable half — `pyth_lazer` and `wormhole`, verified on chain 2026-08-06 —
and `packages/token/Published.toml` already records a mainnet entry. The rest
is open, and none of it is a manifest fix:

- **`bs_oracle` and `bs_sid` are unpublished on mainnet.** The pinned upstream
  revision's publication metadata records testnet only. Closed by the provider
  publishing to mainnet and handing over the package identity, the same
  handover the signer-custody confirmation waits on.
- **`dusdc` has no mainnet counterpart, and the intended mainnet collateral is
  a differently-named type.** `packages/dusdc/Published.toml` is testnet-only
  and records that its `UpgradeCap` is not held here, so it cannot be
  republished to make a mainnet graph resolve. The intended mainnet collateral
  is native USDC —
  `0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC`.
  A `dep-replacements.mainnet` entry cannot express that: a replacement
  substitutes the address only, while Predict names the collateral nominally
  (`use dusdc::dusdc::DUSDC`, ~140 references), and the USDC package publishes a
  single module `usdc` containing no `dusdc::DUSDC`. Closing this means renaming
  the collateral type in source so one module path resolves on both networks —
  which also changes the coin type of the live testnet deployment, and so is its
  own change with its own republish — not a manifest edit.

**Recorded, not blocking: mainnet `pyth_lazer` links version 1 on purpose.**
The lineage has been upgraded — version 2 adds `channel_v2` and `update_v2`,
purely additively — so `published-at` had a choice to make. It links version 1,
because that is the version the pinned source revision describes exactly (its
module set matches, and matches the testnet package already linked) and it is
also the single package id Pyth documents for Sui mainnet. Linking the version
2 head would point the linkage table at bytecode this repo's pinned source does
not describe, for modules Predict does not use. Advancing to version 2 would
mean advancing the source pin — which also serves live testnet — and is only
worth doing if Predict ever needs the `_v2` surface.

**Action:** Do not attempt a mainnet publish while either bullet above is open,
and never resolve one with `--with-unpublished-dependencies`: that
republishes packages this repo does not own and changes their type identity.
Close this gate by recording each identity as it lands, then re-resolving both
manifests against a mainnet environment.

**Adjacent testnet observation, not part of this gate.** The linked testnet
`pyth_lazer` and the deployment Pyth currently documents are both version 1 of
*separate* lineages — Pyth republished rather than upgraded — so the linked
package is superseded though still live. Whether the relayer and the live
testnet deployment should move to the current lineage is an open question for
whoever owns the next testnet republish.

### S-6: The `bs_sid` copy the deployment executes is never the one anything tests

**Severity:** Deploy gate.

The series-id derivation is checked on every edge but the deployed one.
`DirectWsSource` hard-fails a subscription whose acknowledgement does not return
exactly the locally derived ids, so TypeScript-against-provider is verified at
every subscribe; the localnet run signs batches carrying TypeScript-derived ids
and pushes them through `apply_*_batch`, which aborts `ESeriesIdMismatch` unless
they equal the Move derivation, so Move-against-TypeScript is verified by every
green harness run.

Both of those exercise a `bs_sid` the harness publishes itself from the pinned
source. A real deployment links the provider's published package instead, whose
bytecode nothing compares against that source. If the two ever diverge, every
subscription acknowledges, every batch verifies, and ingestion aborts against a
store whose expectations no test has ever read.

Separately unpinned: the `block_scholes_base_asset` bound at
`registry::create_and_share_block_scholes_stores` is checked only non-empty and
is permanent per P-26. A spelling that is wrong but *real* routes another
asset's honestly-signed data into this underlying's markets with every check
passing, on-chain and off, because the series id is correct for what it names.

**Action:** Before a value-bearing deployment, devInspect the created stores'
`spot_sid()` / `forward_sid(expiry)` / `svi_sid(expiry)` and assert they equal
the ids the subscription layer derives. Those getters are `public fun` so an
external caller can ask the chain what it will accept; nothing asks today.
Confirm the bound base asset against the subscription config in the same step
and record the answer, since no code path can.

## Contract Findings

### P-5: BS zero/non-normalizable updates can blank live reads

**Severity:** Low.

The BS stores keep signed values verbatim, including zero: a signed zero spot or
forward prices as `EBlockScholesInputsInvalid` at the pricing envelope until a
newer batch replaces it. Only the registered Block Scholes signer can produce
such a value, so this is a provider-quality residual, not a relayer surface.

**Action:** Restore write-time nonzero guards for BS spot and forward
observations, or document that the provider guarantees this.

**2026-07-07 extension — settlement lane, permanent brick.** The same
write-time normalizability gap reaches settlement, not just live reads. A
non-normalizable exact-expiry Pyth print (negative, normalizes-to-zero,
u64-overflow, or exponent-shift > 18 — `pyth_feed::normalize_raw_spot` returns
none) inserted at `key == expiry_ms` locks that key forever: the exact-history
lane is first-writer-wins with no overwrite/remove (`oracle_lane::insert_at`).
`expiry_market::try_settle` then
returns false permanently and post-expiry live pricing aborts
(`ELivePricingExpired`), so the market never settles and the pool-wide flush
stays bricked. This defeats RP-4's stated recovery (the permissionless exact-ms
insert followed by `try_settle`) — the later valid insert is silently
dropped. Reachability is low for real major-asset feeds but the failure is
permanent.

**Action (extension):** Extend the proposed write-time nonzero/normalizable
guard to the exact-ms settlement insert (reject a raw that cannot produce a
positive normalized spot before it can claim the key), or add an authorized
overwrite/removal for a non-normalizable exact-expiry read; and extend RP-4 to
cover the permanent (not just transient) case.

### P-13: Boundary aggregation can understate positive liability by one raw unit

**Severity:** Low.

The payout tree prices and floors each signed boundary contribution before
netting the aggregate, while an individual order floors its range probability
before multiplying by quantity. Those operation orders are not bit-equivalent.
On a normal monotone constant-variance surface, two one-lot ranges sharing an
upper strike price individually at `463 + 410 = 873` raw DUSDC units, while
`strike_payout_tree::walk_linear` produces `9583 + 9530 - 18241 = 872`. The
aggregate live liability is therefore one raw unit below the sum of the two
order liabilities, and `current_nav` is one raw unit high. This is distinct from
P-11's non-monotone-surface netting failure.

**Action:** Decide whether live liability must reproduce per-order rounding. If
yes, preserve per-range rounded terms in the valuation representation. If not,
bound and accept the aggregation residual in the rounding policy, add a
regression covering both directions, and narrow every exact-NAV claim to the
accepted bound. (2026-07-17 clean-room gap audit)

### P-16: The pricing reference does not cover the deployed variance range

**Severity:** Medium.

The ratified price-deviation bound (`response-policies.md § Pricing and valuation
deviation bounds`) is enforced by the generated pricing reference, so it is only
enforced where that dataset has scenarios. The committed scenario corpus is a
single real market whose total variance bottoms out near `w ≈ 4e-7`, while
deployed one-minute and five-minute cadences reach `w ≈ 1e-8` — the regime where
`1/sqrt(w)` conditioning makes the bound tightest and where an evaluation defect
is least likely to show up anywhere else.

This is what let P-14 (short-dated `up_price` biased by the 1e9 variance
truncation, resolved by the u128/1e18 variance path) reach a release candidate:
every scenario the reference could check sat five orders of magnitude above the
regime that was wrong. The generator now carries one short-dated scenario at the
corpus minimum, which demonstrates the fix but is not coverage — it is one point,
and it does not reach `1e-8`.

**Action:** extend the scenario corpus to span the deployed variance range,
including one-minute and five-minute surfaces, so the deviation bound is checked
where it binds. This needs source rows at those cadences; the current CSV does
not contain them, so it is a data-collection task before it is a generator task.

### P-27: The PLP exit fee ships at 20 bps on a partly-unmeasured basis

**Severity:** Undecided policy. Not a correctness bug — the mechanism is
tested; the open question is whether the rate is right, and whether the leak it
prices is real at all.

A fill at an exact mark is provably value-neutral to incumbents: supplying `D`
into pool value `V` over `S` shares mints `D·S/V`, leaving `V/S` unchanged.
Extraction therefore requires the mark to differ from true recoverable value.
Two facts make that gap non-zero: the certified NAV error is bounded near 1% in
the worst case, and incumbents are involuntary counterparties who cannot
decline a fill or requote it. Whoever chooses when to transact selects against
that error one-directionally.

The counter-argument is that this is ordinary trading, not extraction, and that
a fee only shifts the thresholds a timer needs. That is correct in the limit
where the mark is exact; it is exactly the limit that is not established.

Predict is forward-priced — requests queue before the mark exists — which is
the standard mitigation for the *stale-NAV* form of this problem, so the
residual exposure is mark **error**, not mark **staleness**. That distinction
decides the calibration: the yardstick is the certified error, not the variance
of the share price between flushes.

Shipped state: two independent rates, `plp_supply_fee_rate` (default **0**) and
`plp_withdraw_fee_rate` (default **20 bps**), each in a `0..5%` envelope, charged
on the DUSDC leg of executed fills only and retained by the pool. Both are
admin-tunable to zero without a package upgrade, so shipping enabled is
reversible; widening past 5% is not.

**The basis splits in two, and only one half needs calibrating.**

*Utilization on exit* — the pool's written liabilities do not shrink when an LP
leaves, so the same risk sits on a smaller base and risk per dollar rises for
whoever stays. This needs no adversary and no cleverness, and it is why the
charge belongs on the exit alone: a deposit moves risk the other way. It
justifies a non-zero exit fee on its own, without a measurement.

*Model estimation error* — NAV is cash less what the pool owes, and what it owes
comes from a formula over vendor vol with known mispricing. An active LP can
capture that error at the expense of the LPs who stay. **This is the half that
needs calibrating, and it is what the experiment below is for.** Sizing against
the ~1% certified *arithmetic* bound is the wrong yardstick for it: that bound
is the numerical envelope of the pricer, not the vendor's model error.

The 20 bps default is therefore justified as a floor by the first mechanism and
unvalidated as a ceiling against the second.

**A withdrawer partly refunds their own fee, and the deviation is largest for
the smallest exits.** The charge is retained by the pool, so a withdrawer who is
not fully exiting still owns a share of what they just paid. For a holder of `s`
of `S` shares withdrawing `w` at fee `F`, the net charge is
`F * (1 - post_withdrawal_share)` where the share is `(s - w) / (S - w)`. At
`w = s` the recapture term is exactly zero, so a **full exit pays `F` in full**;
the deviation grows as the exit shrinks relative to what the holder keeps, and
is largest for a holder who still owns much of the pool afterwards. That is the
right direction — the charge bites hardest on the exit that concentrates the most
risk, least on the LP who stays exposed — but any calibration below must target
the *effective* rate at the sizes it is meant to deter, not the nominal one.

The same identity holds on the supply leg, which is one more reason entry ships
at zero: a supplier is a holder the instant the fill lands. Illustrated on that
now-dormant leg, at a 1.0 mark with a 10 DUSDC pool and a 10 DUSDC supply at
20 bps: fee 20_000, shares 9_980_000, post-fill price 20e6/19.98e6, so the new
holding is worth 9_989_989 and the net charge is 10_011 — just over half. In
closed form that is `F * V / (V + n - F)` for a deposit `n` into a pool worth
`V`, equivalently `F * (1 - post_fill_share)`.

**The split roughly halves the shipped cost of the strategy this item exists to
measure.** A round trip costs `F_in * (1 - share) + F_out`; with `F_in = 0` as
shipped that is now just `F_out`, so the timing loop pays a flat 20 bps rather
than the ~40 bps a symmetric 20 bps would have charged a small LP. A pure
outside timer — deposit, wait a flush, exit fully — recaptures nothing on either
leg and pays exactly the nominal exit rate. The measurement below must be read
against that figure, not against the symmetric one the item was first written
for.

**Experiment plan** (decision rule written before the run):

- **Question:** does the realized fill mark deviate from a higher-precision
  reference NAV at fill time, in a direction a submitter can predict at
  *submit* time?
- **Strategy:** drive supply/withdraw against a live book while recording, per
  flush, the realized mark, the reference NAV, and the information available
  one flush earlier. Measure realized round-trip PnL of a timing strategy at
  both LP fee rates at 0, net of gas and a flush of escrow lockup.
- **Blocked on:** the Python parity oracle still models scalar NAV, so there is
  no independent reference to difference the realized mark against. Closing
  that gap is the first step, not the experiment. It also does not model this
  fee at all (`simulations/python_replay.py`, marked in-file), so parity runs
  must stage both LP fee rates at 0 until someone derives the fee independently
  there — copying the Move formula across would make the oracle a mirror of the
  code it is supposed to check.
- **Decision rule:** if zero-fee round-trip PnL is not distinguishable from
  zero at the observed flush cadence, set the default to 0 and keep the knob.
  If it is positive, set the rate above the measured per-lap edge and record
  the measurement as the basis. Either outcome graduates to
  `response-policies.md`; "it feels safer with a fee" does not.

**Note:** the measurement depends on the flush cadence, which is itself
unsettled — the keeper default and this repo's design record disagree, and
every per-day figure in the discussion moves with it. Settle the cadence before
running, or the result is not interpretable.

### P-28: The pricing reference's tolerances predate the difference-of-logs change

**Severity:** Low. Not a correctness bug — every committed reference point still
passes and worst-case budget usage is unchanged at 61%. The defect is that the
tolerances are now conservative by luck rather than derived.

`generate_pricing_reference.py` derives every tolerance analytically from
`math.move`'s documented per-primitive budgets, and its `d_k` term has been
corrected to the difference-of-logs form (`1e-7·(|ln strike| + |ln forward|) +
2/F`) that RP-26 shipped. The committed `pricing_reference_data.move` was
generated under the previous ratio model (`1/F/ratio + 1e-7·|k| + 1/F`), which
understates the current implementation by roughly 6x near the money — the old
model's `1e-7·|k|` term vanishes at the money, while two `ln` evaluations do not.

Regeneration needs `simulations/data/scenario_dataset.csv`, which is gitignored
and absent from a fresh worktree, so it could not be done in the same change.

**Action:** regenerate the reference data with the dataset present and confirm
the budgets still bound the observed deviations. Until then the file's stated
contract — "propagated from `math.move`'s documented per-primitive budgets" — is
true of the generator but not of the committed data.

### P-29: Settlement has no fallback when no admissible print exists at a boundary

**Severity:** High for any non-24/7 underlying; otherwise an unmeasured tail
with an unbounded consequence. Launch blocker before listing a session-traded
asset.

Settlement reads one exact key. `try_settle` calls `load_exact_spot_read` at
`market.expiry`, and the only way to fill that key is
`pyth_feed::insert_at`, which requires an envelope stamped at exactly that
millisecond carrying a price generated no more than
`constants::max_settlement_carry_ms` (2s) earlier. The lane is insert-only:
`oracle_lane::insert_at` ignores an occupied key without aborting, and there is
no overwrite or removal.

So a boundary has no admissible settling row, permanently, in either of two
states:

- **Empty.** Price generation gapped across the boundary by more than the carry
  window, so every envelope at that millisecond is rejected
  (`ESettlementCarryExceedsWindow`).
- **Poisoned.** The first lane-valid observation to claim the key has no
  normalized projection (`pyth_feed::normalize_raw_spot` returns none on a
  negative price, a `scale_up` overflow, a negative exponent shifted more than
  18, or a price that rounds to zero). The doc comment on `insert_at` states
  the consequence directly: the first lane-valid raw observation owns the key
  and cannot be replaced, even if its normalized projection is unavailable.

Either way `try_settle` returns false forever, post-expiry live pricing aborts
`ELivePricingExpired`, and RP-4's response — abort the flush and retry — never
terminates. RP-4 records this ("Recovery is not guaranteed", risk profile
`UNMEASURED` for the unrecoverable case) and its reopen clause names the
remedy: an admin settlement fallback. This item is that remedy.

**Why this is not only a tail.** For a 24/7 crypto underlying the trigger is an
unmeasured generation-gap tail. For a session-traded underlying — equities,
futures, FX, metals — a grid boundary landing in a closed session carries from
beyond the window *by construction*, so the failure is certain rather than
probabilistic. Listing any such asset without this item resolved ships a known
permanent pool-wide brick.

**Two properties any fallback must preserve.**

1. **It must not weaken `insert_at`.** First-writer-wins on the oracle lane is
   what stops a permissionless caller from rewriting settlement history. The
   fallback therefore records a settlement price on the market and must not
   mutate or remove a lane row.
2. **It must not become an admin price lever.** RP-4 refuses a substitute
   *mark* because an unsettled market has no well-defined value. A fallback
   avoids that objection only by actually settling the market, and only when
   normal settlement provably cannot — so the arming condition has to be
   objective and on-chain checkable, never discretionary.

**Proposed design — two layers, the second only if the first cannot fire.**

*Arming condition (both layers).* `clock.timestamp_ms() >= expiry +
settlement_grace_ms`, and the exact key is either unfilled or holds a read with
no normalized projection. Normal settlement always wins inside the grace
window; the fallback is unreachable for any market that could still settle
normally.

*Layer 1 — deterministic widened reach, permissionless, no discretion.* Settle
from the nearest admissible normalized print within a compiled
`fallback_reach_ms` of the boundary, nearest-preceding first, ties to the
earlier timestamp. Fully determined by lane contents, so any caller computes
the same answer and no attestation is needed. This is the layer that answers
the crypto generation-gap case and the poisoned-key case, because it reads past
the poisoned key rather than replacing it. It deliberately relaxes the
"defensible mark for that tick" property the carry bound protects, which is
exactly why it sits behind the arming condition.

*Layer 2 — attested settlement under a timelock, only when layer 1 finds
nothing.* An `AdminCap` holder proposes a settlement price; the market enters a
published `challenge_window_ms` during which it is flagged and settlement is
not yet recorded; the price takes effect when the window elapses. The check on
a wrong price is the window plus the existing protocol freeze, not an on-chain
dispute mechanism — worth stating plainly rather than calling it a challenge
process it is not. This is the layer that answers the session-closure case,
where no print exists within any defensible reach, and it is the layer that
carries a real trust decision.

**What this buys even before layer 2.** Today the flush block is unbounded.
With the arming condition alone it becomes bounded by `settlement_grace_ms`
plus the reach lookup, which converts a permanent pool-wide brick into a
delay of known length.

**Action:** Decide whether layer 2 is in scope for launch or whether launch is
restricted to 24/7 underlyings with layer 1 only, then implement and graduate
the decision to `response-policies.md` as an entry resolving this item and
reopening RP-4. Publish the rule before launch, not during an outage. Pinning
tests to carry: arming refused inside the grace window; arming refused when the
exact key holds a normalizable read; layer 1 settling across an empty key;
layer 1 settling across a poisoned key without mutating it; layer 1 refusing
beyond `fallback_reach_ms`; and, if layer 2 ships, no effect before the window
elapses.

### P-30: The C-1 capacity model is one measurement behind the pricing path

**Severity:** Low, but it compounds. Not a defect; a stale measurement.

RP-26 added one `ln` evaluation per digital and removed one `try_mul_div_down`.
`walk_linear` pays that per payout-tree node and the pool-wide flush prices every
active market in one PTB, so the increment lands directly on the C-1 computation
budget — last measured at ~51% of the wall.

Precedent for sizing it: `evidence/c1-skew-gas-2026-07-09.md` records that the
previous comparable addition (one `normal_pdf`, i.e. one `exp`) cost +2.2%
per-order flush slope and +3.3% at a full book. An `ln` is of similar cost, so a
comparable increment is expected — not near a cliff, but unmeasured. Move
unit-test metering put the difference under 0.01% of a test's gas; that is not
on-chain compute and should not be cited as the answer.

**Action:** fold a re-measurement into the next localnet capacity campaign rather
than running one for this alone, and refresh the C-1 figures.

### P-31: A provider envelope ahead of the Sui clock silently empties the feed

**Severity:** Medium; liveness, misattributed failure.

`block_scholes_store::apply` returns `false` rather than aborting when
`published_at_ms > recorded_at_ms` — the batch's envelope time is ahead of the
Sui `Clock` at execution. The transaction still succeeds, so the relayer sees
success, and the only signal is `applied` reading below `update_count` in
`BlockScholesBatchIngested`. Skipping is the right response for one unusable
entry, but this particular condition is not per-entry: the provider's publish
clock and the Sui checkpoint clock are independent, so a provider running even
slightly ahead at relay latency fails *every* observation in *every* batch. The
feed then looks like it is ingesting while nothing is ever stored, and pricing
halts a freshness window later on `EBlockScholesPriceStale` — an error naming
provider staleness for what is actually clock skew on our side of the boundary.

The comparison has a real duty and is not simply removable: accepting a
future-dated envelope would let that observation win the `(model, published)`
ordering against every honest later batch at equal model time, pinning the
series until its model time advances.

**Action:** Measure the observed `published_at_ms - recorded_at_ms` distribution
against the live provider before a value-bearing deployment, and alert on
`update_count > 0 && applied == 0` sustained across consecutive batches, which
is what distinguishes this from a genuinely quiet feed. If the observed margin
is thin, decide the response deliberately — a bounded tolerance on the
comparison is a `response-policies.md` decision, not a silent widening.

## Access and Governance

### G-1: Root admin caps have no on-chain revocation or rotation

**Severity:** Deploy decision.

The three root caps — predict `AdminCap`, propbook `RegistryAdminCap`, and
account `AccountAdminCap` — have no on-chain revoke or rotate path (contrast
predict's `registry::revoke_pause_cap` / `revoke_lifecycle_cap`).
Coupled exposures:

- A leaked `AccountAdminCap` is an unrecoverable path to draining all user
  custody: it authorizes apps (`authorize_app`), and account app-auth is
  generic — any co-authorized app can call public `account::withdraw` on any
  predict user's wrapper. `account::load_account_mut` intentionally grants a
  valid `Auth` unrestricted mutable account access, but the deploy-time
  authorization hygiene and the cap-compromise recovery are not an explicit
  item.
- The propbook `RegistryAdminCap` is a *separate* admin domain that can rebind
  an underlying's oracle (`registry::replace_pyth_binding_for_underlying`),
  instantly redirecting and stranding pricing AND
  settlement of all in-flight predict markets, with no timelock and no
  predict-side detection.

**Action:** Before a value-bearing deploy, choose root-cap custody and recovery:
multisig custody plus a rotation/replacement mechanism for each non-rotatable
root cap, or documented acceptance of the cap-compromise and cross-package admin
trust coupling.

## Capacity and Liveness Findings

### C-1: Full-pool flush has no joint valuation budget

**Severity:** Medium / must be accepted or fixed before deployment.

The flush values every active market in one PTB. Current independent caps
(`24` live markets, `1000` payout nodes) do
not compose into a single-PTB budget — and the binding limit is object-count,
not compute (corrected 2026-07-07; see the model below). The NAV price memo
removed the single-market pre-cap OOG; the remaining deploy blocker is the
pool-total case. The missing bound is a joint sum across all active markets, not
another isolated per-market cap.

**Capacity model (corrected 2026-07-07 — the binding wall is object-count, not compute):**

- The binding wall for the pool total is the Sui **object-runtime cached-objects
  limit: 1,000 dynamic-field child objects per transaction**
  (`object_runtime_max_num_cached_objects`; a protocol constant, taken as
  network-invariant). The flush loads each market's payout-tree nodes as
  dynamic-field children, and the object-runtime cache
  **accumulates across every `value_expiry` command in the one PTB**. On overflow
  it aborts `MEMORY_LIMIT_EXCEEDED` inside `dynamic_field::borrow_child_object` —
  a framework error whose true cause is this limit. It binds at 16–50% of the 5M
  compute cap, so the pool flush is object-count-bound, not computation-bound
  (`evidence/c1-object-cache-flush-2026-07-07.md`).
- Driver = distinct payout-tree nodes: one `Table<tick,PayoutNode>` child per
  distinct strike tick, and `walk_linear` loads every node. Node count = distinct
  ticks, NOT order count (the tree aggregates by boundary) — which is why
  single-market runs at narrow strikes never reached it despite large books.
- Confirmed cumulative, not per-command: two 1× markets at 586 nodes each —
  neither near 1,000 — abort the flush at ~1,172 combined; a single 1× market
  crosses at ~982 nodes (`evidence/c1-object-cache-flush-2026-07-07.md`).
- Superseded conclusion: the 2026-07-01 model called the flush
  computation-bound. That holds for the SINGLE market (a full 5,000-order book
  values at ~47–54% of the compute cap, `evidence/c1-price-memo-2026-07-01.md`;
  pre-memo that single market OOG'd at ~4,580 orders,
  `evidence/c1-nav-stress-2026-06-30.md`) but not the pool total. Earlier
  pool-total runs hit
  `expiry_cash::EInsufficientCash` (capital) at ~92% compute before reaching the
  object wall; raising the allocation cap removed that mask and exposed the
  1,000-child limit.
- Skew-adjusted pricing re-measured the single-market compute cost on 2026-07-09:
  the per-order flush slope rose 2.2% (~480K → ~491K computation units) and a
  full 5,000-order book used 51% of the compute wall. This does not change the
  pool-total conclusion above: the object-cache limit binds first
  (`evidence/c1-skew-gas-2026-07-09.md`).
- Expired-unswept markets leave the active set only inside a successful
  `value_expiry`/sweep, so the flush's active tail is not bounded by the
  live-market creation cap.
- Capacity law:
  `sum_over_active_markets(distinct_ticks + base_children)
  < 1,000 dynamic-field children per flush PTB` — a joint sum across all active
  markets, dominated by distinct strike ticks.
- Leverage removal (2026-08-14) deleted the `ceil(leveraged_orders / 64)`
  liquidation-book term from this law and the 5,000-order cap that bounded it.
  Every measured threshold above was taken with leveraged orders present, so the
  numbers are now conservative for the object wall and stale for compute; they
  must be re-measured against the 1x-only footprint before this item is closed.
  The benchmark cannot do that until the simulation parity model is updated.

**Fix options (reframed for the object-count wall):** shrink the per-market
NAV-walk child footprint (e.g. cache tree aggregates so `walk_linear` need not
load every node) · a joint active-market×node budget enforced at creation/roll ·
valuation resumable across PTBs (partial state instead of a hot potato) · an
out-of-flush settled sweep/deactivate path (bounds the active tail) · documented
operator throttling (an off-chain acceptance, not an on-chain guarantee).

**Plan — runs that finish the number (decision rules pre-registered
2026-07-02):**

The binding wall is now identified (object-cache, 2026-07-07 above); the compute
runs below are superseded for the pool total (compute is not the wall), and what
remains open is the FIX, not the measurement. Retained for context:

- Historical payout-tree probes — DONE 2026-07-07: filling one 1× market to the node cap
  and two markets to 586 each proved the pool-total wall is the object-runtime
  cached-objects limit, cumulative across the PTB, not compute
  (`evidence/c1-object-cache-flush-2026-07-07.md`). The `c_node`/compute terms are
  moot for the pool total — object count binds first.
- Historical worst-branch and pool-total compute probes are superseded by the object-count result above, and their one-off strategy files were retired. If a fix needs a fresh boundary measurement, extend the retained `packages/predict/harness/ts/strategies/capacity.ts` family rather than restoring the old probes.
- Any final cap change is followed by one run that reaches the new boundary
  and proves the flush stays under the safety target.

## Oracle Calibration

### O-1: Near-expiry oracle miscalibration is exploitable

**Severity:** High if near-expiry markets are enabled without recalibration.

Offline and on-chain tests found high-priced near-expiry binary contracts
systematically underpriced and low-priced contracts systematically overpriced.
See `evidence/o1-oracle-calibration.md`.

**Action:** Recalibrate near-expiry volatility/time-to-expiry behavior or block
the affected near-expiry market shape until the reliability curve is verified.

## Maintainability and Pre-Deploy Hygiene

These are free to fix pre-deploy and breaking (or permanent) after; none block
correctness today.

### H-3: Smaller cleanup items

- The store tables have no pruning path: every expiry ever quoted leaves a
  permanent row in `values`/`svis`, and neither store can be unwrapped (`key`
  only). Reads stay O(1), so this is unreclaimable storage rather than a
  liveness risk, but it grows monotonically for the life of the deployment.
- `fee_incentive_balance` DUSDC custody sits on `ExpiryMarket` outside the
  `ExpiryCash` solvency invariant — consider folding it into the custody
  component so per-expiry DUSDC has one owner.
- The store pair could be one object. The verifier's two batch types force two
  typed entry functions, not two stores; a single store would drop
  `BlockScholesStorePair`, one registry id, one of the two binding checks in
  `pricing::assert_current_oracles`, and the duplicated
  `block_scholes_base_asset` field whose two copies agree only by construction
  and can never be checked against each other on-chain.
- Every series id is scoped to the verifier package id
  (`type_name::original_id<PackageMarker>()`), so repointing Propbook at a new
  `bs_oracle` publication rotates the entire identity space at once: stored rows
  go dead and unprunable, and reads fail closed with no error distinguishing it
  from a stopped feed. The revision bump in this cutover already moved it once.
  Deployment procedure should treat a verifier repoint as feed re-provisioning
  rather than a configuration change.
- The upstream publication metadata records a live `UpgradeCap` for `bs_sid`.
  Sui pins linkage at publish, so a provider-side upgrade cannot move Propbook's
  derivation on its own, but a future Propbook upgrade rebuilt against a newer
  revision would, silently. Upstream's manifest states nothing there depends on
  retaining the capability, and the burn commitment obtained for the verifier
  package does not cover this one — worth asking for it.

### H-6: Maintainability backlog

- Thread the cadence value group (tick_size, admission_tick_size,
  max_expiry_allocation, initial_expiry_cash, window_size) as a named
  `CadenceParams` struct instead of a 5-long u64 run through
  registry → market_manager → event; reshapes the public
  `set_template_cadence_config` signature, so coordinate with the positional TS
  callers.
- `expiry_market` god-module decomposition (trade sequencing / fee decomposition
  / payment settlement / lifecycle in one 1170-line module) — decide a seam or
  consciously accept before the codebase grows further.
  probe; needs a raw liquidate builder (`ctx.submitLiquidate`) in the harness.

### H-7: Test-coverage gaps from the PR #1097 review

From the 2026-07-02 full-PR review (all Low; strengthenings, not blockers).

- **RP-3 clamp not directly pinned.** No flush test exercises the sticky-exclusion
  clamp's own trigger (held-out total > a positive-then-collapsed gross). Add a
  flush test that latches positive profit-basis credits (settle a profitable
  market), withdraws idle, then collapses the remaining active mark so
  `exclusion + pending > gross`, and asserts the flush still succeeds at NAV==0.
- **Cadence public-read surface uncovered.** The `market_manager` cadence-config
  getters are retained for SDK and dev-inspect consumers but have zero direct
  test coverage; cover the external values and the enabled/disabled projection.
- **`pricing` forward-absence branch untested.** `EBlockScholesPriceUnavailable`
  is pinned for the spot-absence path but not the forward-absence path; add the
  missing `expected_failure`.
- **One-sided boundary/receiving-side assertions.** The drain rounds-to-zero
  boundaries are tested only on the aborting side; the all-in `max_cost` boundary
  pair (from the now-resolved H-2 fix) pins only a 2-of-4-component decomposition
  (zero builder fee / subsidy). Strengthen each to assert the passing boundary.
  (`unstake_deep` receiving-side assertion — that the account received the DEEP —
  added on PR #1106.)
