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
    if args.command == "status":
        return _status(args)
    if args.command == "markets":
        return _markets(args)
    parser.print_help()
    return 2


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
