# Testnet pricing example

This standalone example reconstructs range-contract probabilities from an earlier Predict package on Sui Testnet, turns each probability into a fair contract value, and compares the result with ten historical mint events from that package. It is a historical pricing demonstration, not a live data feed, a production quoting system, or a reference implementation of current Predict pricing.

## Data

`testnet_pricing_sample.json` contains 1,000 unique oracle snapshots across 27 expiries and ten real mints. The sample is frozen historical data captured from the public Sui Testnet GraphQL API; the script makes no network requests when it runs.

The exact historical Predict and Propbook package addresses are recorded under `deployment` in the fixture. That Predict package used raw SVI parameters and the unadjusted `N(d2)` digital formula shown below; current Predict pricing additionally applies remaining-time SVI roll-down and an SVI digital-skew correction, as described in the [current pricing documentation](../../docs/concepts/pricing-and-oracles.md#from-svi-to-a-range-probability).

Each snapshot combines a Pyth spot event with the latest Block Scholes spot, forward, and SVI observations available as of that event for the expiry; those observations may come from the same oracle transaction as Pyth. When replaying a mint, the script conservatively selects a snapshot with a strictly earlier timestamp because distinct Testnet transactions can share a clock timestamp without exposing their execution order in this fixture.

The fixture omits wallet, account, and order identifiers. It retains public Testnet transaction links so the inputs can be checked independently; those links can still be used to trace pseudonymous public-chain activity.

## Historical pricing flow

The live forward re-anchors the provider basis to the higher-frequency Pyth spot:

```text
live_forward = pyth_spot * provider_forward / provider_spot
```

For each strike, the script evaluates SVI total variance and a cash-or-nothing digital probability. A range probability is the probability above the lower strike minus the probability above the higher strike:

```text
w(k) = a + b * (rho * (k - m) + sqrt((k - m)^2 + sigma^2))
P(settlement > strike) = N(-(k + w(k) / 2) / sqrt(w(k)))
P(lower < settlement <= higher) = P(settlement > lower) - P(settlement > higher)
contract value = range probability * fixed payout
```

The example intentionally excludes inventory, hedging, pool state, fees, liquidation, settlement, and transaction execution.

## Run

Python 3 is the only requirement:

```sh
python3 predict_probability_demo.py
python3 predict_probability_demo.py --mint 0 --json
```

The default output replays all ten sampled mints and shows the model probability, probability recorded by the mint event, and corresponding premium values.
