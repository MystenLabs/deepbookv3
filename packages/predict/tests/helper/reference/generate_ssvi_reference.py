#!/usr/bin/env python3
"""Independent true-math reference for Block Scholes SSVI slices and the relaxed
SVI bounds they need, emitted as `pricing_ssvi_reference_data.move`.

Block Scholes SSVI surfaces narrow `sigma` toward expiry: in the SSVI backfill
below, 83% of slices within a minute of expiry sit under the former 1e-3 sigma
floor, and a few short-end slices carry a slightly negative `a`. These slices
exercise the pricing-safe envelope's 1e-5 floor, its lack of any bound on `a`
beyond total variance, and the smile root `sqrt((k - m)^2 + sigma^2)`, which the
contract takes from an exact 1e18 input so a small `sigma` survives squaring. Run:

    python3 generate_ssvi_reference.py     # no third-party deps (stdlib only)

The source rows are embedded below, so regeneration does not need the backfill.

============================================================================
SOURCE AND SELECTION
============================================================================
Source: the Block Scholes SSVI params backfill
`v2composite_svi_params_SSVI_B_BTC_20260201_20260630.parquet` (BTC, one row per
20-second publication, one SVI tuple per listed expiry). Candidates are slices with
`sigma < 1e-3`, the ones the former floor rejected; from those:
  [0] the smallest `sigma` in the whole backfill (a one-minute slice);
  [1] the one-minute slice with the most negative `a` relative to the SVI
      increment's analytical minimum `b * sigma * sqrt(1 - rho^2)`, the short-end
      case Block Scholes flagged; its rounded minimum clears the load gate by one
      raw unit, the tightest margin in the backfill;
  [2] the one-minute slice whose at-the-forward digital the former 1e9 smile root
      missed by the most (about 562_500 units, 0.056 percentage points);
  [3] the same selection as [2] among slices one to five minutes from expiry;
  [4] the same selection as [2] among slices five minutes to one hour from expiry.
Slices [5]-[7] are synthetic: slice [0] with `sigma` at the 1e-5 floor and the
smile's vertex placed relative to the forward:
  [5] `m = 0`, the forward is the vertex; the former 1e9 root was zero there and
      the skew slope's division aborted;
  [6] `m = sigma`, one smile width away, where both squares under the root are a
      tenth of a raw unit at 1e9; the former root was zero and the wing term went
      negative (`ECannotBeNegative`);
  [7] `m = -10 sigma`, in the wing, where `(k - m)^2` dominates; the former root
      priced it about 1.1M units off.
Slices [8]-[9] are synthetic surfaces with `a` past the former `|a| <= 100` cap,
priced with a live skew correction:
  [8] `a = -150` against `b = 1.6`, `sigma = 100` (the `sigma` ceiling),
      `rho = -0.2`, `m = 0.1`: the SVI increment's minimum 156.8 leaves a minimum
      total variance of 6.8 and a forward one of about 10.03, and the wing slopes
      `b * (1 +- rho)` stay under Lee's bound of 2, so the surface is
      arbitrage-free in its wings;
  [9] `a = 101` with a slice-[0] shape: total variance is about 101.
Slice [10] is the sub-unit-variance surface (predeploy RP-20), found by search:
its rounded minimum clears the load gate, and at the forward its true total
variance is 0.99993e-9, which the 1e18 variance path prices and a variance
floored to 1e9 would round to zero and abort on.
Slice [11] sits at `rho = -1`, where the SVI increment's infimum over strikes is
0, so the minimum total variance is `a` alone: one raw unit of positive `a` is the
smallest that loads. `b = 1e-4` and `sigma = 1e-3` keep the skew correction
interior (`UP` about 0.56 at the forward).
Slice [12] clears the load gate by one raw unit (rounded minimum increment 3
against `a = -2`), and at the forward the exact root makes `b * inner` exactly
3e9 at 1e18, so its forward total variance is exactly one raw unit.
The roll-down case seeds slice [2] one minute before a one-minute market's expiry
and prices it three quarters of the way there, so `a` and `b` enter at a quarter
of their published values while `sigma` is unrolled.

Each source float is converted to Predict's 1e9 fixed point once, with
round-to-nearest, and the Move fixture seeds the identical integers the reference
below prices, so the conversion contributes no error to the comparison.

============================================================================
REFERENCE AND BUDGET
============================================================================
The reference is the adjusted digital from Python stdlib `math`:

    w     = a + b*(rho*(k - m) + sqrt((k - m)^2 + sigma^2))
    w'    = b*(rho + (k - m)/sqrt((k - m)^2 + sigma^2))
    d2    = -(k + w/2)/sqrt(w)
    UP    = clamp01(Phi(d2) - phi(d2)*w'/(2*sqrt(w)))

Every tolerance is `generate_pricing_reference.up_error_budget` plus the
generator's 2-unit cushion: the propagation of math.move's documented
per-primitive budgets that the real-scenario reference uses, never measured from
contract output.

The fixture seeds spot == Pyth spot, so the live forward equals the seeded forward
exactly. Each slice is checked two ways:
  - `points`: at its real forward, quoting the forward itself. The contract's
    `k = ln(strike) - ln(forward)` is exactly zero there, so the point carries no
    `ln` error (`d_k = 0`).
  - `unit_forward_points`: the same SVI shape seeded at spot == forward == 1.0,
    where `ln(forward)` is exactly zero, quoting raw strikes around the smile
    (the vertex, a smile width either side for the floor surfaces, and `d2` near
    +-1 and +-2; a fixed log-moneyness grid for the high-variance surfaces
    [9], whose `d2 = +-1` strikes sit below one raw unit; none for [10], a
    forward-only pin). Only `ln(strike)` carries error, and near 1.0 that is the raw-unit
    term of the same `d_k` model, so the budgets stay tight enough to separate the
    former 1e9 root. At real BTC strikes the documented 1e-7 relative `ln` bound is
    about 2e-6 in `k`, which against one-minute `sqrt(w)` near 1e-4 is a cent of
    probability, too loose to catch anything but a gross formula error (predeploy
    open item P-16); the unit forward removes that term without changing the
    surface's shape in log-moneyness.
"""
import math
import os

from generate_pricing_reference import CUSHION_UNITS, F, phi, phi_pdf, up_error_budget

OUT_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "..", "pricing", "pricing_ssvi_reference_data.move",
)

# Source values exactly as the backfill carries them.
SOURCE_SLICES = [
    dict(
        key="smallest_sigma",
        note="smallest sigma in the backfill",
        isodate="2026-04-03T22:29:40.000Z", expiry="2026-04-03T22:30:00Z",
        spot=66875.41251081793, forward=66875.41,
        a=4.455766493415811e-09, b=9.399032248166457e-05,
        rho=0.0004026366575837393, m=-1.9087658935079156e-08,
        sigma=4.740665567416494e-05,
    ),
    dict(
        key="negative_a",
        note="most negative a against the SVI increment's minimum, one minute out",
        isodate="2026-04-04T01:22:40.000Z", expiry="2026-04-04T01:23:00Z",
        spot=66857.05121336073, forward=66857.05,
        a=-5.725444955518636e-09, b=9.78346668506319e-05,
        rho=0.00045942959253389665, m=2.2398533504391035e-07,
        sigma=7.946514521542227e-05,
    ),
    dict(
        key="one_minute_root_miss",
        note="largest at-the-forward miss by the former 1e9 root, one minute out",
        isodate="2026-06-19T23:59:40.000Z", expiry="2026-06-20T00:00:00Z",
        spot=63488.11358005571, forward=63488.11,
        a=5.284023965038848e-09, b=8.464794030294398e-05,
        rho=-0.016036733542527246, m=1.0013271727169928e-06,
        sigma=6.243156704649579e-05,
    ),
    dict(
        key="one_to_five_minute_root_miss",
        note="largest at-the-forward miss by the former 1e9 root, one to five minutes out",
        isodate="2026-05-09T01:17:00.000Z", expiry="2026-05-09T01:19:00Z",
        spot=80297.17852670558, forward=80297.18,
        a=-2.8582829751976012e-08, b=0.00021036471330122022,
        rho=0.021651599936483745, m=-1.3883786328708944e-05,
        sigma=0.0002466983286788099,
    ),
    dict(
        key="sub_hour_root_miss",
        note="largest at-the-forward miss by the former 1e9 root, five minutes to an hour out",
        isodate="2026-05-09T01:17:00.000Z", expiry="2026-05-09T01:25:00Z",
        spot=80297.17852670558, forward=80297.17,
        a=-1.0396516448823014e-07, b=0.0004225908068512946,
        rho=0.03277486067469523, m=-6.0076733497987e-05,
        sigma=0.0004988234851400063,
    ),
]
SIGMA_FLOOR = 1e-05
FORMER_A_CAP = 100.0
SYNTHETIC_SLICES = [
    dict(SOURCE_SLICES[0], key="floor_vertex",
         note="synthetic: slice [0], sigma at the floor, vertex at the forward",
         sigma=SIGMA_FLOOR, m=0.0),
    dict(SOURCE_SLICES[0], key="floor_one_width",
         note="synthetic: slice [0], sigma at the floor, forward one width from the vertex",
         sigma=SIGMA_FLOOR, m=SIGMA_FLOOR),
    dict(SOURCE_SLICES[0], key="floor_wing",
         note="synthetic: slice [0], sigma at the floor, forward in the wing",
         sigma=SIGMA_FLOOR, m=-10 * SIGMA_FLOOR),
    dict(SOURCE_SLICES[0], key="negative_a_past_cap",
         note="synthetic: negative a past the former |a| <= 100 cap",
         a=-150.0, b=1.6, rho=-0.2, m=0.1, sigma=100.0),
    dict(SOURCE_SLICES[0], key="positive_a_past_cap",
         note="synthetic: positive a past the former |a| <= 100 cap",
         a=101.0, unit_forward="log_moneyness_grid", k_grid=(-2.0, -1.0, 1.0, 2.0)),
    dict(SOURCE_SLICES[0], key="sub_unit_variance",
         note="synthetic: true total variance under one raw unit at the forward (RP-20)",
         a=-6_504_462 / F, b=269_451 / F, rho=549_040_989 / F,
         m=18_973_018_796 / F, sigma=28_882_292_262 / F, unit_forward="none"),
    dict(SOURCE_SLICES[0], key="unit_rho",
         note="synthetic: rho = -1 with one raw unit of positive a",
         a=1 / F, b=1e-04, rho=-1.0, m=0.0, sigma=1e-03),
    dict(SOURCE_SLICES[0], key="one_raw_unit_variance",
         note="synthetic: total variance at the forward exactly one raw unit",
         a=-2 / F, b=1_000 / F, rho=0.8, m=6_666_634 / F, sigma=5_000_000 / F),
]
UNIT_FORWARD = F                       # 1.0: ln(forward) is exactly zero
UNIT_FORWARD_D2 = [2.0, 1.0, -1.0, -2.0]

# Roll-down case: the tuple is seeded at the fixture clock and priced later.
ROLLED_SLICE = 2
ROLLED_SEEDED_AT_MS = 120_000          # test_constants::now_ms
ROLLED_EXPIRY_MS = 180_000             # one cadence period after the seed
ROLLED_PRICED_AT_MS = 165_000          # SVI age 45s, inside the 60s default window
ROLLED_RATIO = (ROLLED_EXPIRY_MS - ROLLED_PRICED_AT_MS) / (ROLLED_EXPIRY_MS - ROLLED_SEEDED_AT_MS)


def to_fixed(x):
    return round(x * F)


class Slice:
    def __init__(self, src):
        self.key = src["key"]
        self.note = src["note"]
        self.provenance = f"{src['isodate']} -> {src['expiry']}"
        self.spot = to_fixed(src["spot"])
        self.forward = to_fixed(src["forward"])
        self.a = to_fixed(src["a"])
        self.b = to_fixed(src["b"])
        self.rho = to_fixed(src["rho"])
        self.m = to_fixed(src["m"])
        self.sigma = to_fixed(src["sigma"])
        self.unit_forward = src.get("unit_forward", "d2_targets")
        self.k_grid = src.get("k_grid", ())
        # Exact reals of the seeded integers.
        self.af, self.bf, self.rf, self.mf, self.sf = (
            v / F for v in (self.a, self.b, self.rho, self.m, self.sigma)
        )

    def w_of_k(self, k, ratio=1.0):
        x = k - self.mf
        return ratio * (self.af + self.bf * (self.rf * x + math.sqrt(x * x + self.sf * self.sf)))

    def up_true(self, strike, forward, ratio=1.0):
        k = math.log(strike / forward)
        x = k - self.mf
        sq = math.sqrt(x * x + self.sf * self.sf)
        w = self.w_of_k(k, ratio)
        w_prime = ratio * self.bf * (self.rf + x / sq)
        S = math.sqrt(w)
        d2 = -(k + w / 2.0) / S
        up = phi(d2) - phi_pdf(d2) * w_prime / (2.0 * S)
        return round(max(0.0, min(1.0, up)) * F)

    def tolerance(self, strike, forward, ratio=1.0):
        if strike == forward:
            k, d_k = 0.0, 0.0
        else:
            k = math.log(strike / forward)
            d_k = 1e-7 * (abs(math.log(strike / F)) + abs(math.log(forward / F))) + 2.0 / F
        du = up_error_budget(
            ratio * self.af, ratio * self.bf, self.rf, self.mf, self.sf, k, d_k
        )
        return math.ceil(du * F) + CUSHION_UNITS

    def d2_of_k(self, k):
        w = self.w_of_k(k)
        return -(k + w / 2.0) / math.sqrt(w)

    def k_for_d2(self, d2_target):
        # Bisect d2(k) = d2_target inside +-50 at-the-forward deviations. Only the
        # bracket is checked; the bisection assumes d2 falls monotonically in k
        # inside it, which holds for these surfaces (their densities are positive).
        half_width = 50.0 * math.sqrt(self.w_of_k(0.0))
        lo, hi = -half_width, half_width
        if not self.d2_of_k(lo) > d2_target > self.d2_of_k(hi):
            raise ValueError(f"{self.key}: d2={d2_target} is not bracketed")
        for _ in range(200):
            mid = (lo + hi) / 2.0
            if self.d2_of_k(mid) > d2_target:
                lo = mid
            else:
                hi = mid
        return (lo + hi) / 2.0

    def point(self, strike, forward, where):
        k = math.log(strike / forward)
        w = self.w_of_k(k)
        d2 = -(k + w / 2.0) / math.sqrt(w)
        return dict(
            strike=strike,
            reference=self.up_true(strike, forward),
            tolerance=self.tolerance(strike, forward),
            note=f"{where}, k={k:+.3e}, d2={d2:+.3f}",
        )

    def points(self):
        return [self.point(self.forward, self.forward, "at the forward")]

    def unit_forward_points(self):
        if self.unit_forward == "none":
            return []
        log_strikes = [(self.mf, "vertex")]
        if self.unit_forward == "log_moneyness_grid":
            # Total variance near 100 puts d2 = +-1 at |k| ~ 35, below one raw strike.
            log_strikes += [(k, f"k = {k:+.1f}") for k in self.k_grid]
            return self.points_at_unit_forward(log_strikes)
        if self.sigma == to_fixed(SIGMA_FLOOR):
            log_strikes += [
                (self.mf - self.sf, "one width below the vertex"),
                (self.mf + self.sf, "one width above the vertex"),
                (self.mf + 10 * self.sf, "ten widths above the vertex"),
            ]
        log_strikes += [(self.k_for_d2(d2), f"d2 target {d2:+.0f}") for d2 in UNIT_FORWARD_D2]
        return self.points_at_unit_forward(log_strikes)

    def points_at_unit_forward(self, log_strikes):
        pts, seen = [], set()
        for k, where in log_strikes:
            strike = round(UNIT_FORWARD * math.exp(k))
            if strike in seen or strike == UNIT_FORWARD:
                continue
            seen.add(strike)
            pts.append(self.point(strike, UNIT_FORWARD, where))
        return pts


def gate_increment(s):
    """The load gate's rounded minimum increment, emulating pricing.move's documented
    floors (`mul_down`, `sqrt_down`). Used only to check that a fixture sits where
    its tests say it does, never to derive an expected value."""
    rho_sq = abs(s.rho) * abs(s.rho) // F
    if abs(s.rho) == F:
        return 0
    root = math.isqrt((F - rho_sq) * F)
    return s.b * (s.sigma * root // F) // F


def forward_variance_1e18(s):
    """Total variance at the forward (`k = 0`) at 1e18, emulating the exact root."""
    x = -s.m
    root = math.isqrt(x * x + s.sigma * s.sigma)
    rho_x = abs(s.rho) * abs(x) // F
    inner = root + (-rho_x if (s.rho < 0) != (x < 0) else rho_x)
    return s.a * F + s.b * inner


def check_selection(slices):
    """Fail loudly if an embedded slice no longer has the property its tests claim."""
    by_key = {s.key: s for s in slices}
    assert by_key["negative_a"].a < 0
    assert gate_increment(by_key["negative_a"]) + by_key["negative_a"].a == 1
    assert all(s.sigma < to_fixed(1e-3) for s in slices[:len(SOURCE_SLICES)])
    for key in ("floor_vertex", "floor_one_width", "floor_wing"):
        assert by_key[key].sigma == to_fixed(SIGMA_FLOOR)
    assert by_key["negative_a_past_cap"].a < -to_fixed(FORMER_A_CAP)
    for s in slices:
        assert s.bf * (1 + abs(s.rf)) < 2, f"{s.key}: wing slope breaks Lee's bound"
    assert by_key["positive_a_past_cap"].a > to_fixed(FORMER_A_CAP)
    sub_unit = by_key["sub_unit_variance"]
    assert 0 < sub_unit.w_of_k(0.0) < 1 / F
    assert 0 < forward_variance_1e18(sub_unit) < F
    one_unit = by_key["one_raw_unit_variance"]
    assert gate_increment(one_unit) + one_unit.a == 1
    assert forward_variance_1e18(one_unit) == F
    unit_rho = by_key["unit_rho"]
    assert unit_rho.rho == -F and unit_rho.a == 1


def fmt_u64(x):
    return f"{x:_}"


def emit_move(slices, rolled):
    lines = []
    w = lines.append
    w("// Copyright (c) Mysten Labs, Inc.")
    w("// SPDX-License-Identifier: Apache-2.0")
    w("//")
    w("// @generated by packages/predict/tests/helper/reference/generate_ssvi_reference.py")
    w("// Source data: Block Scholes SSVI params backfill")
    w("// v2composite_svi_params_SSVI_B_BTC_20260201_20260630.parquet (BTC, 20-second")
    w("// publications). DO NOT EDIT BY HAND — regenerate with")
    w("//   python3 generate_ssvi_reference.py")
    w("//")
    w("// Independent true-math reference (Python stdlib math.log/sqrt/erf, NOT the contract)")
    w("// for Pricer.range_price on SSVI slices and the relaxed SVI bounds. Each `tolerance` is")
    w("// generate_pricing_reference.up_error_budget at that strike plus a 2-unit cushion.")
    w("// `points` quote each slice's real forward (no `ln` error); `unit_forward_points`")
    w("// quote strikes around the smile with the same shape seeded at a forward of 1.0.")
    w("// See the generator header for the selection and derivation.")
    w("//")
    w("// Provenance (publication -> expiry):")
    for i, s in enumerate(slices):
        w(f"//   [{i}] {s.provenance}  {s.note}")
    w("#[test_only]")
    w("module deepbook_predict::pricing_ssvi_reference_data;")
    w("")
    w("use deepbook_predict::constants;")
    w("")
    w("const ENoSuchSlice: u64 = 0;")
    w("")
    w("/// One independent reference point: Pricer.range_price(lower, higher).probability()")
    w("/// must be within `tolerance` units of the true-math `reference`.")
    w("public struct RefPoint has copy, drop {")
    w("    lower: u64,")
    w("    higher: u64,")
    w("    reference: u64,")
    w("    tolerance: u64,")
    w("}")
    w("")
    w("public fun lower(p: &RefPoint): u64 { p.lower }")
    w("")
    w("public fun higher(p: &RefPoint): u64 { p.higher }")
    w("")
    w("public fun reference(p: &RefPoint): u64 { p.reference }")
    w("")
    w("public fun tolerance(p: &RefPoint): u64 { p.tolerance }")
    w("")
    w("fun pt(lower: u64, higher: u64, reference: u64, tolerance: u64): RefPoint {")
    w("    RefPoint { lower, higher, reference, tolerance }")
    w("}")
    w("")
    w("/// Number of slices.")
    w(f"public fun slice_count(): u64 {{ {len(slices)} }}")
    w("")
    w("// === Slice indices ===")
    w("")
    for i, s in enumerate(slices):
        w(f"/// {s.note[0].upper()}{s.note[1:]}.")
        w(f"public fun {s.key}_slice(): u64 {{ {i} }}")
        w("")
    w("/// Spot and forward of the unit-forward seeding (1.0 at 1e9).")
    w(f"public fun unit_forward(): u64 {{ {fmt_u64(UNIT_FORWARD)} }}")
    w("")

    def selector(name, ty, values, doc):
        # Fully-expanded if/else-if/else so prettier-move leaves it untouched.
        w(f"/// {doc}")
        w(f"public fun {name}(s: u64): {ty} {{")
        for i, v in enumerate(values):
            kw = "if" if i == 0 else "} else if"
            w(f"    {kw} (s == {i}) {{")
            w(f"        {str(v).lower() if ty == 'bool' else fmt_u64(v)}")
        w("    } else {")
        w("        abort ENoSuchSlice")
        w("    }")
        w("}")
        w("")

    selector("spot", "u64", [s.spot for s in slices], "Block Scholes spot (1e9), also seeded as the Pyth spot.")
    selector("forward", "u64", [s.forward for s in slices], "Block Scholes forward (1e9); the live forward.")
    selector("svi_a_magnitude", "u64", [abs(s.a) for s in slices], "SVI `a` magnitude (1e9).")
    selector("svi_a_is_negative", "bool", [s.a < 0 for s in slices], "Sign flag for SVI `a` (true == negative).")
    selector("svi_b", "u64", [s.b for s in slices], "SVI `b` (1e9).")
    selector("svi_rho_magnitude", "u64", [abs(s.rho) for s in slices], "SVI `rho` magnitude (1e9).")
    selector("svi_rho_is_negative", "bool", [s.rho < 0 for s in slices], "Sign flag for SVI `rho` (true == negative).")
    selector("svi_m_magnitude", "u64", [abs(s.m) for s in slices], "SVI `m` magnitude (1e9).")
    selector("svi_m_is_negative", "bool", [s.m < 0 for s in slices], "Sign flag for SVI `m` (true == negative).")
    selector("svi_sigma", "u64", [s.sigma for s in slices], "SVI `sigma` (1e9).")

    def point_selector(name, doc, pts_of):
        w(f"/// {doc}")
        w(f"public fun {name}(s: u64): vector<RefPoint> {{")
        for i, s in enumerate(slices):
            kw = "if" if i == 0 else "} else if"
            w(f"    {kw} (s == {i}) {{")
            pts = pts_of(s)
            if not pts:
                w("        vector[]")
                continue
            w("        vector[")
            for p in pts:
                w(f"            // {p['note']}")
                w(f"            pt({fmt_u64(p['strike'])}, constants::pos_inf!(), {fmt_u64(p['reference'])}, {fmt_u64(p['tolerance'])}),")
            w("        ]")
        w("    } else {")
        w("        abort ENoSuchSlice")
        w("    }")
        w("}")
        w("")

    point_selector(
        "points",
        "Reference points for slice `s` at its real forward: the UP digital `(strike, +inf]`.",
        lambda s: s.points(),
    )
    point_selector(
        "unit_forward_points",
        "Reference points for slice `s` seeded at spot == forward == `unit_forward()`.",
        lambda s: s.unit_forward_points(),
    )

    w("// === Roll-down ===")
    w("")
    w(f"/// Slice the roll-down case seeds, priced with {ROLLED_RATIO} of its anchored horizon left.")
    w(f"public fun rolled_slice(): u64 {{ {ROLLED_SLICE} }}")
    w("")
    w("/// Expiry of the roll-down market; the tuple is seeded at `test_constants::now_ms`.")
    w(f"public fun rolled_expiry_ms(): u64 {{ {fmt_u64(ROLLED_EXPIRY_MS)} }}")
    w("")
    w("/// Clock at which the roll-down case is priced.")
    w(f"public fun rolled_priced_at_ms(): u64 {{ {fmt_u64(ROLLED_PRICED_AT_MS)} }}")
    w("")
    w("/// True UP digital at the forward with `a` and `b` rolled down.")
    w(f"public fun rolled_up_at_forward(): u64 {{ {fmt_u64(rolled.up_true(rolled.forward, rolled.forward, ROLLED_RATIO))} }}")
    w("")
    w("/// Absolute precision budget for `rolled_up_at_forward` (units @1e9).")
    w(f"public fun rolled_budget(): u64 {{ {fmt_u64(rolled.tolerance(rolled.forward, rolled.forward, ROLLED_RATIO))} }}")
    return "\n".join(lines) + "\n"


def main():
    slices = [Slice(src) for src in SOURCE_SLICES + SYNTHETIC_SLICES]
    check_selection(slices)
    for i, s in enumerate(slices):
        print(f"[{i}] {s.key}: {s.provenance} {s.note}")
        print(f"    spot={s.spot} forward={s.forward} a={s.a} b={s.b} rho={s.rho} m={s.m} sigma={s.sigma}")
        for p in s.points() + s.unit_forward_points():
            print(f"      strike={p['strike']} ref={p['reference']} tol={p['tolerance']}  {p['note']}")
    rolled = slices[ROLLED_SLICE]
    print(f"rolled [{ROLLED_SLICE}] ratio={ROLLED_RATIO} "
          f"ref={rolled.up_true(rolled.forward, rolled.forward, ROLLED_RATIO)} "
          f"tol={rolled.tolerance(rolled.forward, rolled.forward, ROLLED_RATIO)}")
    move_src = emit_move(slices, rolled)
    with open(OUT_PATH, "w") as f:
        f.write(move_src)
    print(f"wrote {os.path.normpath(OUT_PATH)} ({move_src.count(chr(10))} lines)")


if __name__ == "__main__":
    main()
