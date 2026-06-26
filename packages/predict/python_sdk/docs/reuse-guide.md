# Reuse Guide

This guide shows how another agent or application can reuse the SDK without starting
from the CLI.

## Install

```bash
cd packages/predict/python_sdk
pip install -e .
```

Trading requires `SUI_PRIVATE_KEY` in the environment or local `.env`.

## Read Live Status

```python
from predict_sdk import load_testnet_config
from predict_sdk.observability import ObservabilityClient
from predict_sdk.rpc import SuiRpcObjectReader

config = load_testnet_config()
reader = SuiRpcObjectReader("https://fullnode.testnet.sui.io:443")
report = ObservabilityClient(config, reader).status("BTC_USD")

print(report.is_live, report.is_mintable)
print(report.mintable_market_ids)
```

## Render A Dashboard

```python
import time

from predict_sdk import load_testnet_config, render_dashboard
from predict_sdk.observability import ObservabilityClient
from predict_sdk.rpc import SuiRpcObjectReader

now_ms = int(time.time() * 1000)
config = load_testnet_config()
report = ObservabilityClient(
    config,
    SuiRpcObjectReader("https://fullnode.testnet.sui.io:443"),
).status("BTC_USD", now_ms=now_ms)

print(render_dashboard(report, now_ms, color=False))
```

## Create Or Load An Account

```python
from predict_sdk.actions import PredictActions

actions = PredictActions.from_env()
account_id = actions.ensure_account(execute=False)  # dry run
print(account_id)
```

Use `execute=True` only when you intend to submit on-chain.

## Read Custody Balance

```python
from predict_sdk.actions import PredictActions

actions = PredictActions.from_env()
custody_raw = actions.custody_balance()
print(custody_raw / 1_000_000)
```

This is the DUSDC held inside the shared `AccountWrapper`. Wallet DUSDC is separate
and comes from `suix_getAllBalances`.

## Deposit DUSDC

```python
from predict_sdk.actions import PredictActions

actions = PredictActions.from_env()
amount = 5_000 * 1_000_000  # 5,000 DUSDC in raw units
result = actions.deposit(amount, execute=False)

print(result.success, result.gas_used, result.error)
```

## Dry-Run A Mint For Price Discovery

```python
from predict_sdk.actions import PredictActions

actions = PredictActions.from_env()

result = actions.mint(
    "0xMARKET_ID",
    lower_tick=64_000,
    higher_tick=65_000,
    quantity=100 * 1_000_000,
    leverage=1_000_000_000,
    max_cost=100 * 1_000_000,
    max_probability=990_000_000,
    execute=False,
)

for event in result.events:
    if event.get("type", "").endswith("OrderMinted"):
        parsed = event["parsedJson"]
        print(parsed["entry_probability"], parsed["net_premium"])
```

This is the SDK's pricing model: dry-run the real mint and read the event.

## Execute A Mint

```python
result = actions.mint(
    "0xMARKET_ID",
    lower_tick=64_000,
    higher_tick=65_000,
    quantity=100 * 1_000_000,
    leverage=1_000_000_000,
    max_cost=100 * 1_000_000,
    max_probability=990_000_000,
    execute=True,
)

print(result.success, result.digest, result.error)
```

Call dry-run first unless a higher-level workflow already did so.

## Read Portfolio

```python
from predict_sdk.actions import PredictActions

actions = PredictActions.from_env()
portfolio = actions.portfolio()

print(portfolio.open_count, portfolio.realized_pnl)
for position in portfolio.positions:
    print(position.market_id, position.order_id, position.open_quantity)
```

Portfolio reconstruction reads order events from Sui RPC.

## Parallel Writes

```python
from predict_sdk.gas import GasPool

pool = GasPool(actions.client)
pool.split(4, 120_000_000)

def task(coin):
    result = actions.mint(..., gas_coin=coin, execute=True)
    pool.update_coin_from_result(coin, result)
    return result

results = pool.parallel([task, task, task, task])
```

Each in-flight write must use a distinct gas coin.
