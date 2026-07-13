# P-9 · Claim-time-stake abuse bound (E2)

**Item:** P-9 · **Instrument:** config-analytical (no localnet needed) · **Date:** 2026-07-07

Pre-registered plan AND result for the second of P-9's two acceptance questions: is the
economic leak from the rebate using **claim-time** active stake (rather than at-trade stake)
below deploy relevance? E1 (`p9-cleanout-gas-2026-07-07.md`) covers the first question (is the
permissionless cleanout self-incentivized). This one is closed on paper from the config
constants + the lazy-epoch stake-activation rule.

## Hypothesis

A trader cannot profitably game the rebate by staking DEEP **after** trading (once they see
they are losing), for any market whose life is shorter than one Sui epoch — which is the entire
current cadence set (1m / 5m / 1h). Any residual leak is (a) bounded per account by
`rate × fees`, and (b) captures at most the *rebate half* of staking's value while forgoing the
*fee-discount half* already paid, so it is dominated by simply staking up front.

## Mechanism under test (verified at HEAD 79879740)

- `claim_trading_loss_rebate` (`expiry_market.move:743-778`) prices the rebate as
  `rebate_amount(eligible_rebate, active_stake)` with `active_stake =
  roll_active_stake(account, ctx)` read at **claim** time.
- `roll_active_stake` (`predict_account.move:296-305`) activates inactive stake only when
  `stake_epoch != current_epoch` — i.e. DEEP staked in epoch `E` is **inactive until epoch
  `E+1`**. So stake first counts for benefits one epoch after it is added.
- `benefit_ratio` (`stake_config.move:77-91`) is 0 at stake 0, 0.5 at `lower_benefit_power`,
  1.0 at `upper_benefit_power`.

## Config constants (defaults, HEAD)

| Constant | Value | Meaning |
|---|---|---|
| `default_trading_loss_rebate_rate` | `0.5` (`500_000_000` / 1e9) | rebate reserve = 0.5 × trader fees |
| `max_fee_discount` | `0.5` (`500_000_000` / 1e9) | max fraction of a fee staking can discount |
| `default_lower_benefit_power` | `100_000` DEEP | stake for `benefit_ratio = 0.5` |
| `default_upper_benefit_power` | `1_100_000` DEEP | stake for `benefit_ratio = 1.0` |
| Sui epoch (mainnet/testnet) | ~24 h | stake-activation boundary |
| Market cadences (prod) | 1m / 5m / 1h | all ≪ 1 epoch |

## Result 1 — the boost is STRUCTURALLY IMPOSSIBLE for every sub-epoch market

To boost a rebate a trader needs `active_stake > 0` at **claim** time that was **not** active
at trade time. Because staking in epoch `E` only activates at `E+1` (~24 h later), the trader
must stake at least one full epoch **before** the claim. The claim happens right after
settlement (and, per E1, an incentivized keeper resolves it promptly). So the whole
trade → stake → settle → claim chain must span **≥ 1 epoch** for the late stake to have
activated. Every current-cadence market (1m / 5m / 1h) settles and is claimed **far inside a
single 24 h epoch**, so a late stake is still `inactive` at claim and contributes
`benefit_ratio` of exactly its *previously-active* stake — the boost is unreachable. The only
regime where the window can reach an epoch is a **long-dated (multi-epoch) option**, which does
not exist today.

This is also why E2 is analytical, not a localnet run: the localnet epoch is a short devnet
artifact, so the harness cannot faithfully reproduce the 24 h activation gate that closes this
on production.

## Result 2 — even where reachable, the leak is bounded and dominated

Suppose long-dated options exist and a losing trader stakes mid-life. Compare their strategies:

- **Up-front staker** (staked the whole time, benefit ratio β): saves fee discount
  `f · β · max_fee_discount = 0.5 · f · β` per position, **and** (if a net loser) recovers rebate
  `≤ rate · f · β = 0.5 · f · β`. Total staking value ≈ `f · β · (0.5 + 0.5·[net-loser])`.
- **Late staker** (stakes only near expiry): pays full fees (**forgoes** the `0.5 · f · β`
  discount) and recovers only rebate `≤ 0.5 · f · β`.

With `rate = max_fee_discount = 0.5`, the rebate is **exactly the discount half** of staking's
value. So a late staker captures **at most 50 %** of what staking offers, only if net-losing,
and must still lock the *same* DEEP staking always requires. The LP-visible leak is the rebate
paid to a late staker who would not otherwise have staked, bounded per account by `rate · fees`.

The stake threshold gates who can do this at all: meaningful `benefit_ratio` needs
`≥ 100_000` DEEP (β = 0.5) up to `1_100_000` DEEP (β = 1.0). A retail loser's total fees are a
few dollars; `0.5 · fees · β` is cents — orders of magnitude below the capital cost of locking
100k+ DEEP. So gaming is EV-negative for retail and only turns EV-positive for a **large
position paying large fees** — for whom committing 100k+ DEEP to recover a rebate is
approximately the *intended* mechanism (stake → rebate), merely accessed late.

## Result 3 — the permissionless "claim-to-deny" grief is neutralized by the same gate

The grief (a third party resolving a victim's one-shot summary at a low-stake instant) needs
the victim's `active_stake` at forced-claim time to be lower than it would be if the victim
waited. But (Result 1) no sub-epoch stake can activate within the market's life anyway, so the
victim's claim-time active stake equals their **standing** active stake regardless of when the
claim fires — a griefer cannot lower it (they cannot unstake the victim). Under the incentivized
prompt cleanout (E1) everyone is resolved uniformly at settlement-time standing stake. Payoff to
the griefer: none; loss to the victim: none, for every sub-epoch market.

## Decision (pre-registered rule + outcome)

**Pre-registered rule:** accept if, for the current cadence set, the retroactive-boost is either
structurally impossible or the worst-case aggregate is below deploy relevance; otherwise the fix
(snapshot benefit-relevant stake at mint) is required.

**Outcome — ACCEPT.** For every current-cadence market the boost and the grief are
**structurally impossible** (the 24 h stake-activation gate), and even in the hypothetical
long-dated regime the leak is bounded by `rate · fees`, captures ≤ 50 % of staking's value, and
requires a genuine 100k+ DEEP commitment (retail-excluded, whale ≈ intended-mechanism). The
claim-time-stake design is accepted as-is.

**Reopen when:** a market with life ≥ ~1 Sui epoch (a long-dated / multi-epoch option) is
introduced — at that point re-measure the aggregate late-stake exposure and reconsider snapshotting
benefit-relevant stake at mint. Also reopen if `trading_loss_rebate_rate` is set materially above
`max_fee_discount` (the `rate ≤ max_fee_discount` inequality is what bounds the leak to the
discount half).
