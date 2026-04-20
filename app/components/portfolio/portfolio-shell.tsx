"use client";

import { useState } from "react";

import { PageShell } from "@/components/common/page-shell";
import { portfolioShellMock, type PortfolioShellSnapshot } from "@/lib/mocks/portfolio";

type PortfolioShellProps = {
  networkLabel: string;
  sourceLabel: string;
  sourceTone: "neutral" | "positive" | "warning";
  snapshot?: PortfolioShellSnapshot;
  walletBalanceValue?: string | null;
  managerBalanceValue?: string | null;
  amountValue?: string;
  walletConnected?: boolean;
  isPending?: boolean;
  statusMessage?: string | null;
  depositDisabled?: boolean;
  withdrawDisabled?: boolean;
  onAmountChange?: (value: string) => void;
  onDeposit?: () => void;
  onWithdraw?: () => void;
};

type TransferMode = "deposit" | "withdraw";
type PnlRange = "1D" | "1W" | "1M" | "3M" | "All";

const PNL_RANGES: PnlRange[] = ["1D", "1W", "1M", "3M", "All"];

function isPositiveChange(change: string): boolean {
  return change.trimStart().startsWith("+");
}

export function PortfolioShell({
  snapshot = portfolioShellMock,
  walletBalanceValue = null,
  managerBalanceValue = null,
  amountValue = "",
  walletConnected = false,
  isPending = false,
  statusMessage,
  depositDisabled = false,
  withdrawDisabled = false,
  onAmountChange,
  onDeposit,
  onWithdraw,
}: PortfolioShellProps) {
  const [pnlRange, setPnlRange] = useState<PnlRange>("1M");
  const [transferMode, setTransferMode] = useState<TransferMode>("deposit");

  const accountMetric = snapshot.metrics[0];
  const tradingMetric = snapshot.metrics[1];
  const pnlMetric = snapshot.metrics[2];

  const pnlPositive = isPositiveChange(snapshot.pnl.change);
  const lineColor = pnlPositive
    ? "rgba(60,200,120,0.95)"
    : "rgba(240,100,100,0.9)";
  const areaColorTop = pnlPositive
    ? "rgba(60,200,120,0.18)"
    : "rgba(240,100,100,0.18)";
  const sourceBalanceValue =
    transferMode === "deposit" ? walletBalanceValue : managerBalanceValue;
  const destinationBalanceValue =
    transferMode === "deposit" ? managerBalanceValue : walletBalanceValue;

  return (
    <PageShell
      title="Portfolio"
      description={snapshot.description}
    >
      <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_360px]">
        {/* Left column — Account Value + PnL chart */}
        <div className="space-y-4">
          {/* Account Value header */}
          <div>
            <p className="text-xs text-muted">Account value</p>
            <p className="mt-2 font-mono text-4xl font-semibold text-primary">
              {accountMetric?.value ?? "—"}
            </p>
            {accountMetric?.change ? (
              <p className="mt-1 font-mono text-sm text-secondary">
                <span
                  className={
                    isPositiveChange(accountMetric.change)
                      ? "text-accent-green"
                      : "text-accent-red"
                  }
                >
                  {accountMetric.change}
                </span>
                {" all-time"}
              </p>
            ) : null}
          </div>

          {/* PnL chart card */}
          <div className="panel-shell min-w-0 overflow-hidden p-4">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <p className="text-xs text-muted">PnL over time</p>
              <div className="flex items-center gap-1" role="group" aria-label="PnL range">
                {PNL_RANGES.map((range) => (
                  <button
                    key={range}
                    type="button"
                    onClick={() => setPnlRange(range)}
                    className={
                      pnlRange === range
                        ? "rounded-[8px] border border-accent-gold/50 bg-accent-gold/[0.08] px-2 py-1 font-mono text-xs text-accent-gold"
                        : "rounded-[8px] border border-faint bg-elevated px-2 py-1 font-mono text-xs text-muted hover:text-primary"
                    }
                  >
                    {range}
                  </button>
                ))}
              </div>
            </div>

            <div className="relative mt-4 overflow-hidden rounded-[14px]">
              <svg
                viewBox="0 0 806 252"
                className="block h-[220px] w-full"
                role="img"
                aria-label="Portfolio pnl chart"
              >
                <defs>
                  <linearGradient id="portfolio-fill" x1="0%" x2="0%" y1="0%" y2="100%">
                    <stop offset="0%" stopColor={areaColorTop} />
                    <stop offset="100%" stopColor="rgba(0,0,0,0)" />
                  </linearGradient>
                </defs>
                {/* Grid lines */}
                {[63, 126, 189].map((y) => (
                  <line
                    key={y}
                    x1="24"
                    y1={y}
                    x2="782"
                    y2={y}
                    stroke="rgba(15,20,35,0.05)"
                    strokeWidth="1"
                  />
                ))}
                <path d={snapshot.pnl.fillPath} fill="url(#portfolio-fill)" />
                <path
                  d={snapshot.pnl.linePath}
                  fill="none"
                  stroke={lineColor}
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth="2.5"
                />
                {/* Live-value dot at end of line path */}
                <circle cx="782" cy="72" r="4" fill={lineColor} />
              </svg>
              <div className="absolute inset-x-4 bottom-4 flex justify-between font-mono text-xs text-muted">
                {snapshot.pnl.axis.map((label) => (
                  <span key={label}>{label}</span>
                ))}
              </div>
            </div>

            {/* PnL summary row */}
            {pnlMetric ? (
              <div className="mt-3 flex items-center justify-between gap-3 border-t border-faint pt-3">
                <span className="font-mono text-sm text-secondary">{pnlMetric.label}</span>
                <span
                  className={`font-mono text-sm font-semibold ${
                    isPositiveChange(pnlMetric.value)
                      ? "text-accent-green"
                      : "text-accent-red"
                  }`}
                >
                  {pnlMetric.value}
                </span>
              </div>
            ) : null}
          </div>

          {/* Positions */}
          {snapshot.positions.length > 0 ? (
            <div className="space-y-2">
              <p className="text-xs text-muted">Open positions</p>
              {snapshot.positions.map((position) => (
                <article
                  key={`${position.market}-${position.side}`}
                  className="data-card flex items-center justify-between gap-3"
                >
                  <div className="min-w-0">
                    <p className="truncate font-mono text-sm text-primary">
                      {position.market}
                    </p>
                    <p className="mt-0.5 text-xs uppercase tracking-[0.18em] text-muted">
                      {position.side}
                    </p>
                  </div>
                  <div className="flex shrink-0 items-center gap-3 text-sm">
                    <span className="font-mono text-muted">{position.size}</span>
                    <strong className="font-mono font-semibold text-primary">
                      {position.mark}
                    </strong>
                    <span className="rounded-[8px] border border-faint bg-elevated px-2 py-0.5 font-mono text-xs text-muted">
                      {position.state}
                    </span>
                  </div>
                </article>
              ))}
            </div>
          ) : null}
        </div>

        {/* Right column — Trading Balance + Transfer */}
        <div className="min-w-0 space-y-4">
          {/* Trading Balance header */}
          <div className="min-w-0">
            <p className="text-xs text-muted">Trading balance</p>
            <p className="mt-2 font-mono text-4xl font-semibold text-primary">
              {tradingMetric?.value ?? "—"}
            </p>
            <p className="mt-1 font-mono text-sm text-secondary">
              USDsui · available to trade
            </p>
          </div>

          {/* Transfer card */}
          <div className="panel-shell min-w-0 overflow-hidden space-y-4 p-4">
            {/* Header row */}
            <div className="flex flex-wrap items-center justify-between gap-2">
              <p className="text-xs text-muted">Transfer</p>
              <div role="tablist" className="flex flex-wrap items-center rounded-[10px] border border-faint bg-rail p-0.5">
                <button
                  role="tab"
                  type="button"
                  aria-selected={transferMode === "deposit"}
                  onClick={() => setTransferMode("deposit")}
                  className={
                    transferMode === "deposit"
                      ? "rounded-[8px] border border-strong bg-elevated px-3 py-1 text-xs font-medium text-primary"
                      : "rounded-[8px] px-3 py-1 text-xs font-medium text-muted hover:text-primary"
                  }
                >
                  Deposit
                </button>
                <button
                  role="tab"
                  type="button"
                  aria-selected={transferMode === "withdraw"}
                  onClick={() => setTransferMode("withdraw")}
                  className={
                    transferMode === "withdraw"
                      ? "rounded-[8px] border border-strong bg-elevated px-3 py-1 text-xs font-medium text-primary"
                      : "rounded-[8px] px-3 py-1 text-xs font-medium text-muted hover:text-primary"
                  }
                >
                  Withdraw
                </button>
              </div>
            </div>

            {/* From-lane */}
            <div className="data-card min-w-0 overflow-hidden">
              <p className="text-xs text-muted">
                {transferMode === "deposit" ? "From wallet" : "From trading"}
              </p>
              <p className="mt-2 min-w-0 overflow-hidden text-ellipsis whitespace-nowrap font-mono text-[26px] text-primary">
                {sourceBalanceValue ?? "—"}
              </p>
              <p className="mt-1 font-mono text-xs text-muted">
                {transferMode === "deposit" ? "Wallet balance" : "Manager balance"}
              </p>
            </div>

            {/* Arrow divider */}
            <div className="py-2 text-center text-muted">↓</div>

            {/* To-lane */}
            <div className="data-card min-w-0 overflow-hidden">
              <p className="text-xs text-muted">
                {transferMode === "deposit" ? "To trading" : "To wallet"}
              </p>
              <p className="mt-2 min-w-0 overflow-hidden text-ellipsis whitespace-nowrap font-mono text-[26px] text-primary">
                {destinationBalanceValue ?? "—"}
              </p>
            </div>

            {/* Amount input */}
            <input
              aria-label="Transfer amount"
              value={amountValue}
              onChange={(event) => onAmountChange?.(event.target.value)}
              inputMode="decimal"
              placeholder="250"
              className="w-full min-w-0 rounded-[12px] border border-faint bg-rail px-3 py-3 font-mono text-sm text-primary outline-none transition placeholder:text-muted focus:border-strong"
            />

            {/* Preset chips */}
            <div className="flex gap-2">
              {["25%", "50%", "75%", "Max"].map((preset) => (
                <button
                  key={preset}
                  type="button"
                  className="border border-faint bg-elevated text-secondary hover:text-primary rounded-[8px] px-2 py-1 font-mono text-xs"
                >
                  {preset}
                </button>
              ))}
            </div>

            {/* CTA button */}
            <button
              type="button"
              onClick={transferMode === "deposit" ? onDeposit : onWithdraw}
              disabled={
                !walletConnected ||
                isPending ||
                (transferMode === "deposit" ? depositDisabled : withdrawDisabled)
              }
              className="w-full rounded-[12px] bg-accent-gold py-3 font-mono text-sm font-bold text-white transition hover:brightness-110 disabled:opacity-60"
            >
              {isPending
                ? "Pending..."
                : transferMode === "deposit"
                  ? snapshot.transferRail.actions[0]
                  : snapshot.transferRail.actions[1]}
            </button>

            {/* Status message */}
            {statusMessage ? (
              <p className="font-mono text-sm text-muted">{statusMessage}</p>
            ) : null}
          </div>

          {/* Balance summary */}
          {snapshot.transferRail.balances.length > 0 ? (
            <div className="panel-shell min-w-0 overflow-hidden p-4">
              <p className="text-xs text-muted mb-3">Balances</p>
              <div className="space-y-2">
                {snapshot.transferRail.balances.map((item) => (
                  <div key={item.label} className="flex items-center justify-between gap-3">
                    <span className="text-sm text-secondary">{item.label}</span>
                    <strong className="font-mono text-sm font-semibold text-primary">
                      {item.value}
                    </strong>
                  </div>
                ))}
              </div>
            </div>
          ) : null}
        </div>
      </div>
    </PageShell>
  );
}
