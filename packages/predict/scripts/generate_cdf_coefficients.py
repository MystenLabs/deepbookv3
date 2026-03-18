"""
Generate all math constants for math_optimized.move.

Outputs:
  1. ln() constants: precomputed reciprocals (1/k) and ln(2)
  2. normal_cdf() constants: 16 piecewise cubic polynomial coefficients

Usage:
    python scripts/generate_cdf_coefficients.py

Requires only the Python standard library (math.erfc).
"""
import math

FLOAT_SCALING = 1_000_000_000
NUM_SEGMENTS = 16
DOMAIN_MAX = 4.0


def norm_cdf(x: float) -> float:
    """Standard normal CDF via erfc."""
    return 0.5 * math.erfc(-x / math.sqrt(2))


def fit_cubic(xs, ys):
    """Fit cubic through 4 points via Gaussian elimination."""
    n = 4
    Ab = [[xi**j for j in range(n)] + [yi] for xi, yi in zip(xs, ys)]
    for col in range(n):
        pivot = max(range(col, n), key=lambda r: abs(Ab[r][col]))
        Ab[col], Ab[pivot] = Ab[pivot], Ab[col]
        for row in range(col + 1, n):
            f = Ab[row][col] / Ab[col][col]
            for j in range(col, n + 1):
                Ab[row][j] -= f * Ab[col][j]
    coeffs = [0.0] * n
    for i in range(n - 1, -1, -1):
        coeffs[i] = (Ab[i][n] - sum(Ab[i][j] * coeffs[j] for j in range(i + 1, n))) / Ab[i][i]
    return coeffs


def generate_ln_constants():
    """Precomputed reciprocals for Horner-form ln series and ln(2)."""
    print("// === ln() constants ===")
    print(f"const LN2: u64 = {round(math.log(2) * FLOAT_SCALING)};")
    print()
    for k in [3, 5, 7, 9, 11, 13]:
        val = round(FLOAT_SCALING / k)
        print(f"const INV_{k}: u64 = {val};  // round(1e9 / {k})")
    print()


def generate_cdf_constants():
    """16-segment piecewise cubic CDF coefficients."""
    width = DOMAIN_MAX / NUM_SEGMENTS
    overall_max_err = 0.0

    print(f"// === normal_cdf() segment boundaries ===")
    for i in range(1, NUM_SEGMENTS + 1):
        val = round(i * width * FLOAT_SCALING)
        print(f"const B{i}: u64 = {val};")
    print()

    print(f"// === normal_cdf() constants: {NUM_SEGMENTS} segments on [0, {DOMAIN_MAX}] ===")
    print(f"// P(x) = A + B*x - C*x^2 +/- D*x^3")
    print()

    for seg in range(NUM_SEGMENTS):
        lo = seg * width
        hi = lo + width
        xs = [lo + i * width / 3 for i in range(4)]
        ys = [norm_cdf(x) for x in xs]
        a, b, c, d = fit_cubic(xs, ys)

        max_err = 0.0
        for i in range(1001):
            tx = lo + width * i / 1000
            exact = norm_cdf(tx)
            approx = a + b * tx + c * tx**2 + d * tx**3
            max_err = max(max_err, abs(exact - approx))
        overall_max_err = max(overall_max_err, max_err)

        a_s = int(round(a * FLOAT_SCALING))
        b_s = int(round(b * FLOAT_SCALING))
        c_s = int(round(c * FLOAT_SCALING))
        d_s = int(round(d * FLOAT_SCALING))

        print(f"// Segment {seg}: [{lo:.2f}, {hi:.2f})  max_err={max_err:.2e} ({max_err*10000:.4f} bp)")
        print(f"const SEG{seg}_A: u64 = {abs(a_s)};")
        print(f"const SEG{seg}_B: u64 = {abs(b_s)};")
        print(f"const SEG{seg}_C: u64 = {abs(c_s)};")
        print(f"const SEG{seg}_D: u64 = {abs(d_s)}; // {'negative' if d_s < 0 else 'positive'}")
        print()

    print(f"// Overall max error: {overall_max_err:.2e} ({overall_max_err*10000:.4f} bp)")


if __name__ == "__main__":
    generate_ln_constants()
    generate_cdf_constants()
