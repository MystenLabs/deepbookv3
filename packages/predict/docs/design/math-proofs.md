# Mathematical proofs for Predict pricing and accounting

This document records the mathematical arguments behind Predict's fixed-point
pricing certificates, directed rounding, payout-tree accounting, NAV bid/ask,
and exact-subtraction invariants. It proves formulas, not source freshness:
Move source and Move tests remain authoritative. Every result below therefore
names the function that implements it and the tests that pin its behavior.

The statements are deliberately separated into three classes:

- **Theorem:** a symbolic argument valid for every input satisfying the stated
  assumptions.
- **Induction:** a theorem over all states reachable through an enumerated set
  of state transitions.
- **Counterexample:** one reachable input refuting a proposed stronger claim.

Finite searches and sampled market data are not mathematical proofs. In
particular, the measured mint-availability percentages and bounded
partial-close fragmentation maxima are evidence, not results in this document.

## 1. Notation and integer-rounding lemmas

Let `S = 1,000,000,000`, the fixed-point scale. A nonnegative integer `x`
represents the real number `x / S`. For nonnegative integers `a`, `b`, and
positive `d`, define

```text
down(a, b; d) = floor(a b / d)
up(a, b; d)   = ceil(a b / d)
```

`math::mul_down(a, b)` and `math::mul_up(a, b)` use `d = S`;
`math::div_down(a, b)` and `math::div_up(a, b)` use numerator `a S`;
the three-argument helpers use the supplied denominator.

### Theorem 1.1 — Every directed collapse has a sub-unit residual

By Euclidean division, `a b = q d + r` for unique integers `q` and `r` with
`0 <= r < d`. Therefore

```text
down(a, b; d) = q
a b / d - down(a, b; d) = r / d, in [0, 1)
```

and

```text
up(a, b; d) = q                  when r = 0
up(a, b; d) = q + 1              when r > 0
up(a, b; d) - a b / d = 0        when r = 0
up(a, b; d) - a b / d = 1-r/d    when r > 0.
```

Dust exists exactly when `r != 0`; its magnitude is strictly less than one raw
output unit. A down-rounded transfer leaves the residual with the sender. An
up-rounded transfer assigns the complementary residual to the recipient.

### Theorem 1.2 — Exact complements conserve every stored atom

If a stored total `T` is split by first computing `A` and then setting
`B = T - A`, then `A + B = T` exactly. No independent rounding occurs in the
second leg. This is stronger than separately computing two rounded fractions,
whose residuals need not add to `T`.

This theorem is used for the mint premium/floor split and partial-close
floor-share split.

### Non-equivalence of staged and fused rounding

In general,

```text
floor(floor(a b / S) c / d) != floor(a b c / (S d)),
ceil(floor(a b / S) S / d) != ceil(a b / d).
```

The first floor discards a remainder before the second operation. It may be
removed only when a separate quotient-remainder argument proves that the
discarded remainder cannot cross the later integer boundary. This is why the
mint entry-value collapse and the subsequent premium division remain staged.

## 2. `Approx` interval algebra

An `Approx` with signed center `c` and radius `e` represents the assertion

```text
true value x satisfies |x - c| <= e
```

in raw fixed-point units. The arithmetic below bounds numerical approximation
along the branch selected by the contract. It does not include uncertainty
about taking a different economic branch.

Implementation: `fixed_math::approx`.

### Theorem 2.1 — Linear operations

If `|x-a| <= ea` and `|y-b| <= eb`, the triangle inequality gives

```text
|(x+y) - (a+b)| <= ea + eb
|(x-y) - (a-b)| <= ea + eb.
```

Negation preserves the radius. Doubling adds the ball to itself and therefore
doubles both center and radius exactly.

The projections `max(0,x)`, `min(U,x)`, and their composition onto `[0,U]` are
1-Lipschitz:

```text
|project(x) - project(y)| <= |x-y|.
```

Consequently `clamp_nonnegative`, `clamp_upper`, and
`clamp_unit_interval` retain the incoming radius.

### Theorem 2.2 — Scaled multiplication

Write `x = a + da` and `y = b + db`, with `|da| <= ea` and
`|db| <= eb`. Then

```text
x y - a b = a db + b da + da db
|x y - a b| <= |a| eb + |b| ea + ea eb.
```

After division by `S`, upward rounding each error term and adding one raw unit
for the center's fixed-point truncation encloses the product. A certified exact
zero is absorbing: when `a = ea = 0`, the true input is exactly zero, so both
the product center and radius are zero.

### Theorem 2.3 — Scaled square

With `x = a + d` and `|d| <= e`,

```text
x^2 - a^2 = 2 a d + d^2
|x^2 - a^2| <= 2 |a| e + e^2.
```

Upward scaling of those terms plus one center-rounding unit yields the radius
used by `square_scaled`.

### Theorem 2.4 — Scaled division

Assume `|b| > eb`, so the denominator ball excludes zero. For
`x = a + da` and `y = b + db`,

```text
x/y - a/b = da/y - a db/(b y).
```

Since `|y| >= |b|-eb`,

```text
|x/y - a/b|
  <= ea/(|b|-eb)
   + |a| eb/(|b| (|b|-eb)).
```

`div_scaled` rounds both terms upward and adds one raw center-rounding unit. If
the denominator ball reaches zero, no finite quotient radius follows; the
function returns the maximum error sentinel so every value-transferring
precision gate rejects the result.

### Theorem 2.5 — Fused multiply-divide

Assume the denominator ball excludes zero. If both numerator-factor balls keep
their signs, quotient magnitude is monotone in the three magnitudes and lies
within

```text
((|a|-ea)(|b|-eb))/(|c|+ec)
    <= |a b / c| <=
((|a|+ea)(|b|+eb))/(|c|-ec).
```

Outward integer evaluation of those corners therefore encloses the true
quotient. If either numerator factor crosses zero, either output sign is
possible; the distance from the canonical signed center is bounded by the sum
of its magnitude and the farthest upper-corner magnitude. This is the bound
implemented by `Approx::mul_div_down`.

### Theorem 2.6 — Logarithm, square root, CDF, and PDF

For a positive logarithm input with lower endpoint `x-e > 0`, the mean-value
theorem and `d ln(t)/dt = 1/t` give

```text
|ln(x+d)-ln(x)| <= e/(x-e).
```

`ln_ratio` either applies this to the positive rounded ratio or subtracts two
certified exact-input logarithms.

Square root is monotone. Evaluating the lower and upper input endpoints gives

```text
sqrt(max(0,x-e)) <= sqrt(true input) <= sqrt(x+e).
```

The larger endpoint distance from the center root, plus the primitive's
one-unit leaf bound, encloses the result. The upper endpoint is evaluated in
`u128`, so `x+e` need not fit in `u64`.

For the normal CDF, `Phi'(x)=phi(x)`. Evaluating the maximum PDF over the input
interval and multiplying it by the input radius bounds propagation; the CDF
primitive's leaf error is then added. For the normal PDF,
`|phi'(x)|=|x|phi(x)` has global maximum `phi(1)<0.242`, so
`0.242 e` plus the PDF leaf error is a global bound.

### Maximum-error semantics

Saturating error arithmetic is an uncertifiable sentinel, not a claim that
`u64::MAX` is mathematical infinity. Sound value transfer relies on
`true_relative_deviation_within` rejecting such a result at mint or pool-NAV
boundaries. Center-only close and liquidation intentionally select the
canonical center under their separate economic policy.

Pins:

- `packages/fixed_math/tests/math/approx_tests.move`
- `packages/predict/tests/pricing/precision_guard_tests.move`
- `packages/predict/tests/flows/precision_policy_flow_tests.move`
- `packages/predict/tests/flows/pool_valuation_flow_tests.move`

## 3. Retained-precision variance projection

Implementation:
`pricing::variance_denominator_terms` and `pricing::compute_up_price`.

Let `C` be the nonnegative wide total-variance center at scale `S^2`, and let
`E` bound its wide error. The canonical 1e9-scale total variance is
`floor(C/S)`.

### Theorem 3.1 — Direct half-variance center is bit-identical

Write `C = 2 S k + r`, where `0 <= r < 2 S`. Then

```text
floor(floor(C/S)/2)
  = floor((2k + floor(r/S))/2)
  = k
  = floor(C/(2S)).
```

Thus constructing `w/2` directly from the wide center preserves the old
canonical center while avoiding the discarded intermediate `Approx`.

### Theorem 3.2 — Direct half-variance radius

The exact wide value lies in `[C-E,C+E]`. Division by `2S` scales its deviation
by at most `E/(2S)`. The integer center floor contributes less than one
additional raw unit, so

```text
ceil(E/(2S)) + 1
```

is a valid integer radius. The final `+1` is necessary: with `E=0` and
`C` not divisible by `2S`, radius zero would exclude the non-integer exact
value.

### Theorem 3.3 — Wide square-root enclosure

Square root is monotone, so evaluating

```text
sqrt_down(max(0,C-E)),
sqrt_down(C),
sqrt_up(C+E)
```

and taking the larger distance from the center encloses every square root of a
wide value in `[C-E,C+E]`.

The retained-precision island ends at `w/2` and `sqrt(w)`. Log-moneyness, SVI
geometry, slope, CDF/PDF, and final price remain in the ordinary `Approx`
algebra. The measured availability improvement is empirical and is not part of
these theorems.

Pins:

- `packages/predict/tests/pricing/pricing_exact_tests.move`
- `packages/predict/tests/pricing/pricing_reference_data.move`
- `packages/predict/tests/pricing/precision_guard_tests.move`

## 4. Directed money collapses and dust ownership

Theorem 1.1 proves the bound at every row below. The table records which party
retains the residual when the exact real-number amount is not integral.
Intermediate rates have no custody owner until a later money collapse.

| Atom and source | Integer form | Consequence of the residual |
| --- | --- | --- |
| Rebate reserve, `expiry_cash_config::rebate_reserve_for_fee_basis` | `floor(fees*rate/S)` | Unreserved dust remains in expiry/LP cash. |
| Stake benefit, `stake_config::benefit_ratio` | Piecewise floor | Benefit never exceeds the exact curve; no direct custody leg. |
| Discounted fee, `stake_config::fee_amount_after_discount` | `amount-floor(amount*discount/S)` | The result is the ceiling of the complementary fee; fee dust stays in expiry cash. |
| Stake rebate, `stake_config::rebate_amount` | Floor | Claimant receives no more than the exact rebate. |
| Trading fee, `strike_exposure_config::trading_fee` | Final ceiling | Fractional fee dust is collected into expiry cash. |
| Mint entry value, `strike_exposure_config::assert_mint_admission` | Floor | Defines one stored integer atom; premium and floor split that atom exactly. |
| Net premium, `strike_exposure_config::net_premium_from_entry_value` | Ceiling | Premium dust goes to expiry cash; the complementary stored floor rounds down. |
| Fee-rate construction, `strike_exposure_config::fee_rate` | Intermediate floors | Final money transfer is still the upward-rounded trading fee. |
| EWMA penalty, `ewma::penalty_fee` | Final ceiling | Penalty dust goes to expiry cash. |
| Fee-incentive subsidy, `expiry_market::fee_incentive_subsidy_amount` | Floor then cap | Residual remains in the sponsor reserve. |
| Builder fee, `expiry_market::builder_fee_amount` | Minimum of two floors | Residual stays with the trader; this is a peer-to-peer fee, not protocol custody. |
| LP supply, `lp_book::quote_supply_shares` | Fused floor | Supplier receives no more than the ask-priced entitlement. |
| LP withdrawal, `lp_book::quote_withdraw_dusdc` | Fused floor | Withdrawer receives no more than the bid-priced entitlement. |
| Fee-incentive target/cap, `plp::sync_fee_incentives` and `pool_accounting::register_expiry` | Floor | Both sides are protocol-controlled custody; residual remains in the reserve. |
| Expiry rebalance buffer, `plp::expiry_rebalance_cash_terms` | Floor | Residual remains idle in LP custody. |
| Protocol profit cut, `plp::materialize_expiry_profit` | Floor | Residual remains with LPs. |
| Live payout buffer, `strike_exposure::payout_liability` | Floor | Only optional early-exit liquidity is reduced; the exact settlement floor is unchanged. |
| Live close gross, `strike_exposure::quote_live_close` | Floor | User-facing gross payout never exceeds the exact mark. |
| Live order gross, `strike_exposure::gross_order_value` | Floor | Center-only liquidation and correction use the canonical down-rounded mark. |
| NAV bid/ask, `plp::pool_nav_bid_ask` | Exact endpoint subtraction/addition | No new rounding is introduced at the policy boundary. |

### Theorem 4.1 — Discount complement rounds the charged fee upward

Let `D=floor(A d/S)`. Then

```text
A-D = ceil(A(S-d)/S).
```

This follows from the integer identity
`n-floor(x)=ceil(n-x)` for integer `n`. Consequently flooring the discount
cannot undercharge the complementary fee.

### Theorem 4.2 — Premium and floor conserve entry value

For entry probability `p`, quantity `Q`, and leverage `L>=S`, Move stores

```text
E = floor(p Q / S)
N = ceil(E S / L)
F = E - N.
```

Because `L>=S`, `N<=E`, so the subtraction is total. By construction
`N+F=E` exactly. `N` is not below the exact premium on the stored entry atom,
and every premium rounding atom reduces `F` by the same atom.

### Theorem 4.3 — Exact-amount search is maximal over lot quantities

`E(Q)=floor(pQ/S)` is nondecreasing in `Q`, and
`N(Q)=ceil(E(Q)S/L)` is nondecreasing in `E`. Their composition is therefore
nondecreasing over lot-aligned quantities. The upper-bound binary search in
`strike_exposure::quote_mint_terms` returns the greatest lot count satisfying
`N(Q)<=budget`. Admission recomputes the same `E` and calls the same
`net_premium_from_entry_value`, so the search predicate and charged premium
are bit-identical.

Pins:

- `packages/predict/tests/config/strike_exposure_config_tests.move`
- `packages/predict/tests/flows/mint_exact_amount_tests.move`
- `packages/predict/tests/flows/quote_mint_tests.move`
- `packages/predict/tests/ewma_tests.move`
- `packages/predict/tests/plp/lp_book_tests.move`

## 5. Partial-close floor allocation

Implementation: `strike_exposure::quote_live_close`.

Let an order have quantity `Q`, floor `F`, close quantity `C`, and survivor
quantity `R=Q-C`. Move computes

```text
Fr = floor(F R / Q)
Fc = F - Fr.
```

### Theorem 5.1 — Conservation and survivor protection

The exact complement gives `Fr+Fc=F`. Also

```text
Fr/R <= F/Q
```

for `R>0`, because `Fr<=FR/Q`. Thus a partial close cannot increase the
survivor's floor ratio or move it closer to knockout merely through floor
allocation.

Using `FR = FQ-FC` and the identity
`n-floor(n-x)=ceil(x)` for integer `n`,

```text
Fc = F-floor(FR/Q) = ceil(FC/Q).
```

The closed slice therefore carries the unique residual atom required by exact
floor conservation and survivor-down rounding.

### Theorem 5.2 — The allocation conflict is unavoidable without extra state

If `FC` is not divisible by `Q`, then

```text
floor(FC/Q) + floor(FR/Q) = F-1.
```

Therefore no integer split can simultaneously:

1. conserve `F`,
2. give the survivor at most its proportional floor, and
3. give the closed slice at most its proportional floor.

One residual atom must go to a slice or to separately stored dust state. The
current policy assigns it to the closed slice so the survivor is not worsened.

### Counterexample 5.3 — Live-close positive part is reachable

The following mint-valid order is live and not liquidatable:

```text
entry probability = 10,000,000
quantity          = 200,000,000
leverage          = 1,005,000,000
entry value E     = 2,000,000
net premium N     = 1,990,050
floor F           = 9,950
live probability  = 58,530
close quantity C  = 10,000
```

Its full live gross is `11,706`, and
`ceil(11,706 * 0.85)=9,951>F`, so it is not liquidatable. The partial split
gives `Fc=1`, while
`floor(58,530*10,000/S)=0`. Plain `gross-Fc` underflows; the economically
correct limited-recourse payout is `max(0,gross-Fc)=0`.

Consequently `saturating_sub` in `quote_live_close` is a required positive-part
operation, not defensive arithmetic.

### Counterexample 5.4 — Discounted proceeds are path-dependent

A mint-reachable one-floor-atom order exists at entry probability `990,000,000`,
quantity `1,020,000`, and leverage `1,000,000,991`. At live probability
`40,000`, closing `60,000` units once and closing `10,000` then `50,000`
preserve the same total quantity and do not worsen the survivor. Under the
maximum stake discount, the split path yields one more raw DUSDC atom because
the per-close positive part and fee discount are nonlinear. Without the
discount, the two paths agree for this witness.

This counterexample proves non-path-independence. It does not establish a
global maximum advantage over arbitrary quantities, price paths, or future
configuration.

Pins:

- `packages/predict/tests/strike_exposure/strike_exposure_c1_tests.move`
- `packages/predict/tests/flows/backing_buffer_flow_tests.move`
- `packages/predict/tests/flows/settled_solvency_boundary_tests.move`

## 6. Payout-tree algebra

### Theorem 6.1 — One signed shared-boundary product is certified

At one finite boundary, let price center/radius be `(p,r)`, starts be `s`, ends
be `e`, and signed net quantity be `q=s-e`. The exact real-number contribution
under the selected price branch is `P q/S`. The integer center is truncation
toward zero:

```text
center = trunc(p q / S).
```

Its fixed-point residue has magnitude less than one raw unit. Price uncertainty
contributes at most `r|q|/S`, so

```text
ceil(r|q|/S) + 1
```

encloses the local term. If `q=0`, exact-zero absorption returns zero center
and zero radius. Summing boundary balls certifies the complete signed linear
walk. With at most 1,000 finite payout-tree nodes, the structural product
residue alone is at most 1,000 raw DUSDC atoms per expiry.

Grouping by shared boundary is the NAV reference. It need not reproduce a sum
of independently rounded per-order marks.

### Theorem 6.2 — Maximum-prefix summary is an associative monoid

For a sequence of signed boundary deltas, define summary `(D,M)` by

```text
D = total delta
M = max(0, every prefix sum).
```

For concatenation `A·B`, every prefix is either a prefix of `A` or all of `A`
followed by a prefix of `B`. Therefore

```text
summary(A·B)
  = (Da+Db, max(Ma, max(0, Da+Mb))).
```

This formula is derived from sequence concatenation, which is associative, so
the combine operation is associative. `(0,0)` is its identity.

Both stored components are necessary: `Da` is needed to shift every prefix of
`B`, while `Ma` is needed to retain a maximum reached inside `A`. The inner
positive part is necessary when `Da+Mb<0`; the outer maximum is necessary when
the best prefix occurs inside `A`.

The payout tree's `positive_net_delta` implements the inner positive part, and
`combine_summaries` implements the outer maximum. Removing either changes the
summary or causes unsigned underflow on reachable signed sequences.

### Theorem 6.3 — Settled liability is order-independent

Each settled winning order contributes the exact stored atom
`quantity-floor_shares`; losing orders contribute zero. The tree's settled
prefix sum and each individual redemption use those same atoms. Integer
addition is associative and commutative, so redeem order cannot change total
payout, and subtracting each payout from the stored liability ends at zero.

Pins:

- `packages/predict/tests/strike_exposure/index/payout_tree_walk_tests.move`
- `packages/predict/tests/strike_exposure/index/strike_payout_tree_tests.move`
- `packages/predict/tests/flows/settlement_flow_tests.move`

## 7. Marked liability and NAV bid/ask

### Theorem 7.1 — Final marked-liability projection is sound

The boundary walk returns a signed certified ball `L`. The leveraged-book
correction returns a nonnegative certified ball `C`, using the branch selected
by the contract's liquidation predicate. By Theorem 2.1, `L-C` is certified.
The function `max(0,x)` is 1-Lipschitz, so projecting once after subtraction
retains the same radius and certifies the nonnegative marked-liability
reference.

The final projection cannot be removed: shared-boundary product residue can
make `L` negative by one atom, and `C` is nonnegative.

### Theorem 7.2 — Shared active-NAV uncertainty is evaluated once

Let the fixed-point protocol-profit share be `s` with `0 <= s <= 1`, exact idle
cash be `I`, exact profit-basis credits and debits be `C` and `D`, and exact
pending protocol profit be `P`. Write `floor_s(y)` for the implementation's
down-rounded fixed-point product `floor(s y)`. As a function of the one uncertain
active-market NAV input `x`, canonical LP pool value is

```text
f(x) = max(0, I + x - floor_s(max(0, C + x - D)) - P).
```

Increasing integer `x` by one increases the gross term by one and increases
`floor_s` by either zero or one because `s <= 1`. The expression before the
outer projection is therefore nondecreasing, and projection onto the
nonnegative half-line preserves monotonicity. Therefore, for a certified
active-NAV interval `[c-e,c+e]`,

```text
f(max(0,c-e)) <= f(true active NAV) <= f(c+e).
```

Evaluating these two endpoints and taking the larger distance from `f(c)`
certifies pool value without treating the two correlated appearances of `x` as
independent errors. Generic ball subtraction would remain sound but would count
the same radius once through gross value and again through the profit exclusion,
causing avoidable rejections at the 1% pool-NAV gate.

### Theorem 7.3 — NAV endpoints prevent both LP transfer directions

Let true pool NAV `V` satisfy

```text
c-e <= V <= c+e,
```

with positive representable endpoints. Define

```text
bid = c-e
ask = c+e.
```

For a supply of `A` against frozen pre-drain share supply `T`, fair shares at
true NAV are `A T/V`. Since `ask>=V`,

```text
floor(A T/ask) <= A T/ask <= A T/V.
```

The supplier cannot receive more than the fair entitlement and therefore
cannot dilute incumbent LPs.

For withdrawal of `H` shares, fair DUSDC is `H V/T`. Since `bid<=V`,

```text
floor(H bid/T) <= H bid/T <= H V/T.
```

The withdrawer cannot receive more than the true entitlement.

If `e>0`, no single mark `m` can provide both guarantees for every
`V in [c-e,c+e]`: supply protection requires `m>=c+e`, while withdrawal
protection requires `m<=c-e`. The bid/ask spread is therefore forced by the two
counterparty invariants, not an optional fee.

A zero center produces two non-executable zero marks. A nonzero center must pass
the relative-precision gate and the `center+error` representability guard before
either queue moves value.

Pins:

- `packages/predict/tests/plp/lp_book_tests.move`
- `packages/predict/tests/flows/current_nav_flow_tests.move`
- `packages/predict/tests/flows/pool_valuation_flow_tests.move`
- `packages/predict/tests/flows/precision_policy_flow_tests.move`

## 8. Exact-subtraction state invariants

### Induction 8.1 — Net expiry funding never exceeds its cap

For one registered expiry let

```text
n = max(0, sent-received)
cap = max_expiry_allocation.
```

Registration establishes `sent=received=0`, hence `n=0<=cap`.

The only successful sent transition first asserts `n+amount<=cap` and then
sets `sent'=sent+amount`. Since

```text
max(0,sent+amount-received) <= n+amount,
```

the post-state satisfies `n'<=cap`.

The received transition only increases `received`, so `n` cannot increase.
The cap is immutable after registration. These transitions enumerate every
writer of the three fields, so induction proves `n<=cap` for every reachable
state. Therefore

```text
available_expiry_funding = cap-n
```

is total and needs no outer saturation. The inner
`max(0,sent-received)` remains necessary because profitable expiries can return
more than the pool sent.

### Induction 8.2 — Fee-incentive allocation never exceeds its lifetime cap

Registration establishes `allocated=0<=cap`. An allocation transition computes

```text
remaining = cap-allocated
delta = min(requested,remaining)
allocated' = allocated+delta.
```

Thus `allocated'<=allocated+(cap-allocated)=cap`. The cap is snapshotted and
has no later writer, so `cap-allocated` is total in every reachable state.

### Theorem 8.3 — Expiry surplus release preserves backing exactly

Let required cash be

```text
R = payout_liability + rebate_reserve.
```

`release_surplus(amount)` requires `cash>=R+amount`, so after the split
`cash'=cash-amount>=R`.

`release_all_surplus` requires `cash>=R` and releases `cash-R`, leaving
`cash'=R` exactly. Consequently the caller needs neither a second payout-tree
walk nor a duplicate post-release backing assertion.

`free_cash=cash-rebate_reserve` is also total because the stronger backing
invariant gives `cash>=payout_liability+rebate_reserve>=rebate_reserve`.
An underfunded protocol-controlled state aborts instead of being converted into
a plausible zero.

Pins:

- `packages/predict/tests/plp/pool_accounting_tests.move`
- `packages/predict/tests/expiry_cash_tests.move`
- `packages/predict/tests/flows/backing_buffer_flow_tests.move`

## 9. Remaining positive parts and saturation

The following operations encode reachable semantics and are not removable
under the current protocol definitions.

| Operation | Required meaning |
| --- | --- |
| `predict_account` gross profit | `max(received-paid,0)` for losing accounts. |
| `pool_accounting::flow_net_funding` | Net capital supplied by the pool; profitable expiries may have `received>sent`. |
| Trading-loss eligible rebate | `max(reserve-gross_profit,0)` for winners whose profit exceeds reserved rebate. |
| Fee-incentive top-up | `max(target-current,0)` when a market is already funded above target. |
| Payout-tree `positive_net_delta` | Positive part in the maximum-prefix monoid recurrence. |
| Live-close redeem amount | Limited-recourse `max(gross-closed_floor,0)`; Counterexample 5.3 is reachable. |
| Marked liability | Shared-boundary center minus correction can be negative from representation dust. |
| Current expiry NAV | Valid free cash can be below marked live liability; limited-recourse market value is zero. |
| LP pool value | Sticky protocol-profit exclusions can exceed a later collapsed gross mark. |
| `Approx` error addition | Maximum error is the fail-closed uncertifiable sentinel when a finite radius is not representable. |

## 10. What is not proved

This document does not claim that every semantically equivalent program has
been enumerated or that the implementation is globally operation-minimal. It
proves the specific identities used by the landed simplifications and gives
counterexamples for the tempting removals listed above.

It also does not prove a global upper bound on partial-close fragmentation
advantage, remove the current-NAV nonnegative projection, or show that every
configured SVI surface produces a certifiable live price. Those questions
require additional economic policy or stronger state invariants; they are not
hidden behind a green aggregate verdict.
