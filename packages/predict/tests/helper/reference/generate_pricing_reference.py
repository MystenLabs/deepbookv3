#!/usr/bin/env python3
"""Independent true-math reference for `Pricer.range_price`, driven
from REAL on-chain Block Scholes SVI observations.

Emits the committed Move module `pricing_reference_data.move`, which the exact
pricing tests (`pricing_exact_tests.move`) assert against. Run:

    python3 generate_pricing_reference.py        # no third-party deps (stdlib only)

Per Predict unit-test rule 16 the generator is committed for provenance and is
NOT in the CI path: CI runs only the Move tests against the emitted constants.

============================================================================
REFERENCE INDEPENDENCE (unit-tests rule 1)
============================================================================
The expected price at each strike is computed here in FULL DOUBLE PRECISION
from Python's stdlib (`math.log`, `math.sqrt`, `math.erf`) using the standard
digital-option definition, NOT transcribed from the Move contract and NOT taken
from `python_replay.py` (which is a fixed-point PARITY model — asserting against
it would be circular). The SVI model spec is used only as the *definition* of the
total-variance curve; d2 and Phi are derived from first principles:

    k       = ln(strike / forward)                         (log-moneyness)
    w(k)    = a + b*( rho*(k-m) + sqrt((k-m)^2 + sigma^2) ) (SVI total variance)
    d2      = -(k + w/2) / sqrt(w)                          (Black digital d2)
    UP(K)   = Phi(d2) = P(S_T > K)        Phi(x)=0.5*(1+erf(x/sqrt2))
    range   = max(0, UP(lower) - UP(higher))   with UP(-inf)=1, UP(+inf)=0

`erf`-based Phi is independent of the contract's Cody rational approximation, so
a formula bug in the contract (wrong d2 sign, wrong SVI assembly, etc.) is caught,
not masked.

============================================================================
INPUT FIDELITY (never truncate)
============================================================================
Every SVI param (a, b, rho, m, sigma) and spot/forward is carried as the EXACT
1e9-scaled INTEGER from the CSV, end to end. The Move fixture seeds the oracle
with the identical integer magnitudes + sign flags; this reference computes from
the identical integers (int/1e9 in float64 is exact to ~1e-16, far below the 1e-9
scale). No param is ever rounded, shortened, or re-derived from another column.

The *forward the contract actually prices with* is NOT the raw pushed forward: in
`pricing::load_live_pricer` the fresh-Pyth path re-derives it as
    forward_live = mul(spot, div(forward, spot))            (two fixed_math floors)
This is the dominant production path (Pyth spot fresh). We reproduce that floor
round-trip below to obtain the byte-identical forward the model prices at, then
compute the TRUE Phi(d2) from it. The round-trip is INPUT CONSTRUCTION (it builds
the model's forward input), not the pricer; ref and contract therefore price the
identical forward, so the round-trip contributes NO error to the budget.

============================================================================
PRECISION BUDGET (derived, never measured from contract output)
============================================================================
Each test tolerance is the analytic worst-case absolute error of the contract's
fixed-point evaluation of UP(K)=Phi(d2), propagated from the math layer's
DOCUMENTED per-primitive budgets (math.move "Precision contract"):
    ln   : relative error <= 1e-7        (k = ln(strike/forward))
    sqrt : floor, <= 1 ULP (1e-9)
    mul / div / square (predict math, i64): floor, <= 1 ULP (1e-9) each
    normal_cdf : absolute error <= 2e-8  (reaches the quote 1:1)

evaluated at the TRUE (reference) values — NOT read from the contract. The
composition is, with F=1e9 and all quantities in real (un-scaled) units:

    ratio = strike/forward ;  e_ratio = 1/F                         (div floor)
    k     = ln(ratio)
      d_k = e_ratio/ratio + 1e-7*|k| + 1/F                          (ratio floor; ln rel; k ULP)
    km    = k - m                                                   (m exact)
    km2   = km^2          ; e_km2 = 2|km|*d_k + 1/F                 (square floor)
    sig2  = sigma^2       ; e_sig2 = 1/F                            (sigma exact; mul floor)
    si    = km2 + sig2    ; e_si  = e_km2 + e_sig2
    sq    = sqrt(si)      ; e_sq  = e_si/(2*sqrt(si)) + 1/F         (sqrt floor)
    rk    = rho*km        ; e_rk  = |rho|*d_k + 1/F                 (rho exact; mul floor)
    inner = rk + sq       ; e_in  = e_rk + e_sq
    w     = a + b*inner   ; e_w   = b*e_in + 1/F                    (a exact; mul floor)
    S     = sqrt(w)       ; e_S_floor = 1/F                         (sqrt floor, independent)
    hv    = w/2           ; e_hv_floor = 0.5/F                      (int floor, independent)
    N     = k + w/2       ;  d2 = -N/S
    d_d2  = d_k/S                                  (dk through num,  dN/dk = 1)
          + |dd2/dw| * e_w                         (variance value error, correlated num+den)
          + e_hv_floor/S                           (half_var independent floor)
          + |N/w| * e_S_floor                      (sqrt_var independent floor; dd2/dS=N/S^2=N/w)
          + 1/F                                    (div_scaled floor on d2)
        where  dd2/dw = 0.5*w^(-3/2)*(k - w/2)
    d_up  = 2e-8 + phi(d2)*d_d2                    (normal_cdf abs + Phi sensitivity)

KEY RESULT: the budget is dominated NOT by any single primitive (~1e-7) but by the
`|dd2/dw|*e_w` term: at small total variance w (near-expiry scenarios) and moderate
moneyness (|d2|~1, where phi(d2) is still large), d2 = -(k+w/2)/sqrt(w) is
ill-conditioned w.r.t. w (the w^(-3/2) factor), so a 1-ULP variance rounding moves
the quote by ~1e-6. The reported worst-case budget reflects this.

The wings (deep ITM/OTM, |d2| large) hit the contract's normal_cdf clamp (0 or F)
and Phi rounds to exactly 0/F, so those points are EXACT (tolerance = a 2-unit
representation cushion), exercising the clamp path.
"""
import csv
import math
import os
from decimal import Decimal, getcontext

getcontext().prec = 60

F = 1_000_000_000
REFERENCE_GRID_TICKS = 100_000       # Reference ladder width used to choose strikes.
MARKET_TICK_SIZE_UNIT = 10_000       # constants::market_tick_size_unit!()
TICK_SIZE = 1_000_000_000            # $1 ticks: spot/tick in (50000, 100000] for ~$75k spot
CUSHION_UNITS = 2                    # reference integer rounding + 2nd-order propagation

# SVI production bounds (constants.move) the chosen rows must satisfy so the
# fixture can seed them through the production cap path (assert_valid_svi).
SVI_SIGMA_MIN, SVI_SIGMA_MAX = 1_000_000, 100_000_000_000

# Three diverse-variance rows from the single real market, selected by stable
# svi_event_digest (large / medium / small total variance => different time to
# expiry). Recorded for reproducibility; the generator fails loudly if absent.
SELECTED_DIGESTS = [
    "5KbNiu2S7ULJcS1ryDtJ3DC2omTojjJoMFjmu7nYgTAF9",   # 2026-05-27 08:00:18  sqrt_w_atm ~0.0171
    "H4DNoM3eRw83KdZjASFabLJSgu7YNZYRNfCWErcKgnE59",   # 2026-05-27 20:04:03  sqrt_w_atm ~0.0109
    "357n4TarJkp62atdMpfGExEr77SZGqnDBZ7QcBatgpUF9",   # 2026-05-28 02:03:03  sqrt_w_atm ~0.0084
]

# Interior d2 ladder (well below the sqrt(32)~5.657 clamp) + two clamp wings.
INTERIOR_D2 = [3.0, 2.0, 1.0, 0.5, 0.0, -0.5, -1.0, -2.0, -3.0]
WING_D2 = [8.0, -8.0]                 # deep ITM / OTM -> contract clamps to F / 0

HERE = os.path.dirname(os.path.abspath(__file__))
CSV_PATH = os.path.join(HERE, "..", "..", "..", "simulations", "data", "scenario_dataset.csv")
OUT_PATH = os.path.join(HERE, "..", "..", "pricing", "pricing_reference_data.move")


# --- predict math floor ops (INPUT construction only: forward round-trip) ---
def fp_div(x, y):  # math::div: floor(x * F / y)
    return (x * F) // y


def fp_mul(x, y):  # math::mul: floor(x * y / F)
    return (x * y) // F


def phi(x):  # standard normal CDF via stdlib erf (independent of Cody approx)
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def phi_pdf(x):  # standard normal density 1/sqrt(2pi) * exp(-x^2/2)
    return math.exp(-0.5 * x * x) / math.sqrt(2.0 * math.pi)


class Scenario:
    def __init__(self, row):
        self.digest = row["svi_event_digest"]
        self.svi_ts = row["svi_timestamp"]
        self.oracle_id = row["oracle_id"]
        self.spot = int(row["spot"])
        self.forward = int(row["forward"])
        self.a = int(row["a"])
        self.b = int(row["b"])
        self.rho_mag = int(row["rho"])
        self.rho_neg = row["rho_negative"].strip().lower() == "true"
        self.m_mag = int(row["m"])
        self.m_neg = row["m_negative"].strip().lower() == "true"
        self.sigma = int(row["sigma"])
        self._validate()
        # Exact reals for the true-math reference.
        self.af = self.a / F
        self.bf = self.b / F
        self.rf = (-self.rho_mag if self.rho_neg else self.rho_mag) / F
        self.mf = (-self.m_mag if self.m_neg else self.m_mag) / F
        self.sf = self.sigma / F
        # The forward the contract actually prices with (fresh-Pyth round-trip).
        self.forward_live = fp_mul(self.spot, fp_div(self.forward, self.spot))
        self.fwd_f = self.forward_live / F
        # Reference ladder for selecting raw strikes around spot. Production
        # markets use absolute ticks; this generator emits raw strike points.
        spot_ticks = self.spot // TICK_SIZE
        if not (REFERENCE_GRID_TICKS // 2 < spot_ticks <= REFERENCE_GRID_TICKS):
            raise ValueError(f"{self.digest}: spot_ticks {spot_ticks} out of reference window")
        self.min_strike = (spot_ticks - REFERENCE_GRID_TICKS // 2) * TICK_SIZE
        self.max_strike = self.min_strike + TICK_SIZE * REFERENCE_GRID_TICKS

    def _validate(self):
        assert SVI_SIGMA_MIN <= self.sigma <= SVI_SIGMA_MAX, f"{self.digest}: sigma out of bounds"
        assert self.rho_mag <= F, f"{self.digest}: |rho|>1"
        assert TICK_SIZE % MARKET_TICK_SIZE_UNIT == 0

    # --- true-math pricing from exact reals ---
    def w_of_k(self, k):
        km = k - self.mf
        return self.af + self.bf * (self.rf * km + math.sqrt(km * km + self.sf * self.sf))

    def d2_of_strike(self, strike):
        # strike and forward_live are both 1e9-scaled integers -> ratio is dimensionless.
        k = math.log(strike / self.forward_live)
        w = self.w_of_k(k)
        return k, w, -(k + w / 2.0) / math.sqrt(w)

    def up_true(self, strike):
        _, _, d2 = self.d2_of_strike(strike)
        return phi(d2)

    # --- analytic absolute error budget for UP(strike)=Phi(d2) at one strike ---
    def delta_up(self, strike):
        k, w, d2 = self.d2_of_strike(strike)
        ratio = strike / self.forward_live
        S = math.sqrt(w)
        N = k + w / 2.0
        # error in k
        d_k = (1.0 / F) / ratio + 1e-7 * abs(k) + 1.0 / F
        km = k - self.mf
        # error in the total-variance VALUE w (before the /2 and sqrt)
        e_km2 = 2.0 * abs(km) * d_k + 1.0 / F
        e_sig2 = 1.0 / F
        e_si = e_km2 + e_sig2
        si = km * km + self.sf * self.sf
        e_sq = e_si / (2.0 * math.sqrt(si)) + 1.0 / F
        e_rk = abs(self.rf) * d_k + 1.0 / F
        e_in = e_rk + e_sq
        e_w = self.bf * e_in + 1.0 / F
        # d2 sensitivity: dk through numerator; e_w correlated through num+den;
        # independent half_var and sqrt_var floors; div floor.
        dd2_dw = 0.5 * w ** (-1.5) * (k - w / 2.0)
        d_d2 = (
            d_k / S
            + abs(dd2_dw) * e_w
            + (0.5 / F) / S
            + abs(N / w) * (1.0 / F)
            + 1.0 / F
        )
        return 2e-8 + phi_pdf(d2) * d_d2

    def snap(self, strike):
        rel = strike - self.min_strike
        snapped = self.min_strike + (rel // TICK_SIZE) * TICK_SIZE
        return max(self.min_strike, min(self.max_strike, snapped))

    def strike_for_d2(self, d2_target):
        # invert d2 = -(k + w/2)/sqrt(w); w depends on k, so iterate a few times.
        w = self.w_of_k(0.0)
        for _ in range(40):
            k = -d2_target * math.sqrt(w) - w / 2.0
            w = self.w_of_k(k)
        strike = self.snap(round(self.fwd_f * math.exp(k) * F))
        assert self.min_strike <= strike <= self.max_strike, f"strike {strike} off grid"
        assert (strike - self.min_strike) % TICK_SIZE == 0
        return strike


POS_INF = (1 << 64) - 1
NEG_INF = 0


def build_points(s):
    """Return (list_of_point_dicts, max_delta_up_units_for_this_scenario)."""
    points = []
    worst = 0
    # de-dup snapped strikes across the d2 ladder (whole-$ ticks are ~$300+ apart)
    d2_to_strike = {}
    for d2 in INTERIOR_D2:
        d2_to_strike[d2] = s.strike_for_d2(d2)
    seen = set()

    # interior single-sided (strike, +inf): UP(strike) = Phi(d2)
    for d2 in INTERIOR_D2:
        strike = d2_to_strike[d2]
        if strike in seen:
            continue
        seen.add(strike)
        du = s.delta_up(strike)
        tol = math.ceil(du * F) + CUSHION_UNITS
        worst = max(worst, du)
        ref = round(s.up_true(strike) * F)
        points.append(dict(lower=strike, higher=POS_INF, reference=ref, tolerance=tol,
                           note=f"d2~{d2:+.1f} UP(K)=Phi(d2)"))

    # clamp wings (strike, +inf): contract clamps, Phi rounds to exactly 0 / F
    for d2 in WING_D2:
        strike = s.strike_for_d2(d2)
        if strike in seen:
            continue
        seen.add(strike)
        _, _, d2t = s.d2_of_strike(strike)
        ref = round(s.up_true(strike) * F)
        assert ref in (0, F), f"wing d2={d2t} did not round to clamp (ref={ref})"
        assert abs(d2t) >= 6.0, f"wing |d2|={abs(d2t)} not deep enough to clamp"
        points.append(dict(lower=strike, higher=POS_INF, reference=ref,
                           tolerance=CUSHION_UNITS, note=f"clamp wing d2~{d2:+.0f}"))

    # neg_inf one-sided range (-inf, strike@ATM): range = 1 - Phi(d2)
    atm = d2_to_strike[0.0]
    du = s.delta_up(atm)
    tol = math.ceil(du * F) + CUSHION_UNITS
    worst = max(worst, du)
    ref = round((1.0 - s.up_true(atm)) * F)
    points.append(dict(lower=NEG_INF, higher=atm, reference=ref, tolerance=tol,
                       note="(-inf, K_atm] = 1 - Phi(d2)"))

    # finite-finite range (K@d2=+1, K@d2=-1): both endpoints approximate -> 2 budgets
    lo = d2_to_strike[1.0]
    hi = d2_to_strike[-1.0]
    assert lo < hi
    du2 = s.delta_up(lo) + s.delta_up(hi)
    tol = math.ceil(du2 * F) + CUSHION_UNITS
    ref = round((s.up_true(lo) - s.up_true(hi)) * F)
    points.append(dict(lower=lo, higher=hi, reference=ref, tolerance=tol,
                       note="(K@d2=+1, K@d2=-1] = Phi(+1)-Phi(-1)"))

    return points, worst


# ----------------------------------------------------------------------------
# Move emission
# ----------------------------------------------------------------------------
def fmt_u64(x):
    return f"{x:_}"


def emit_move(scenarios, scen_points, budget_units):
    lines = []
    w = lines.append
    w("// Copyright (c) Mysten Labs, Inc.")
    w("// SPDX-License-Identifier: Apache-2.0")
    w("//")
    w("// @generated by packages/predict/tests/helper/reference/generate_pricing_reference.py")
    w("// Source data: packages/predict/simulations/data/scenario_dataset.csv (real on-chain")
    w("// Block Scholes SVI, one market, 2026-05-27). DO NOT EDIT BY HAND — regenerate with")
    w("//   python3 generate_pricing_reference.py")
    w("//")
    w("// Independent true-math reference (Python stdlib math.log/sqrt/erf, NOT the contract")
    w("// and NOT python_replay's fixed-point pricer) for Pricer.range_price.")
    w("// Each point's `tolerance` is the analytic worst-case fixed-point error of UP=Phi(d2),")
    w("// propagated from math.move's documented per-primitive budgets at the TRUE values; see")
    w("// the generator header for the full derivation. The forward priced is the fresh-Pyth")
    w("// round-trip mul(spot, div(forward, spot)).")
    w("//")
    w(f"// Worst-case per-endpoint budget across all scenarios/strikes: {fmt_u64(budget_units)} units (@1e9).")
    w("// Dominated by the small-variance scenario at |d2|~1: d2=-(k+w/2)/sqrt(w) is")
    w("// ill-conditioned in w (w^-3/2), so a 1-ULP variance rounding moves the quote ~1e-6.")
    w("//")
    w("// Provenance (svi_event_digest @ svi_timestamp, sqrt(w_atm)):")
    for i, s in enumerate(scenarios):
        wk = s.w_of_k(0.0)
        w(f"//   [{i}] {s.digest}  {s.svi_ts[:19]}  sqrt_w_atm={math.sqrt(wk):.6f}")
    w("#[test_only]")
    w("module deepbook_predict::pricing_reference_data;")
    w("")
    w("use deepbook_predict::constants;")
    w("")
    w("const ENoSuchScenario: u64 = 0;")
    w("")
    w("/// One independent reference point: Pricer.range_price(lower, higher)")
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
    w("/// Number of real-data scenarios.")
    w(f"public fun scenario_count(): u64 {{ {len(scenarios)} }}")
    w("")
    w("/// Worst-case per-endpoint precision budget (units @1e9) over all scenarios/strikes.")
    w(f"public fun worst_case_budget(): u64 {{ {fmt_u64(budget_units)} }}")
    w("")
    w("/// Scenario spot seeded into the Propbook fixtures.")
    w("public fun creation_spot(s: u64): u64 { spot(s) }")
    w("")
    w("/// Market tick size used by every scenario.")
    w(f"public fun tick_size(_s: u64): u64 {{ {fmt_u64(TICK_SIZE)} }}")
    w("")

    def emit_u64_selector(name, values, doc):
        # Fully-expanded if/else-if/else so prettier-move leaves it untouched
        # (regeneration stays byte-identical to the committed, formatted file).
        w(f"/// {doc}")
        w(f"public fun {name}(s: u64): u64 {{")
        for i, v in enumerate(values):
            kw = "if" if i == 0 else "} else if"
            w(f"    {kw} (s == {i}) {{")
            w(f"        {fmt_u64(v)}")
        w("    } else {")
        w("        abort ENoSuchScenario")
        w("    }")
        w("}")
        w("")

    emit_u64_selector("spot", [s.spot for s in scenarios], "Real Block Scholes spot (1e9 fixed-point) seeded into the oracle.")
    emit_u64_selector("forward", [s.forward for s in scenarios], "Real Block Scholes forward (1e9) seeded into the oracle (pushed forward).")

    emit_u64_selector("svi_a", [s.a for s in scenarios], "Real SVI `a` (1e9) seeded through the Block Scholes surface update.")
    emit_u64_selector("svi_b", [s.b for s in scenarios], "Real SVI `b` (1e9) seeded through the Block Scholes surface update.")
    emit_u64_selector("svi_sigma", [s.sigma for s in scenarios], "Real SVI `sigma` (1e9) seeded through the Block Scholes surface update.")
    emit_u64_selector("svi_rho_magnitude", [s.rho_mag for s in scenarios], "Real SVI `rho` magnitude (1e9) seeded through the Block Scholes surface update.")

    def emit_bool_selector(name, values, doc):
        w(f"/// {doc}")
        w(f"public fun {name}(s: u64): bool {{")
        for i, v in enumerate(values):
            kw = "if" if i == 0 else "} else if"
            w(f"    {kw} (s == {i}) {{")
            w(f"        {str(v).lower()}")
        w("    } else {")
        w("        abort ENoSuchScenario")
        w("    }")
        w("}")
        w("")

    emit_bool_selector("svi_rho_is_negative", [s.rho_neg for s in scenarios], "Sign flag for real SVI `rho` (true == negative).")
    emit_u64_selector("svi_m_magnitude", [s.m_mag for s in scenarios], "Real SVI `m` magnitude (1e9) seeded through the Block Scholes surface update.")
    emit_bool_selector("svi_m_is_negative", [s.m_neg for s in scenarios], "Sign flag for real SVI `m` (true == negative).")

    w("/// Reference points for scenario `s` (lower, higher, true-math reference, tolerance).")
    w("public fun points(s: u64): vector<RefPoint> {")
    for i, s in enumerate(scenarios):
        kw = "if" if i == 0 else "} else if"
        w(f"    {kw} (s == {i}) {{")
        w("        vector[")
        for p in scen_points[i]:
            lo = "constants::neg_inf!()" if p["lower"] == NEG_INF else fmt_u64(p["lower"])
            hi = "constants::pos_inf!()" if p["higher"] == POS_INF else fmt_u64(p["higher"])
            w(f"            // {p['note']}")
            w(f"            pt({lo}, {hi}, {fmt_u64(p['reference'])}, {fmt_u64(p['tolerance'])}),")
        w("        ]")
    w("    } else {")
    w("        abort ENoSuchScenario")
    w("    }")
    w("}")
    w("")

    w("/// Provenance: svi_event_digest of the source CSV row for scenario `s`.")
    w("public fun svi_event_digest(s: u64): vector<u8> {")
    for i, s in enumerate(scenarios):
        kw = "if" if i == 0 else "} else if"
        w(f"    {kw} (s == {i}) {{")
        w(f'        b"{s.digest}"')
    w("    } else {")
    w("        abort ENoSuchScenario")
    w("    }")
    w("}")
    return "\n".join(lines) + "\n"


def main():
    by_digest = {}
    with open(CSV_PATH) as f:
        for row in csv.DictReader(f):
            d = row["svi_event_digest"]
            if d in SELECTED_DIGESTS and d not in by_digest:
                by_digest[d] = row
    scenarios = []
    for d in SELECTED_DIGESTS:
        if d not in by_digest:
            raise SystemExit(f"selected svi_event_digest not found in CSV: {d}")
        scenarios.append(Scenario(by_digest[d]))

    scen_points = []
    budget = 0.0
    print("=== diagnostic (true-math reference + analytic budget) ===")
    for i, s in enumerate(scenarios):
        pts, worst = build_points(s)
        scen_points.append(pts)
        budget = max(budget, worst)
        print(f"\n[{i}] {s.digest}  {s.svi_ts[:19]}")
        print(f"    spot={s.spot} forward={s.forward} forward_live={s.forward_live}")
        print(f"    a={s.a} b={s.b} rho={'-' if s.rho_neg else '+'}{s.rho_mag} "
              f"m={'-' if s.m_neg else '+'}{s.m_mag} sigma={s.sigma}")
        print(f"    grid=[{s.min_strike}, {s.max_strike}] tick={TICK_SIZE} "
              f"sqrt_w_atm={math.sqrt(s.w_of_k(0.0)):.6f}")
        for p in pts:
            lo = "-inf" if p["lower"] == NEG_INF else str(p["lower"])
            hi = "+inf" if p["higher"] == POS_INF else str(p["higher"])
            print(f"      ({lo}, {hi}] ref={p['reference']:>11} tol={p['tolerance']:>6}  {p['note']}")
        print(f"    scenario worst delta_up = {worst*F:.2f} units")

    budget_units = math.ceil(budget * F) + CUSHION_UNITS
    print(f"\n=== WORST-CASE PER-ENDPOINT BUDGET: {budget_units} units "
          f"({budget_units/F:.2e} of full scale) ===")

    move_src = emit_move(scenarios, scen_points, budget_units)
    with open(OUT_PATH, "w") as f:
        f.write(move_src)
    print(f"wrote {os.path.normpath(OUT_PATH)} ({move_src.count(chr(10))} lines)")


if __name__ == "__main__":
    main()
