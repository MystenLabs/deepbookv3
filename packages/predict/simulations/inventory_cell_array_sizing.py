"""Can a fixed inline cell array carry the inventory-impact coordinate?

The refresh currently rebuilds the grid by reading every payout-tree node, one
dynamic-field child each, and hits the 1,000-child per-transaction ceiling at the
same node count the tree is allowed to reach. The proposal is to keep a coarse
fixed-cell copy of the payout profile inline in the market object so a refresh
reads zero children.

Inline storage is only cheap if the array is small, and its resolution is fixed
while the settlement distribution narrows toward expiry. So: at a cell count
small enough to hold inline, does the coordinate still track the exact one well
enough to charge on?

Everything is exact rather than sampled. A book's payout profile is piecewise
constant, so the profile, its expectation, the continuous worst-5% average, and
the 100-bucket discretisation all have closed forms over the profile's own
segments.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from functools import lru_cache

import numpy as np

RNG_SEED = 20260820
TAIL_ALPHA = 0.05
GRID_BUCKETS = 100
TAIL_BUCKETS = 5
# Mint admission bounds a range's probability to [1%, 99%], so no admissible
# strike sits outside those quantiles of the surface it was quoted against.
MIN_ENTRY_PROBABILITY = 0.01


# --------------------------------------------------------------------- the law
@dataclass(frozen=True)
class Law:
    """Settlement law: forward `f`, total variance `w`, optional fat tail."""

    f: float
    w: float
    student_df: int | None = None

    @property
    def sd(self) -> float:
        return math.sqrt(self.w)

    def ppf(self, u):
        u = np.asarray(u, dtype=float)
        z = _norm_ppf(u) if self.student_df is None else _t_unit_ppf(u, self.student_df)
        return self.f * np.exp(-self.w / 2.0 + self.sd * z)

    def cdf(self, x):
        x = np.asarray(x, dtype=float)
        out = np.empty_like(x)
        finite = np.isfinite(x) & (x > 0)
        z = np.zeros_like(x)
        z[finite] = (np.log(x[finite] / self.f) + self.w / 2.0) / self.sd
        cdf = _norm_cdf(z) if self.student_df is None else _t_unit_cdf(z, self.student_df)
        out[finite] = cdf[finite]
        out[~finite] = np.where(x[~finite] > 0, 1.0, 0.0)
        return out

    def survival(self, x):
        return 1.0 - self.cdf(x)


def _norm_cdf(z):
    from math import erf
    return 0.5 * (1.0 + np.vectorize(erf)(np.asarray(z, float) / math.sqrt(2.0)))


def _norm_ppf(u):
    a = [-3.969683028665376e01, 2.209460984245205e02, -2.759285104469687e02,
         1.383577518672690e02, -3.066479806614716e01, 2.506628277459239e00]
    b = [-5.447609879822406e01, 1.615858368580409e02, -1.556989798598866e02,
         6.680131188771972e01, -1.328068155288572e01]
    c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e00,
         -2.549732539343734e00, 4.374664141464968e00, 2.938163982698783e00]
    d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e00,
         3.754408661907416e00]
    u = np.asarray(u, dtype=float)
    out = np.zeros_like(u)
    lo, hi = u < 0.02425, u > 1 - 0.02425
    mid = ~(lo | hi)
    if lo.any():
        q = np.sqrt(-2 * np.log(u[lo]))
        out[lo] = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / \
                  ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
    if hi.any():
        q = np.sqrt(-2 * np.log(1 - u[hi]))
        out[hi] = -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / \
                   ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
    q = u[mid] - 0.5
    r = q * q
    out[mid] = (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q / \
               (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
    return out


@lru_cache(maxsize=8)
def _t_lattice(df: int):
    grid = np.linspace(-60.0, 60.0, 600_001)
    coef = math.gamma((df + 1) / 2.0) / (math.sqrt(df * math.pi) * math.gamma(df / 2.0))
    dens = coef * (1.0 + grid ** 2 / df) ** (-(df + 1) / 2.0)
    cdf = np.cumsum(dens) * (grid[1] - grid[0])
    return grid, cdf / cdf[-1]


def _t_unit_cdf(z, df: int):
    grid, cdf = _t_lattice(df)
    return np.interp(np.asarray(z, float) * math.sqrt(df / (df - 2.0)), grid, cdf)


def _t_unit_ppf(u, df: int):
    grid, cdf = _t_lattice(df)
    return np.interp(np.asarray(u, float), cdf, grid) / math.sqrt(df / (df - 2.0))


# -------------------------------------------------------------------- the book
@dataclass(frozen=True)
class Order:
    lower: float   # 0.0 = open lower
    upper: float   # inf = open upper
    quantity: float


def profile(orders: list[Order]) -> tuple[np.ndarray, np.ndarray]:
    """Piecewise-constant payout profile as (edges, values).

    `values[i]` is owed if settlement lands in `(edges[i], edges[i + 1]]`.
    Built by boundary deltas and a prefix sum, exactly as the payout tree does.
    """
    cuts = {0.0, math.inf}
    for o in orders:
        if o.lower > 0:
            cuts.add(o.lower)
        if not math.isinf(o.upper):
            cuts.add(o.upper)
    edges = np.array(sorted(cuts))
    delta = np.zeros(edges.size)
    for o in orders:
        delta[np.searchsorted(edges, o.lower)] += o.quantity
        if not math.isinf(o.upper):
            delta[np.searchsorted(edges, o.upper)] -= o.quantity
    return edges, np.cumsum(delta)[:-1]


def segment_mass(edges: np.ndarray, law: Law) -> np.ndarray:
    c = law.cdf(edges)
    return np.diff(c)


def expected_payout(edges, values, law) -> float:
    return float((values * segment_mass(edges, law)).sum())


def truth_k(edges, values, law) -> float:
    """Average payout over the worst 5% of outcomes, minus expected payout.

    Exact: the payout is constant on each segment, so the worst 5% is found by
    sorting segments by payout and walking down until 5% of mass is consumed.
    """
    mass = segment_mass(edges, law)
    order = np.argsort(values)[::-1]
    v, m = values[order], mass[order]
    cum = np.cumsum(m)
    take = int(np.searchsorted(cum, TAIL_ALPHA))
    used = m[:take].sum() if take else 0.0
    total = float((v[:take] * m[:take]).sum())
    if take < v.size:
        total += v[take] * (TAIL_ALPHA - used)
    tail = total / TAIL_ALPHA
    return tail - float((values * mass).sum())


def bucket_maxima(edges, values, bucket_edges: np.ndarray) -> np.ndarray:
    """Largest payout reachable inside each bucket. Exact over segments."""
    seg_lo, seg_hi = edges[:-1], edges[1:]
    out = np.zeros(GRID_BUCKETS)
    for i in range(GRID_BUCKETS):
        lo, hi = bucket_edges[i], bucket_edges[i + 1]
        start = int(np.searchsorted(seg_hi, lo, side="right"))
        stop = int(np.searchsorted(seg_lo, hi, side="left"))
        if stop > start:
            out[i] = values[start:stop].max()
    return out


def k_from_maxima(maxima: np.ndarray, e: float) -> float:
    top = np.partition(maxima, -TAIL_BUCKETS)[-TAIL_BUCKETS:]
    return max(0.0, float(top.mean()) - e)


def quantile_edges(law: Law) -> np.ndarray:
    interior = law.ppf(np.arange(1, GRID_BUCKETS) / GRID_BUCKETS)
    return np.concatenate(([0.0], np.asarray(interior, float), [math.inf]))


def generate_book(rng, law: Law, n: int) -> list[Order]:
    """Mixed flow: mostly near-the-money up/down, a minority narrower ranges."""
    out: list[Order] = []
    while len(out) < n:
        q = float(rng.integers(1, 20)) * 100.0
        if rng.random() < 0.7:
            strike = float(law.ppf(np.array([rng.uniform(0.15, 0.85)]))[0])
            o = Order(strike, math.inf, q) if rng.random() < 0.5 else Order(0.0, strike, q)
        else:
            centre = rng.uniform(0.1, 0.9)
            half = rng.uniform(0.02, 0.12)
            lo, hi = law.ppf(np.array([max(1e-6, centre - half),
                                       min(1 - 1e-6, centre + half)]))
            o = Order(float(lo), float(hi), q)
        p = _range_probability(o, law)
        if MIN_ENTRY_PROBABILITY <= p <= 1.0 - MIN_ENTRY_PROBABILITY:
            out.append(o)
    return out


def _range_probability(o: Order, law: Law) -> float:
    hi = 0.0 if math.isinf(o.upper) else float(law.survival(np.array([o.upper]))[0])
    lo = float(law.survival(np.array([o.lower]))[0]) if o.lower > 0 else 1.0
    return max(0.0, lo - hi)


# -------------------------------------------------------------- the cell array
@dataclass(frozen=True)
class CellArray:
    edges: np.ndarray

    @property
    def count(self) -> int:
        return self.edges.size - 1

    @property
    def inline_bytes(self) -> int:
        # One `u64` of net payout per cell. Unlike the payout tree this needs no
        # signed start/end pair: a cell holds an absolute non-negative payout, and
        # a range order adds its quantity to each covered cell directly, so a
        # negative intermediate is never representable.
        return 8 * self.count


def build_cells(creation: Law, n_cells: int, span_sd: float) -> CellArray:
    half = span_sd * creation.sd
    lo = creation.f * math.exp(-creation.w / 2 - half)
    hi = creation.f * math.exp(-creation.w / 2 + half)
    inner = np.exp(np.linspace(math.log(lo), math.log(hi), n_cells - 1))
    # The two open ends absorb anything outside the span so the array always
    # represents the whole price line.
    return CellArray(np.concatenate(([0.0], inner, [math.inf])))


def cell_values(orders: list[Order], cells: CellArray, conservative: bool) -> np.ndarray:
    """Per-cell payout after snapping order edges onto cell edges."""
    edges = cells.edges
    delta = np.zeros(cells.count + 1)
    for o in orders:
        if conservative:
            # Widen to every cell the order touches: the stored profile then
            # dominates the true one everywhere.
            lo_i = max(0, int(np.searchsorted(edges, o.lower, side="right")) - 1)
            hi_i = cells.count if math.isinf(o.upper) else \
                min(cells.count, int(np.searchsorted(edges, o.upper, side="left")))
        else:
            lo_i = int(np.clip(np.argmin(np.abs(edges[:-1] - o.lower)), 0, cells.count))
            hi_i = cells.count if math.isinf(o.upper) else \
                int(np.clip(np.argmin(np.abs(edges[:-1] - o.upper)), 0, cells.count))
        if hi_i <= lo_i:
            hi_i = min(cells.count, lo_i + 1)
        delta[lo_i] += o.quantity
        delta[hi_i] -= o.quantity
    return np.cumsum(delta)[:-1]


def cell_coordinate(values: np.ndarray, cells: CellArray,
                    bucket_edges: np.ndarray, law: Law) -> float:
    """The grid coordinate rebuilt from the inline cells alone, no tree read."""
    maxima = bucket_maxima(cells.edges, values, bucket_edges)
    e = float((values * segment_mass(cells.edges, law)).sum())
    return k_from_maxima(maxima, e)


# ------------------------------------------------------------------- the sweep
def _charge(k_before: float, k_after: float, b_k: float) -> float:
    return max(0.0, (k_after ** 2 - k_before ** 2) / (2.0 * b_k))


def run(n_cells_grid=(256, 512, 1024, 2048), span_sd=4.0,
        elapsed=(0.0, 0.25, 0.5, 0.75, 0.9, 0.99),
        n_books=40, n_orders=140, n_trades=60, student_df=None,
        conservative=False, life_hours=3.0, sigma_annual=0.55, f0=72_000.0,
        spot_drift_sd=0.0):
    """Score the inline cell array as a substitute for reading the payout tree.

    The primary question is fidelity to the exact grid, not to the continuous
    measure: the grid's own economics are already established, so a cell array
    that reproduces the grid's charge inherits them. The continuous measure is
    carried alongside only to show where both sit.
    """
    rng = np.random.default_rng(RNG_SEED)
    w0 = (sigma_annual ** 2) * (life_hours / (24 * 365))
    creation = Law(f0, w0, student_df)
    cells = {n: build_cells(creation, n, span_sd) for n in n_cells_grid}

    law_name = "lognormal" if student_df is None else f"student-t df={student_df}"
    print(f"forward ${f0:,.0f} · {life_hours:g}h life · vol {sigma_annual:.0%} "
          f"· creation sd {creation.sd:.3%} · {law_name}")
    print(f"snapping {'conservative' if conservative else 'nearest'} · "
          f"spot drift {spot_drift_sd:+.1f} creation sd · "
          f"{n_books} books × {n_trades} trades per point")
    print(f"cell span ±{span_sd:g} creation sd = "
          f"${creation.f * math.exp(-span_sd * creation.sd):,.0f}"
          f" .. ${creation.f * math.exp(span_sd * creation.sd):,.0f}")
    for n, c in cells.items():
        mid = c.count // 2
        print(f"   {n:>5} cells · {c.inline_bytes / 1024:>5.1f} KB inline · "
              f"centre cell {(c.edges[mid + 1] / c.edges[mid] - 1) * 1e4:>5.2f} bp")
    print()

    rows = []
    for frac in elapsed:
        law = Law(f0 * math.exp(spot_drift_sd * creation.sd),
                  w0 * max(1e-9, 1.0 - frac), student_df)
        bedges = quantile_edges(law)
        mid = GRID_BUCKETS // 2
        bucket_bp = (bedges[mid + 1] / bedges[mid] - 1) * 1e4

        grid_charges: list[float] = []
        truth_charges: list[float] = []
        cell_charges = {n: [] for n in n_cells_grid}

        for _ in range(n_books):
            book = generate_book(rng, law, n_orders)
            e0, v0 = profile(book)
            b_k = max(1.0, truth_k(e0, v0, law))
            base_truth = truth_k(e0, v0, law)
            base_grid = k_from_maxima(bucket_maxima(e0, v0, bedges),
                                      expected_payout(e0, v0, law))
            base_cell = {n: cell_coordinate(cell_values(book, cells[n], conservative),
                                            cells[n], bedges, law) for n in n_cells_grid}

            for cand in generate_book(rng, law, n_trades):
                after = book + [cand]
                ea, va = profile(after)
                truth_charges.append(_charge(base_truth, truth_k(ea, va, law), b_k))
                grid_charges.append(
                    _charge(base_grid, k_from_maxima(bucket_maxima(ea, va, bedges),
                                                     expected_payout(ea, va, law)), b_k))
                for n in n_cells_grid:
                    cell_charges[n].append(
                        _charge(base_cell[n],
                                cell_coordinate(cell_values(after, cells[n], conservative),
                                                cells[n], bedges, law), b_k))

        g = np.array(grid_charges)
        t = np.array(truth_charges)
        stats = {}
        for n in n_cells_grid:
            c = np.array(cell_charges[n])
            billed = g > 0
            rel = np.abs(c[billed] - g[billed]) / g[billed] if billed.any() else np.array([0.0])
            missed = billed & (c == 0)
            stats[n] = {
                "ratio": c.sum() / max(g.sum(), 1e-12),
                "corr": float(np.corrcoef(c, g)[0, 1]) if c.std() > 0 and g.std() > 0 else float("nan"),
                "p50": float(np.median(rel)),
                "p90": float(np.quantile(rel, 0.90)),
                "missed": float(missed.sum() / max(billed.sum(), 1)),
                # What those missed trades were worth, which is the number that
                # matters: a miss on a trade the tree barely charges costs nothing.
                "missed_rev": float(g[missed].sum() / max(g.sum(), 1e-12)),
            }
        rows.append((frac, bucket_bp, g.sum() / max(t.sum(), 1e-12), stats))

    print(f"{'elapsed':>7} {'bucket':>9} {'grid/true':>10} | "
          f"{'cells':>5} {'cell/grid':>9} {'corr':>6} {'p50 err':>8} {'p90 err':>8} "
          f"{'missed':>7} {'miss $':>7}")
    print("-" * 92)
    for frac, bp, gt, stats in rows:
        for i, n in enumerate(n_cells_grid):
            s = stats[n]
            lead = f"{frac:>6.0%} {bp:>8.2f}bp {gt:>10.3f}" if i == 0 else " " * 27
            print(f"{lead} | {n:>5} {s['ratio']:>9.3f} {s['corr']:>6.3f} "
                  f"{s['p50']:>7.1%} {s['p90']:>7.1%} {s['missed']:>6.1%} "
                  f"{s['missed_rev']:>6.2%}")
        print()
    print("cell/grid 1.000 = the inline array bills exactly what reading the tree bills.")
    print("corr = per-trade charge correlation; err = relative charge error on billed trades;")
    print("missed = trades the tree bills but the cell array bills zero.")
    return rows


VARIANTS = {
    "baseline": {},
    "drift-up": dict(spot_drift_sd=2.0),
    "drift-down": dict(spot_drift_sd=-2.0),
    "conservative": dict(conservative=True),
    "fat-tail": dict(student_df=4),
}

VARIANT_SWEEP = dict(n_cells_grid=(512, 1024, 2048), elapsed=(0.0, 0.5, 0.9, 0.99),
                     n_books=25, n_trades=60)


def main() -> None:
    import sys

    names = sys.argv[1:] or ["baseline"]
    if names == ["all"]:
        names = list(VARIANTS)
    for name in names:
        if name not in VARIANTS:
            raise SystemExit(f"unknown variant {name!r}; choose from {list(VARIANTS)} or 'all'")
        print("=" * 92)
        print(name.upper())
        print("=" * 92)
        kwargs = dict(VARIANTS[name])
        if name != "baseline":
            kwargs = {**VARIANT_SWEEP, **kwargs}
        run(**kwargs)
        print()


if __name__ == "__main__":
    main()
