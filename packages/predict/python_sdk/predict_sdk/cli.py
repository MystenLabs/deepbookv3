from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import asdict
from typing import Sequence

from .config import DeploymentConfig, load_testnet_config
from .indexer import PredictIndexerClient
from .observability import ObservabilityClient
from .render import render_dashboard, render_markets_table
from .rpc import SuiRpcObjectReader

DEFAULT_TESTNET_RPC_URL = "https://fullnode.testnet.sui.io:443"


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    handlers = {
        "status": _status, "markets": _markets, "account": _account,
        "deposit": _deposit, "withdraw": _withdraw, "trade": _trade,
        "positions": _positions, "redeem": _redeem,
    }
    handler = handlers.get(args.command)
    if handler is None:
        parser.print_help()
        return 2
    return handler(args)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="predict-sdk")
    subcommands = parser.add_subparsers(dest="command")

    status = subcommands.add_parser("status", help="print Predict testnet status")
    status.add_argument("--asset", default="BTC_USD")
    status.add_argument("--rpc-url", default=DEFAULT_TESTNET_RPC_URL)
    status.add_argument("--fixture-live", action="store_true", help="use a local live fixture")
    status.add_argument("--json", action="store_true", help="print machine-readable JSON")
    status.add_argument("--no-color", action="store_true", help="disable ANSI color output")
    status.add_argument("--no-indexer", action="store_true", help="skip the indexer health check")
    status.add_argument("--now-ms", type=int, default=None)
    status.add_argument("--timeout", type=float, default=10)

    markets = subcommands.add_parser("markets", help="list created markets from the indexer")
    markets.add_argument("--limit", type=int, default=20)
    markets.add_argument("--indexer-url", default=None, help="override the predict indexer base URL")
    markets.add_argument("--json", action="store_true", help="print machine-readable JSON")
    markets.add_argument("--no-color", action="store_true", help="disable ANSI color output")
    markets.add_argument("--timeout", type=float, default=10)

    # --- trader commands (write path; default dry-run, --execute to submit) ---
    def trader(name: str, help_text: str):
        p = subcommands.add_parser(name, help=help_text)
        p.add_argument("--execute", action="store_true", help="submit on-chain (default: dry run)")
        p.add_argument("--rpc-url", default=DEFAULT_TESTNET_RPC_URL)
        p.add_argument("--asset", default="BTC_USD")
        return p

    trader("account", "show account + balances + portfolio summary")
    deposit = trader("deposit", "deposit DUSDC from wallet into account custody")
    deposit.add_argument("amount", type=float, help="DUSDC amount (e.g. 5000)")
    withdraw = trader("withdraw", "withdraw DUSDC from account custody to wallet")
    withdraw.add_argument("amount", type=float, help="DUSDC amount")
    trade = trader("trade", "mint a range position around spot on a live market")
    trade.add_argument("--market", default="auto", help="market id, or 'auto' (best live market)")
    trade.add_argument("--width", type=int, default=1000, help="half-width in ticks around spot")
    trade.add_argument("--notional", type=float, default=100.0, help="position size in DUSDC (max payout)")
    trade.add_argument("--leverage", type=float, default=1.0)
    trade.add_argument("--max-cost", type=float, default=None, help="all-in cost cap in DUSDC")
    trader("positions", "show open positions + realized PnL")
    redeem = trader("redeem", "close a live position")
    redeem.add_argument("order_id", help="order id (u256, decimal)")
    redeem.add_argument("--market", required=True, help="market id holding the position")
    redeem.add_argument("--quantity", type=float, default=None, help="DUSDC to close (default: full)")

    return parser


def _status(args: argparse.Namespace) -> int:
    config = load_testnet_config()
    now_ms = _now_ms() if args.now_ms is None else args.now_ms
    reader = (
        _FixtureLiveReader(config, now_ms)
        if args.fixture_live
        else SuiRpcObjectReader(args.rpc_url, timeout=args.timeout)
    )
    report = ObservabilityClient(config, reader).status(args.asset, now_ms=now_ms)
    # Indexer health is best-effort and offline-skipped (fixture mode / opt-out).
    indexer = None
    indexer_url = config.server_url("predict")
    if not args.fixture_live and not args.no_indexer and indexer_url:
        indexer = PredictIndexerClient(indexer_url, timeout=args.timeout).health()
    if args.json:
        print(json.dumps(asdict(report), indent=2, sort_keys=True))
    else:
        color = sys.stdout.isatty() and not args.no_color
        print(render_dashboard(report, now_ms, color=color, indexer=indexer))
    return 0


def _markets(args: argparse.Namespace) -> int:
    config = load_testnet_config()
    base_url = args.indexer_url or config.server_url("predict")
    if not base_url:
        print("no predict indexer URL configured", file=sys.stderr)
        return 2
    markets = PredictIndexerClient(base_url, timeout=args.timeout).markets(limit=args.limit)
    if args.json:
        print(json.dumps(markets, indent=2, sort_keys=True))
    else:
        color = sys.stdout.isatty() and not args.no_color
        print(render_markets_table(markets, _now_ms(), color=color))
    return 0


# === trader commands (lazy-import the write path so read commands stay stdlib-only) ===

def _build_actions(args):
    from .actions import PredictActions
    from .signer import load_signer
    return PredictActions(load_signer(), rpc_url=args.rpc_url, asset=args.asset)


def _dusdc(amount: float) -> int:
    return int(round(amount * 1_000_000))


def _print_tx(res, execute: bool, label: str) -> int:
    tag = "EXECUTED" if execute else "DRY RUN"
    mark = "✓" if res.success else "✗"
    print(f"[{tag}] {mark} {label}: {res.status}", f"| digest {res.digest}" if res.digest else "")
    if not res.success:
        print("  error:", res.error)
        return 1
    if not execute:
        print(f"  (gas ~{res.gas_used} MIST; re-run with --execute to submit)")
    return 0


def _account(args) -> int:
    acts = _build_actions(args)
    wrapper = acts.account_wrapper_id()
    if wrapper is None:
        wrapper = acts.ensure_account(execute=args.execute)
    bals = {b["coinType"].split("::")[-1]: int(b["totalBalance"])
            for b in acts.client._rpc("suix_getAllBalances", [acts.signer.address])}
    pf = acts.portfolio()
    print(f"address      {acts.signer.address}")
    print(f"account      {wrapper}")
    print(f"wallet       {bals.get('SUI', 0) / 1e9:.4f} SUI | {bals.get('DUSDC', 0) / 1e6:,.2f} DUSDC")
    print(f"positions    {pf.open_count} open | {pf.closed_count} closed")
    print(f"premium risk {pf.open_premium / 1e6:,.2f} DUSDC")
    print(f"realized PnL {pf.realized_pnl / 1e6:+,.4f} DUSDC")
    return 0


def _deposit(args) -> int:
    acts = _build_actions(args)
    acts.ensure_account(execute=args.execute)
    res = acts.deposit(_dusdc(args.amount), execute=args.execute)
    return _print_tx(res, args.execute, f"deposit {args.amount} DUSDC")


def _withdraw(args) -> int:
    acts = _build_actions(args)
    res = acts.withdraw(_dusdc(args.amount), execute=args.execute)
    return _print_tx(res, args.execute, f"withdraw {args.amount} DUSDC")


def _trade(args) -> int:
    acts = _build_actions(args)
    acts.ensure_account(execute=args.execute)
    market_id, ref = _resolve_market(acts, args.market)
    base = (ref // 10) * 10
    width = max(10, (args.width // 10) * 10)
    lower, higher = base - width, base + width
    quantity = (_dusdc(args.notional) // 10_000) * 10_000  # snap to position lot size
    max_cost = _dusdc(args.max_cost) if args.max_cost else _dusdc(args.notional)
    res = acts.mint(
        market_id, lower_tick=lower, higher_tick=higher, quantity=quantity,
        leverage=int(round(args.leverage * 1_000_000_000)), max_cost=max_cost,
        max_probability=990_000_000, execute=args.execute,
    )
    print(f"market {market_id[:14]}… range [{lower},{higher}] qty {quantity/1e6:.2f} DUSDC")
    for ev in res.events:
        if ev.get("type", "").endswith("OrderMinted"):
            j = ev["parsedJson"]
            print(f"  entry prob {int(j['entry_probability'])/1e9:.1%} | premium {int(j['net_premium'])/1e6:.2f} DUSDC")
    return _print_tx(res, args.execute, "mint")


def _positions(args) -> int:
    acts = _build_actions(args)
    pf = acts.portfolio()
    print(f"realized PnL {pf.realized_pnl/1e6:+,.4f} DUSDC | open {pf.open_count} | premium risk {pf.open_premium/1e6:,.2f}")
    for p in pf.positions:
        print(f"  {p.order_id[:16]}… mkt {p.market_id[:10]}… [{p.lower_tick},{p.higher_tick}] "
              f"qty {p.open_quantity/1e6:.2f} prob {p.entry_probability/1e9:.1%} premium {p.net_premium/1e6:.2f}")
    return 0


def _redeem(args) -> int:
    acts = _build_actions(args)
    if args.quantity is not None:
        qty = _dusdc(args.quantity)
    else:
        match = next((p for p in acts.portfolio().positions if p.order_id == args.order_id), None)
        qty = match.open_quantity if match else 0
        if not qty:
            print("could not determine close quantity; pass --quantity", file=sys.stderr)
            return 2
    res = acts.redeem_live(args.market, int(args.order_id), qty, execute=args.execute)
    return _print_tx(res, args.execute, f"redeem {qty/1e6:.2f} DUSDC")


def _resolve_market(acts, market: str) -> tuple[str, int]:
    """Resolve a market id + its reference tick; 'auto' picks the longest-dated live one."""
    reader = SuiRpcObjectReader(acts.client.rpc_url, timeout=20)
    if market != "auto":
        fields = reader.get_object(market)["data"]["content"]["fields"]
        return market, int(fields["strike_exposure"]["fields"]["reference_tick"])
    report = ObservabilityClient(acts.config, reader).status(now_ms=_now_ms())
    best = None
    for m in report.markets:
        if not (m.mintable and m.time_to_expiry_ms and m.time_to_expiry_ms > 120_000):
            continue
        ref = reader.get_object(m.market_id)["data"]["content"]["fields"]["strike_exposure"]["fields"].get("reference_tick")
        if ref is not None and (best is None or m.time_to_expiry_ms > best[2]):
            best = (m.market_id, int(ref), m.time_to_expiry_ms)
    if best is None:
        raise RuntimeError("no live mintable market with a reference tick found")
    return best[0], best[1]


class _FixtureLiveReader:
    def __init__(self, config: DeploymentConfig, now_ms: int):
        self.objects = _fixture_live_objects(config, now_ms)

    def get_object(self, object_id: str):
        return self.objects.get(object_id)

    def get_dynamic_field_object(self, parent_id: str, name_type: str, name_value: str):
        return None


def _fixture_live_objects(config: DeploymentConfig, now_ms: int):
    asset = config.asset("BTC_USD")
    # Place markets on real 5m cadence boundaries so they land in the timeline's
    # live / just-expired slots.
    period = config.cadence("5m").period_ms
    live_expiry = ((now_ms // period) + 1) * period
    live_id = "0x1111111111111111111111111111111111111111111111111111111111111111"
    prev_id = "0x2222222222222222222222222222222222222222222222222222222222222222"
    return {
        config.shared_object_id("predict", "protocol_config::ProtocolConfig"): _object(
            {
                "trading_paused": False,
                "valuation_in_progress": False,
                "pricing_config": {
                    "fields": {
                        "pyth_spot_freshness_ms": "30000",
                        "block_scholes_price_freshness_ms": "30000",
                        "block_scholes_svi_freshness_ms": "60000",
                    }
                },
            }
        ),
        config.shared_object_id("predict", "plp::PoolVault"): _object(
            {
                "protocol_reserve_balance": _balance("0"),
                "lp": {
                    "fields": {
                        "treasury_cap": {
                            "fields": {"total_supply": {"fields": {"value": "20000000000"}}}
                        },
                        "supply_queue": {"fields": {"pending": "0"}},
                        "withdraw_queue": {"fields": {"pending": "0"}},
                    }
                },
                "expiry_accounting": {
                    "fields": {
                        "idle_balance": _balance("19990000000"),
                        "active_expiry_markets": [live_id, prev_id],
                    }
                },
            }
        ),
        live_id: _market(live_expiry, "10000000000", reference_tick="64250"),
        prev_id: _market(live_expiry - period, "10000000000"),
        asset.feed_ids.pyth: _object({"latest_source_timestamp_ms": str(now_ms - 10_000)}),
        asset.feed_ids.bs_spot: _object({"latest_source_timestamp_ms": str(now_ms - 10_000)}),
        asset.feed_ids.bs_forward: _object({"latest_source_timestamp_ms": str(now_ms - 10_000)}),
        asset.feed_ids.bs_svi: _object({"latest_source_timestamp_ms": str(now_ms - 10_000)}),
    }


def _market(expiry: int, cash: str, *, reference_tick: str | None = None):
    strike_exposure = {"tick_size": "1000000000"}
    if reference_tick is not None:
        strike_exposure["reference_tick"] = {"fields": {"vec": [reference_tick]}}
    return _object(
        {
            "propbook_underlying_id": "1",
            "expiry": str(expiry),
            "settlement_price": {"fields": {"vec": []}},
            "cash": {
                "fields": {
                    "cash_balance": _balance(cash),
                    "unresolved_trading_fees_paid": "0",
                }
            },
            "strike_exposure": {"fields": strike_exposure},
            "payout_liability": "0",
            "mint_paused": False,
        }
    )


def _object(fields):
    return {"data": {"content": {"fields": fields}}}


def _balance(value: str):
    return {"fields": {"value": value}}


def _now_ms() -> int:
    return int(time.time() * 1000)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
