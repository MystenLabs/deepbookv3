# Vault Liability Tracking: Collateral Redeem Path Mismatch

## The vault as counterparty

The vault holds USDC and takes the opposite side of every trade. When a user mints an UP contract, the vault goes short UP — it owes the user $1 if the underlying settles above the strike. When the user redeems, the vault buys back that exposure.

## Two ways to mint

1. **Regular mint**: User pays USDC to the vault. The vault takes on short exposure.
2. **Collateralized mint**: User locks an existing position as collateral to mint a new one. For UP: lock a lower-strike UP to mint a higher-strike UP. For DOWN: lock a higher-strike DOWN to mint a lower-strike DOWN. No USDC changes hands. The vault takes on no additional exposure.

## Proof: collateralized mints don't change vault exposure

A collateralized UP mint locks UP at strike K_low to mint UP at strike K_high (where K_low < K_high).

For any settlement price S, the binary payout is $1 if in-the-money, $0 otherwise:

| Settlement | Locked (UP-K_low) | Minted (UP-K_high) | Collateral covers? |
|---|---|---|---|
| S > K_high | $1 (ITM) | $1 (ITM) | $1 ≥ $1 yes |
| K_low < S ≤ K_high | $1 (ITM) | $0 (OTM) | $1 ≥ $0 yes |
| S ≤ K_low | $0 (OTM) | $0 (OTM) | $0 ≥ $0 yes |

In every scenario, locked payout ≥ minted payout. The collateral fully covers the minted position. The vault has zero net additional exposure, so `total_short` and `sum_strike_qty` should not change.

(Symmetric argument for DOWN with K_locked > K_minted.)

## All redeems are valid against vault exposure

We proved above that collateralized mints do not change vault exposure. Therefore, the vault's entire short exposure comes from regular mints. When any position is redeemed — regardless of how it was originally minted — the vault is simply buying back short exposure at the redeemed strike and paying `bid(strike) × qty`. This is always a legitimate reduction of vault risk.

There is no need to distinguish how a position was created. The collateral proof guarantees this.

## What the vault tracks and why

The vault estimates its liabilities using aggregate tracking: `total_up_short` (count of UP contracts) and `sum_up_strike_qty` (Σ of qty × strike). From these it derives a weighted-average strike, feeds it to the oracle, and gets an expected liability:

```
avg_strike = sum_up_strike_qty / total_up_short
expected_liability = total_up_short × oracle.price(avg_strike)
vault_value = balance − expected_liability
```

This is used for LP share pricing.

## Four paths and what they do to tracking

| Path | total_up_short | sum_up_strike_qty | balance |
|---|---|---|---|
| Regular mint (strike K) | +qty | +qty×K | +cost |
| Regular redeem (strike K) | −qty | −qty×K | −payout |
| Collateral mint | unchanged | unchanged | unchanged |
| Collateral redeem | unchanged | unchanged | unchanged |

## The mismatch

Redeems all flow through one path — the vault pays `bid(strike) × qty` and subtracts `qty × strike` from the sum. But mints diverge: regular mints add to the sum, collateral mints don't. When a collateral-minted position is regular-redeemed, the subtracted strike was never added.

## Worked example

Assume: UP-50k costs $0.70, UP-60k costs $0.30, price(55k) = $0.50. Vault starts with 1000 USDC from LPs.

**Step 1: User A mints 100 UP-50k** (pays $70)

```
balance: 1070    short: 100    sum: 5,000k
avg_strike: 50k    liability: 100 × $0.70 = $70    vault_value: 1000
```

**Step 2: User B mints 100 UP-50k** (pays $70)

```
balance: 1140    short: 200    sum: 10,000k
avg_strike: 50k    liability: 200 × $0.70 = $140    vault_value: 1000
```

**Step 3: User A locks UP-50k, collateral-mints 100 UP-60k** (no USDC)

```
balance: 1140    short: 200    sum: 10,000k    (unchanged)
avg_strike: 50k    liability: $140    vault_value: 1000
```

**Step 4: User A mints 100 UP-60k** (pays $30)

```
balance: 1170    short: 300    sum: 16,000k
avg_strike: 53.3k    liability: 300 × price(53.3k)
```

True per-position liability: 200 × $0.70 + 100 × $0.30 = $170. vault_value: 1000.

**Step 5: User A redeems 200 UP-60k** (receives 200 × $0.30 = $60)

```
balance: 1110    short: 100    sum: 16,000k − 12,000k = 4,000k
avg_strike: 4,000k / 100 = 40k
tracked liability: 100 × price(40k)
```

Only User B's 100 UP-50k remain. The correct values:

```
correct avg_strike: 50k
correct liability:  100 × $0.70 = $70
correct vault_value: 1110 − 70 = 1040
```

But the tracking says avg_strike = 40k. Since 40k < 50k, UP-40k is deeper in the money, so price(40k) > $0.70. The vault **overestimates** its liability and **undervalues** itself. LPs get shortchanged on withdrawals.

With u64 arithmetic, if the subtracted amount exceeds the sum, the transaction aborts entirely (which is how we found this).

## The constraint

At redeem time, the vault only sees `key.strike()` (the strike of the position being redeemed). It doesn't know that the vault's actual exposure was booked at a different strike. The aggregate tracking has no way to reconstruct which portion of the sum belongs to vault-backed positions vs collateral-backed ones.
