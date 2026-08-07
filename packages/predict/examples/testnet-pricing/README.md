# Testnet pricing example

This standalone example reconstructs Predict range-contract probabilities from historical Sui Testnet oracle events, turns each probability into a fair contract value, and compares the result with ten historical mint events. It is a pricing demonstration, not a live data feed or production quoting system.

## Data

`testnet_pricing_sample.json` contains 1,000 unique oracle snapshots across 27 expiries and ten real mints. The sample is frozen historical data captured from the public Sui Testnet GraphQL API; the script makes no network requests when it runs.

Each snapshot combines a Pyth spot event with the latest strictly preceding Block Scholes spot, forward, and SVI events for that expiry. Strictly earlier events are used because distinct Testnet transactions can share a clock timestamp.

The fixture omits wallet, account, and order identifiers. It retains public Testnet transaction links so the inputs can be checked independently; those links can still be used to trace pseudonymous public-chain activity.

## Pricing flow

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
