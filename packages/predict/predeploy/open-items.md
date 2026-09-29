# Predict Predeploy Open Items

Updated 2026-08-17. This is the live work register governed by the [predeploy lifecycle and update rules](./README.md#lifecycle).

## Deploy Gates

### S-7: Mainnet publication verification and gas plan

**Severity:** Deploy gate.

Mainnet manifests select Circle's native USDC source, Pyth Lazer v2 (retaining its original type identity), Wormhole, and the published Block Scholes verifier/SID revision. Mainnet DeepBook v8 and Testnet DeepBook v20 consumers select the [shared DEEP reconstruction](../../../vendor/deep/README.md) with their separate existing token identities. The package pins are owned by `packages/{predict,propbook,deepbook_core_account,sessions}/Move.toml`.

The remaining gates are:

- The [deployment workflow](../deployment/README.md#execution-gates) requires exact dependency source verification with the pinned build compiler, Circle/Wormhole/DEEP reproduction compiler, Mainnet Pyth generated metadata, and Mainnet Wormhole source. A publication dry run alone proves linkage/execution compatibility, not source equality; every execution rechecks the full dependency closure and live framework.
- The complete Mainnet publication/wiring gas plan must be measured before lowering the conservative per-step caps.

Pyth Mainnet must link v2: the live State's version guard rejects v1 even when the consumed Update ABI exists in both versions. Migrating to the distinct newer Testnet lineage is outside this deployment scope. No upstream Block Scholes publication is required; its Mainnet identities already exist.

**Action:** Resolve these checks before Mainnet execution. Do not republish external packages or use `--with-unpublished-dependencies`. Keep S-6's live SID/base-asset validation as a separate deployment requirement.

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
upper strike price individually at `463 + 410 = 873` raw USDC units, while
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
deployed one-minute and five-minute cadences reach `w ≈ 1e-8`, and SSVI
one-minute slices `w ≈ 2e-9` — the regime where
`1/sqrt(w)` conditioning makes the bound tightest and where an evaluation defect
is least likely to show up anywhere else.

This is what let P-14 (short-dated `up_price` biased by the 1e9 variance
truncation, resolved by the u128/1e18 variance path) reach a release candidate:
every scenario the reference could check sat five orders of magnitude above the
regime that was wrong. The generator now carries one short-dated scenario at the
corpus minimum, which demonstrates the fix but is not coverage — it is one point,
and it does not reach `1e-8`.

Partly addressed: `generate_ssvi_reference.py` carries real one-minute,
one-to-five-minute, and sub-hour Block Scholes SSVI slices down to `w ≈ 2e-9`,
checked two ways. At each slice's real forward the quoted strike is the forward,
where the contract's log-moneyness is exactly zero, and the budgets are a few
thousand raw units. The same SVI shapes seeded at a forward of 1.0, where
`ln(forward)` is exactly zero, are quoted around the smile at budgets of 7.6e-7
to 7.5e-5 absolute, which certifies the 0.1% relative bound for prices above
about 7.5 cents. What stays uncertified is off-forward strikes at real BTC price
levels: there the budget carries `ln`'s documented 1e-7 relative bound per term,
about 2e-6 in `k`, which against `sqrt(w) ≈ 1e-4` is roughly a cent of
probability, however accurate the contract is. The contract's `ln` is far closer
than that, except at its normalization seams: at `x = 2^n · 1e9` its error steps,
for example 22 raw units low at `131_071.999999999` against 10 low at `131_072`, a
12-unit jump in `k` between adjacent strikes that moves a one-minute `$1` range
priced across it by about 0.15% relative.

**Action:** derive a bound on `ln(strike) - ln(forward)` tight enough for
off-forward short-dated strikes at real price levels — a tighter documented `ln`
bound backed by `math_tests`, or a bound on the difference of two nearby
logarithms — and extend the unit-forward coverage to the low-price band the
current budgets do not certify.

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
on the USDC leg of executed fills only and retained by the pool. Both are
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
now-dormant leg, at a 1.0 mark with a 10 USDC pool and a 10 USDC supply at
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
`packages/fixed_math/sources/math.move`'s documented per-primitive budgets, and its `d_k` term has been
corrected to the difference-of-logs form (`1e-7·(|ln strike| + |ln forward|) +
2/F`) that RP-26 shipped. The committed `pricing_reference_data.move` was
generated under the previous ratio model (`1/F/ratio + 1e-7·|k| + 1/F`), which
understates the current implementation by roughly 6x near the money — the old
model's `1e-7·|k|` term vanishes at the money, while two `ln` evaluations do not.

Regeneration needs `simulations/data/scenario_dataset.csv`, which is gitignored
and absent from a fresh worktree, so it could not be done in the same change.

Since then the smile root moved from 1e9-floored squares to exact `u128`
squares (DBU-849), which the generator's `up_error_budget` now models. Under the
current model the committed tolerances are tighter than derived at every point:
they pass only because the contract's `ln` is far more accurate than its
documented bound. The committed `admitted_low_variance_up` doc still describes
the pre-DBU-849 surface as sub-unit; under the exact root its forward variance is
one raw unit, and RP-20's sub-unit pin and that surface's own test moved to
`generate_ssvi_reference.py`, so the generator no longer emits
`admitted_low_variance_up` while the committed file still carries it. One committed
test also borrows a budget derived for another surface:
`w_prime_keeps_the_rolled_b_precision` asserts within `flow_fixture_atm_budget`.

**Action:** regenerate the reference data with the dataset present and confirm
the budgets still bound the observed deviations. Until then the file's stated
contract — "propagated from `packages/fixed_math/sources/math.move`'s documented per-primitive budgets" — is
true of the generator but not of the committed data.

### P-30: The C-1 capacity model is one measurement behind the pricing path

**Severity:** Low, but it compounds. Not a defect; a stale measurement.

RP-26 added one `ln` evaluation per digital and removed one `try_mul_div_down`.
`walk_linear` pays that per payout-tree node; since RP-29 the flush prices one
market per transaction (C-1 — resolved — owned the old joint budget), so the
increment lands on the per-transaction valuation compute (bounded at the node
cap's boundary count; C-5 — resolved by the snapshot restructure — owned the
retired delta log's extra term) — last measured at ~51% of the wall for a full
single-market book.

Precedent for sizing it: `evidence/c1-skew-gas-2026-07-09.md` records that the
previous comparable addition (one `normal_pdf`, i.e. one `exp`) cost +2.2%
per-order flush slope and +3.3% at a full book. An `ln` is of similar cost, so a
comparable increment is expected — not near a cliff, but unmeasured. Move
unit-test metering put the difference under 0.01% of a test's gas; that is not
on-chain compute and should not be cited as the answer.

**Action:** fold a re-measurement into the C-2 localnet campaign rather than
running one for this alone.

### P-31: A provider source timestamp ahead of the Sui clock silently empties the feed

**Severity:** Medium; liveness, misattributed failure.

`block_scholes_store::apply` returns `false` rather than aborting when `source_timestamp_ms > onchain_timestamp_ms` — the update's `value_timestamp` or `svi_timestamp` is ahead of the Sui `Clock` at execution. The transaction still succeeds, so the relayer sees success, and the on-chain signal is `applied` reading below `update_count` in `BlockScholesBatchIngested`. Skipping is the right response for one unusable entry, but the provider source clock and Sui checkpoint clock are independent, so a consistently positive skew can reject every observation. The feed then looks like it is ingesting while nothing advances, and pricing halts a freshness window later on `EBlockScholesPriceStale` — an error naming provider staleness for what is actually clock skew at the boundary.

The comparison has a real duty and is not simply removable: accepting a future-dated source timestamp would let that observation win strict source ordering and pin the series until an even later honest source timestamp arrives.

**Action:** Measure each provider `value_timestamp`/`svi_timestamp` minus the Sui clock before a value-bearing deployment and alert explicitly on positive source skew. `update_count > applied` remains a supporting on-chain symptom, but `applied == 0` alone is not diagnostic because unchanged-source retransmissions are legitimate no-ops. If the observed margin is thin, decide the response deliberately — a bounded tolerance on the comparison is a `response-policies.md` decision, not a silent widening.

### P-32: A filled payout tree denies new strike ranges in its own market

**Severity:** Low-Medium / post-launch; bounded to one market.

`max_payout_tree_nodes` (RP-30) closes the flush-liveness attack, but an actor who fills one market's tree to the cap (~960 boundary-creating min-size mints, premium mostly recoverable) still denies NEW strike ranges in that market until nodes free up on closes or expiry. Direction: collapse the cheap node-minting shape onto the free `pos_inf_tick` sentinel so deep-OTM upper bounds stop minting nodes — sequenced after C-2/C-3 because it changes what the cap costs, not what it must be.

### P-33: SSVI final-seconds slices lose accuracy to the feed's 1e9 input scale

**Severity:** Medium. Pricing accuracy on the newest, shortest markets.

Block Scholes signs SVI parameters at 1e9 fixed point, and on the last publication before a one-minute expiry (20 s out) SSVI `a` is a few raw units and `b·sigma` about the same, so rounding the inputs alone moves total variance by several percent. Over 20,000-slice samples of the backfill, rounding to 1e9 moves the true digital at `k = ±sqrt(w_min)` by more than 0.1% relative for 39.1% of slices 20 s out (worst 4.8%), 19.2% of slices 20–60 s out, and 4.5% of slices one to five minutes out; on the tightest negative-`a` slice it moves the $1 range (66,857, 66,858] from 20.10% to 21.44% (`evidence/rp5-ssvi-backfill-2026-09-28.md`). That is outside the ratified 0.1% contract-price bound before any on-chain arithmetic runs. DBU-849 admits these slices; the former 1e-3 sigma floor rejected most of them. At default fees the per-leg minimum fee exceeds these errors, so the fee floor is what keeps them from being traded against; a zero `min_fee` on short cadences would expose them.

The same scale sets a liveness edge. An SSVI slice's minimum total variance is `theta·(1 − rho²)`, and the load gate rounds `a` and floors the SVI increment at 1e9, so a slice whose `theta·(1 − rho²)` is under about 1e-9 loads with a minimum variance of zero and is rejected, aborting that market's pricer loads and the flush snapshot. At 20 s to expiry that happens below an ATM volatility of about 4% (about 5.6% if the provider truncates rather than rounds); Block Scholes' planned realised-volatility ATM level makes quiet windows the ones to watch. The 1e-5 sigma floor never binds first on SSVI slices (RP-5).

**Action:** ask Block Scholes for a higher-precision SVI encoding (the store carries `u128`, so a 1e18 scale for `a` and `b` fits), or measure the mispricing against realized settlement on the final-seconds markets and disclose it in `docs/risks.md`. Until then, ask them to round rather than truncate at 1e9, to floor the ATM volatility their realised/implied blend can produce well above 4%, and to keep the staging and live SSVI feeds on the existing `SVI` series descriptor (model name and 9 decimals are part of the signed series id; a change aborts ingestion with `ESeriesIdMismatch`). Alert on `EBlockScholesMinVarianceInvalid` as well as `EBlockScholesInputsInvalid`. Rerun O-1's calibration on SSVI slices before enabling the one-minute cadence, and keep short-cadence minimum fees at or above the measured error until then.

### P-34: The minimum-variance load gate rounds in both directions

**Severity:** Low. Neither direction is exploitable; both are unmeasured on live data.

`min_svi_variance_increment` computes `b·sigma·sqrt(1 − rho²)` with four floors. Flooring `rho²` rounds `1 − rho²` up, so near `|rho| = 1` the gate's increment can exceed the true minimum and admit a surface whose true minimum total variance is slightly negative (for example, in raw units, `b = 79_695_456_439`, `sigma = 9_025_768_115`, `rho = 995_630_907`, `a = −67_166_622_671`: the gate's increment is 67_166_622_672, one unit above `|a|`, while the true minimum is about −3.4e-6); the per-strike `ENonPositiveVariance` backstop then aborts at the vertex strike. The remaining floors round down, so elsewhere the gate is stricter than true math by up to about `1 + b·(1 + sigma)` raw units: about one unit on SSVI slices, whose tightest backfill margin is exactly one unit. Removing the `|a| ≤ 100` cap (DBU-849) widens the permissive case's reachable magnitude, since `a` can now offset a larger `b·sigma`.

**Action:** decide a one-sided rounding — for example `mul_up` for `rho²` and a single `u128` product `b·sigma·sqrt(1 − rho²)` compared against `|a|` at 1e27 — and pin both sides of the boundary.

### P-35: One-unit rounding ripple in the far tails trips the active-book monotonicity guard

**Severity:** High before one- and five-minute SSVI cadences go live, and already reachable on the current feed wherever one-to-five-minute markets are live; flush liveness. Pre-existing, independent of DBU-849.

`compute_nd2` rounds `nd2` and the skew correction down separately, so in both tails, where the digital is a few raw units, the adjusted UP price can rise by one raw unit between neighbouring strikes on an arbitrage-free surface. The ripple is not rare: every one of 160 sampled SSVI slices that DBU-849 admits has one somewhere between whole-dollar strikes, and so do 8 of 20 sampled current-style slices one to five minutes out, always exactly one raw unit (`evidence/rp5-ssvi-backfill-2026-09-28.md`). On a real backfill slice (published 2026-03-19 07:06:40 for the 07:15 expiry: `a = 2218`, `b = 926_157`, `rho = −28_390_040`, `m = 68_038`, `sigma = 2_395_589` raw, forward 70_464.04) the contract returns UP(72,670) = 4 and UP(72,680) = 5. `strike_payout_tree` requires active-book UP prices to be non-increasing with no tolerance, so two active boundaries straddling such a ripple abort that market's valuation with `ENonMonotonePrice` and stall the pool-wide flush. RP-15 attributes such inversions only to a provider breaking its butterfly-free guarantee; this one needs no provider fault. It is also reachable on purpose: a ladder of minimum-size mints whose boundaries sit in the tails places active boundaries across the ripple region as expiry approaches and the tails move in, so a trader can make later valuation snapshots of that market abort. The mainnet entry band (5% to 95% since 2026-09-28) does not prevent it: a ladder entered at 5% or more reaches the ripple region as the tails move in. Before DBU-849 the same short-dated snapshots aborted earlier, at pricer load, on the sigma floor.

**Action:** decide the tolerance — for example accept a rise of up to two raw units against the running minimum and net with `min(price, previous)`, understating NAV by at most `2e-9` per unit of quantity — record it against RP-15, and land it before short SSVI cadences go live. Pin it with a walk over the two strikes above, and over the one-minute SSVI slice published 20 s before expiry with `a = 63`, `b = 185_973`, `rho = −2_190_270`, `m = 739`, `sigma = 337_252` raw at forward 66_415.25, where UP(66,811) = 9 and UP(66,812) = 10.

### P-36: Predict's SVI roll-down does not follow SSVI's time scaling

**Severity:** Medium; pricing accuracy on live SSVI markets between publications, second order next to the provider's calibration gap near expiry. Pre-existing design (DBU-655), correct for the current feed.

`roll_down_svi` scales `a` and `b` by `remaining / anchored` time and holds `rho`, `m`, and `sigma`, which is total variance scaling linearly with the smile's shape fixed. SSVI slices change shape with time: the provider's `phi = eta·theta^(−1/2)` makes `b`, `m`, and `sigma` scale with `sqrt(remaining / anchored)`. Rolled 20–100 s forward and compared with the provider's own next slice for the same expiry, Predict's roll misses by 0.34–1.27 pp of `UP` on average over `±3 sqrt(w)`, against 0.01–0.23 pp for the SSVI scaling; on the current-style feed Predict's roll is the better one (`evidence/rp5-ssvi-backfill-2026-09-28.md`). The roll only acts between publications — a quote at a publication second prices the fresh slice as-is — so with 20-second publications the ratio stays at or above 0.5 unless a publication is late, and the error is largest just before the next one. Predict's roll is still closer to the provider's next slice than not rolling at all (1.3–12.8 pp), so the near-expiry favourite underpricing measured on the backfill is a provider calibration question, not a roll-down one.

**Action:** before the feed switches to SSVI, decide how the roll-down follows the model — an SSVI roll (`a` by `lambda`; `b`, `m`, `sigma` by `sqrt(lambda)`), a provider flag selecting the roll, or a publication cadence short enough that the roll barely matters — and pin it against the backfill's next-slice comparison. A `sqrt(lambda)`-scaled `sigma` also needs the smile root's exact 1e18 input, which DBU-849 already provides.

### P-37: Part of the provider's SSVI backfill is not SSVI

**Severity:** Medium; provider data question.

Only 62.65% of the backfill's slices satisfy the SSVI identities (`a = b·sigma·sqrt(1 − rho²)`, `m = −rho·sigma/sqrt(1 − rho²)`). Every slice more than a day out is general raw SVI, and so are 98% of slices within a day that were published in the 01:00 UTC hour and 11.9% of those published outside it; the 01:00 UTC regime carries every negative `a` in the backfill (`evidence/rp5-ssvi-backfill-2026-09-28.md`). Butterfly-freeness is a theorem for the SSVI slices (Gatheral and Jacquier 2014, Theorem 4.2) but only the provider's guarantee for the rest, which RP-15 relies on, and the envelope checks no butterfly or wing condition: its `b ≤ 100` ceiling protects arithmetic headroom, while Lee's moment bound is `b·(1 + |rho|) ≤ 2`, and the backfill peaks at 0.39.

**Action:** ask Block Scholes what the 01:00 UTC output is, whether the live SSVI feed carries it, and whether every published slice is certified butterfly-free. Consider a Lee bound `b·(1 + |rho|) < 2` in place of `b ≤ 100`; it rejects nothing in either backfill.

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

### C-2: The valuation base-children reserve is unmeasured

**Severity:** Low / tighten before mainnet; the unsafe direction is closed.

`valuation_base_children_reserve` ships at 40 against a source-inspected true figure of 1-2 (`constants.move`), so `max_payout_tree_nodes` gives up ~4% of the strike grid as pure headroom (RP-30 derives the cap; C-1 — resolved — measured the wall). Tightening needs one localnet run: fill one market to the cap, run its `value_expiry` alone, and read the object-runtime count the transaction actually cached beyond the tree nodes. Decision rule, pre-registered: set the reserve to the measured base plus 8, and never below 8.

- Instrument: `packages/predict/harness/ts/strategies/capacity.ts` `tree` profile against a localnet publish.
- The run must include mid-window trades on the stamped market, including full closes, so the measured walk covers retained husks (husks are ordinary tree nodes converted in place, expected zero extra children — the run proves that expectation).

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
- `fee_incentive_balance` USDC custody sits on `ExpiryMarket` outside the
  `ExpiryCash` solvency invariant — consider folding it into the custody
  component so per-expiry USDC has one owner.
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
