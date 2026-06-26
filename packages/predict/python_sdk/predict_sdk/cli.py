from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import asdict
from typing import Sequence

from .config import DeploymentConfig, load_testnet_config
from .constants import DEFAULT_TESTNET_RPC_URL, DUSDC_DECIMALS, FLOAT_SCALING
from .indexer import PredictIndexerClient
from .observability import ObservabilityClient
from .render import render_dashboard, render_markets_table
from .rpc import SuiRpcObjectReader

# Admission grid: valid finite ticks are multiples of admission_tick_size/tick_size.
# Every current cadence shares a grid of 10 (see CadenceConfig.admission_grid_ticks);
# deriving it from the resolved market's cadence is a follow-up (needs cadence
# resolution on the write path).
_GRID_TICKS = 10
# Mint quantity lot size in 6-dp DUSDC base units; manual trades snap down to it.
_POSITION_LOT_BASE_UNITS = 10_000
# Default cap on entry probability for a manual `trade` (0.99, 1e9-scaled).
_DEFAULT_MAX_PROBABILITY = 99 * FLOAT_SCALING // 100


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    handlers = {
        "status": _status, "markets": _markets, "account": _account,
        "deposit": _deposit, "withdraw": _withdraw, "trade": _trade,
        "positions": _positions, "redeem": _redeem,
        "dashboard": _dashboard,
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

    dashboard = subcommands.add_parser("dashboard", help="live TUI account monitor")
    dashboard.add_argument("--rpc-url", default=DEFAULT_TESTNET_RPC_URL)
    dashboard.add_argument("--asset", default="BTC_USD")
    dashboard.add_argument("--refresh", type=int, default=10, help="refresh interval seconds")
    dashboard.add_argument("--log-file", default="predict-dashboard.log", help="log file path")

    return parser


def _status(args: argparse.Namespace) -> int:
    config = load_testnet_config()
    now_ms = _now_ms() if args.now_ms is None else args.now_ms
    transport = _fixture_transport(config, now_ms) if args.fixture_live else None
    report = ObservabilityClient(config, transport=transport).status(args.asset, now_ms=now_ms)
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
    return int(round(amount * 10**DUSDC_DECIMALS))


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
    wallet_dusdc = bals.get("DUSDC", 0)
    custody_dusdc = acts.custody_balance() if str(wrapper).startswith("0x") else 0
    pf = acts.portfolio()
    print(f"address      {acts.signer.address}")
    print(f"account      {wrapper}")
    print(f"wallet       {bals.get('SUI', 0) / 1e9:.4f} SUI | {wallet_dusdc / 1e6:,.2f} DUSDC")
    print(f"custody      {custody_dusdc / 1e6:,.2f} DUSDC")
    print(f"total        {(wallet_dusdc + custody_dusdc) / 1e6:,.2f} DUSDC")
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
    base = (ref // _GRID_TICKS) * _GRID_TICKS
    width = max(_GRID_TICKS, (args.width // _GRID_TICKS) * _GRID_TICKS)
    lower, higher = base - width, base + width
    quantity = (_dusdc(args.notional) // _POSITION_LOT_BASE_UNITS) * _POSITION_LOT_BASE_UNITS
    max_cost = _dusdc(args.max_cost) if args.max_cost else _dusdc(args.notional)
    res = acts.mint(
        market_id, lower_tick=lower, higher_tick=higher, quantity=quantity,
        leverage=int(round(args.leverage * FLOAT_SCALING)), max_cost=max_cost,
        max_probability=_DEFAULT_MAX_PROBABILITY, execute=args.execute,
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


def _dashboard(args) -> int:
    from .dashboard import run_dashboard
    print(f"launching dashboard… (logs → {args.log_file})")
    run_dashboard(refresh_s=args.refresh, asset=args.asset, rpc_url=args.rpc_url, log_file=args.log_file)
    return 0


def _resolve_market(acts, market: str) -> tuple[str, int]:
    """Resolve a market id + its reference tick; 'auto' picks the longest-dated live one."""
    reader = SuiRpcObjectReader(acts.client.rpc_url, timeout=20)
    if market != "auto":
        fields = reader.get_object(market)["data"]["content"]["fields"]
        return market, int(fields["strike_exposure"]["fields"]["reference_tick"])
    report = ObservabilityClient(acts.config).status(now_ms=_now_ms())
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


def _fixture_transport(config: DeploymentConfig, now_ms: int):
    """A `(url, timeout) -> JSON` transport serving canned indexer responses for
    `status --fixture-live` — one live 5m market + one just-expired, fresh oracle."""
    period = config.cadence("5m").period_ms
    live_expiry = ((now_ms // period) + 1) * period
    prev_expiry = live_expiry - period
    live_id = "0x1111111111111111111111111111111111111111111111111111111111111111"
    prev_id = "0x2222222222222222222222222222222222222222222222222222222222222222"
    oracle_id = "0xoracle"
    fresh = str(now_ms - 10_000)
    vault_id = config.shared_object_id("predict", "plp::PoolVault")
    underlying = config.asset("BTC_USD").propbook_underlying_id

    def _state(expiry: int) -> dict:
        return {
            "market": {"expiry": expiry, "tick_size": "1000000000", "propbook_underlying_id": underlying},
            "mint_paused": {"paused": False},
            "settlement": None,
        }

    market_state = {live_id: _state(live_expiry), prev_id: _state(prev_expiry)}
    responses = {
        "/config": {
            "trading_paused": {"paused": False},
            "pricing": {"pyth_spot_freshness_ms": 30000, "block_scholes_surface_freshness_ms": 30000},
        },
        "/markets": [
            {"expiry_market_id": live_id, "expiry": live_expiry,
             "propbook_underlying_id": underlying, "tick_size": "1000000000"},
            {"expiry_market_id": prev_id, "expiry": prev_expiry,
             "propbook_underlying_id": underlying, "tick_size": "1000000000"},
        ],
        f"/vaults/{vault_id}/state": {"current": {
            "idle_balance_after": "19990000000",
            "protocol_reserve_balance_after": "0",
            "total_supply": "20000000000",
        }},
        f"/underlyings/{underlying}/binding": {"propbook_oracle_id": oracle_id},
        f"/oracles/{oracle_id}/pyth/latest": {"source_timestamp_ms": fresh},
    }

    def transport(url: str, timeout: float):
        base = url.split("?", 1)[0]
        for market_id, state in market_state.items():
            if base.endswith(f"/markets/{market_id}/state"):
                return state
        if base.endswith(f"/oracles/{oracle_id}/block-scholes"):
            return [{"source_timestamp_ms": fresh}]
        for path, value in responses.items():
            if base.endswith(path):
                return value
        return {}

    return transport


def _now_ms() -> int:
    return int(time.time() * 1000)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
