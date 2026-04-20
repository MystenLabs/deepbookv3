import React from "react";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { TradeLiveShell } from "@/components/trade/trade-live-shell";
import { tradeShellMock } from "@/lib/mocks/trade";
import { readManagerQuoteBalance } from "@/lib/sui/predict-balances";

let mockAccount: { address: string } | null = null;
let mockClient: {
  waitForTransaction: ReturnType<typeof vi.fn>;
} | null = null;
let mockDAppKit: {
  signAndExecuteTransaction: ReturnType<typeof vi.fn>;
} | null = null;

vi.mock("@mysten/dapp-kit-react", () => ({
  useCurrentAccount: () => mockAccount,
  useCurrentClient: () => mockClient,
  useDAppKit: () => mockDAppKit,
}));

vi.mock("@/lib/sui/oracle-store", () => ({
  useOracle: () => ({
    status: "idle" as const,
    spot: null,
    svi: null,
    priceBuffer: [],
    sviBuffer: [],
    lastEventAtMs: null,
    expiryMs: 0,
    lastError: null,
    isStale: false,
    retry: vi.fn(),
  }),
  useQuotes: () => ({
    up: null,
    down: null,
  }),
  useChartPoints: () => ({
    points: [],
    currentValue: null,
    domainMin: 0,
    domainMax: 1,
  }),
  useCountdown: () => ({
    label: "12m 00s",
    urgent: false,
    critical: false,
  }),
}));

vi.mock("@/lib/sui/predict-balances", () => ({
  readManagerQuoteBalance: vi.fn(),
}));

function jsonResponse(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: {
      "content-type": "application/json",
    },
  });
}

describe("TradeLiveShell", () => {
  const fetchMock = vi.fn<typeof fetch>();

  beforeEach(() => {
    mockAccount = null;
    mockClient = null;
    mockDAppKit = null;
    fetchMock.mockReset();
    vi.stubGlobal("fetch", fetchMock);
    vi.mocked(readManagerQuoteBalance).mockReset();
    vi.mocked(readManagerQuoteBalance).mockResolvedValue(0n);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("refetches trade data for the connected owner and swaps in owner positions", async () => {
    mockAccount = { address: "0xowner" };

    fetchMock.mockResolvedValueOnce(
      jsonResponse({
        runtime: {
          networkLabel: "Testnet",
          sourceLabel: "Predict server",
          sourceTone: "positive",
        },
        source: {
          mode: "remote",
          predictServerUrl: "https://predict.example.test",
        },
        snapshot: {
          ...tradeShellMock,
          positions: [
            {
              market: "BTC · Today 2 PM",
              side: "UP",
              strike: "$86,250",
              entry: "0.51",
              mark: "0.59",
              pnl: "+$112",
              state: "Active",
            },
          ],
        },
      }),
    );

    render(
      <TradeLiveShell
        initialData={{
          runtime: {
            networkLabel: "Testnet",
            sourceLabel: "Predict server",
            sourceTone: "positive",
          },
          source: {
            mode: "remote",
            predictServerUrl: "https://predict.example.test",
          },
          snapshot: {
            ...tradeShellMock,
            positions: [],
          },
        }}
      />,
    );

    await waitFor(() => {
      expect(screen.getByText("1 active positions")).toBeInTheDocument();
    });

    expect(fetchMock).toHaveBeenCalledWith(
      `/api/trade?owner=0xowner&oracle=${encodeURIComponent(
        tradeShellMock.meta?.selectedOracleId ?? "",
      )}&strike=${tradeShellMock.meta?.selectedStrikeValue ?? ""}`,
      expect.objectContaining({
        cache: "no-store",
      }),
    );
    expect(screen.getByText("BTC · Today 2 PM")).toBeInTheDocument();
  });

  it("keeps the trade CTA disabled and links to portfolio when no funded manager exists", async () => {
    mockAccount = { address: "0xowner" };

    fetchMock.mockResolvedValueOnce(
      jsonResponse({
        runtime: {
          networkLabel: "Testnet",
          sourceLabel: "Predict server",
          sourceTone: "positive",
        },
        source: {
          mode: "remote",
          predictServerUrl: "https://predict.example.test",
        },
        snapshot: {
          ...tradeShellMock,
          meta: {
            ...tradeShellMock.meta,
            managerId: null,
            managerState: "missing",
            tradingBalance: 0,
            canTrade: false,
            tradeBlockedReason: "Fund your PredictManager on Portfolio.",
          },
          positions: [],
        },
      }),
    );

    render(
      <TradeLiveShell
        initialData={{
          runtime: {
            networkLabel: "Testnet",
            sourceLabel: "Predict server",
            sourceTone: "positive",
          },
          source: {
            mode: "remote",
            predictServerUrl: "https://predict.example.test",
          },
          snapshot: {
            ...tradeShellMock,
            meta: {
              ...tradeShellMock.meta,
              managerId: null,
              managerState: "missing",
              tradingBalance: 0,
              canTrade: false,
              tradeBlockedReason: "Fund your PredictManager on Portfolio.",
            },
            positions: [],
          },
        }}
      />,
    );

    await waitFor(() => {
      expect(screen.getByText("Fund your PredictManager on Portfolio.")).toBeInTheDocument();
    });

    expect(screen.getByRole("button", { name: /buy up/i })).toBeDisabled();
    expect(screen.getByRole("link", { name: /fund on portfolio/i })).toHaveAttribute(
      "href",
      "/portfolio",
    );
  });

  it("shows an indexing sync message when chain balance is funded before indexed trading balance catches up", async () => {
    mockAccount = { address: "0xowner" };
    mockClient = {
      waitForTransaction: vi.fn(),
    };
    vi.mocked(readManagerQuoteBalance).mockResolvedValue(1_000_000n);

    fetchMock.mockResolvedValueOnce(
      jsonResponse({
        runtime: {
          networkLabel: "Testnet",
          sourceLabel: "Predict server",
          sourceTone: "positive",
        },
        source: {
          mode: "remote",
          predictServerUrl: "https://predict.example.test",
        },
        snapshot: {
          ...tradeShellMock,
          meta: {
            ...tradeShellMock.meta,
            managerId: "0xmanager",
            managerState: "ready",
            tradingBalance: 0,
            canTrade: false,
            tradeBlockedReason: "Fund your PredictManager on Portfolio.",
          },
          positions: [],
        },
      }),
    );

    render(
      <TradeLiveShell
        initialData={{
          runtime: {
            networkLabel: "Testnet",
            sourceLabel: "Predict server",
            sourceTone: "positive",
          },
          source: {
            mode: "remote",
            predictServerUrl: "https://predict.example.test",
          },
          snapshot: {
            ...tradeShellMock,
            meta: {
              ...tradeShellMock.meta,
              managerId: "0xmanager",
              managerState: "ready",
              tradingBalance: 0,
              canTrade: false,
              tradeBlockedReason: "Fund your PredictManager on Portfolio.",
            },
            positions: [],
          },
        }}
      />,
    );

    await waitFor(() => {
      expect(readManagerQuoteBalance).toHaveBeenCalledWith(
        mockClient,
        expect.objectContaining({
          managerId: "0xmanager",
          coinType: tradeShellMock.meta?.quoteAsset,
        }),
      );
    });

    await waitFor(() => {
      expect(
        screen.getByText("Deposit detected on-chain. Waiting for portfolio state to index."),
      ).toBeInTheDocument();
    });

    expect(screen.getByRole("button", { name: /buy up/i })).toBeDisabled();
    expect(screen.getByRole("link", { name: /fund on portfolio/i })).toHaveAttribute(
      "href",
      "/portfolio",
    );
  });

  it("submits a single mint transaction when the indexed manager is funded", async () => {
    mockAccount = { address: "0xowner" };
    mockDAppKit = {
      signAndExecuteTransaction: vi.fn().mockResolvedValue({
        $kind: "Transaction",
        Transaction: {
          digest: "0xdigest",
        },
      }),
    };
    mockClient = {
      waitForTransaction: vi.fn().mockResolvedValue({
        $kind: "Transaction",
        Transaction: {
          digest: "0xdigest",
          effects: {
            changedObjects: [],
          },
        },
      }),
    };

    fetchMock
      .mockResolvedValueOnce(
        jsonResponse({
          runtime: {
            networkLabel: "Testnet",
            sourceLabel: "Predict server",
            sourceTone: "positive",
          },
          source: {
            mode: "remote",
            predictServerUrl: "https://predict.example.test",
          },
          snapshot: {
            ...tradeShellMock,
            meta: {
              ...tradeShellMock.meta,
              managerId: "0xmanager",
              managerState: "ready",
              tradingBalance: 500_000_000,
              canTrade: true,
              tradeBlockedReason: null,
            },
          },
        }),
      )
      .mockResolvedValueOnce(
        jsonResponse({
          runtime: {
            networkLabel: "Testnet",
            sourceLabel: "Predict server",
            sourceTone: "positive",
          },
          source: {
            mode: "remote",
            predictServerUrl: "https://predict.example.test",
          },
          snapshot: {
            ...tradeShellMock,
            meta: {
              ...tradeShellMock.meta,
              managerId: "0xmanager",
              managerState: "ready",
              tradingBalance: 250_000_000,
              canTrade: true,
              tradeBlockedReason: null,
            },
            positions: [
              {
                market: "BTC · Today 2 PM",
                side: "UP",
                strike: "$86,250",
                entry: "0.51",
                mark: "0.59",
                pnl: "+$112",
                state: "Active",
              },
            ],
          },
        }),
      );

    render(
      <TradeLiveShell
        initialData={{
          runtime: {
            networkLabel: "Testnet",
            sourceLabel: "Predict server",
            sourceTone: "positive",
          },
          source: {
            mode: "remote",
            predictServerUrl: "https://predict.example.test",
          },
          snapshot: {
            ...tradeShellMock,
            meta: {
              ...tradeShellMock.meta,
              managerId: "0xmanager",
              managerState: "ready",
              tradingBalance: 500_000_000,
              canTrade: true,
              tradeBlockedReason: null,
            },
          },
        }}
      />,
    );

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        `/api/trade?owner=0xowner&oracle=${encodeURIComponent(
          tradeShellMock.meta?.selectedOracleId ?? "",
        )}&strike=${tradeShellMock.meta?.selectedStrikeValue ?? ""}`,
        expect.objectContaining({
          cache: "no-store",
        }),
      );
    });

    fireEvent.click(screen.getByRole("button", { name: /buy up/i }));

    await waitFor(() => {
      expect(mockDAppKit?.signAndExecuteTransaction).toHaveBeenCalledTimes(1);
    });
  });
});
