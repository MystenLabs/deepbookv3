import React from "react";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { PortfolioLiveShell } from "@/components/portfolio/portfolio-live-shell";
import { portfolioShellMock } from "@/lib/mocks/portfolio";
import {
  formatQuoteBalance,
  readManagerQuoteBalance,
  readQuoteAssetMetadata,
  readWalletQuoteBalance,
} from "@/lib/sui/predict-balances";

let mockAccount: { address: string } | null = null;
let mockClient: {
  waitForTransaction: ReturnType<typeof vi.fn>;
  getObjects: ReturnType<typeof vi.fn>;
} | null = null;
let mockDAppKit: {
  signAndExecuteTransaction: ReturnType<typeof vi.fn>;
} | null = null;

vi.mock("@mysten/dapp-kit-react", () => ({
  useCurrentAccount: () => mockAccount,
  useCurrentClient: () => mockClient,
  useDAppKit: () => mockDAppKit,
}));

vi.mock("@/lib/sui/predict-balances", () => ({
  readQuoteAssetMetadata: vi.fn(),
  readWalletQuoteBalance: vi.fn(),
  readManagerQuoteBalance: vi.fn(),
  formatQuoteBalance: vi.fn(),
}));

function jsonResponse(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: {
      "content-type": "application/json",
    },
  });
}

function deferredResponse() {
  let resolve!: (value: Response) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<Response>((nextResolve, nextReject) => {
    resolve = nextResolve;
    reject = nextReject;
  });

  return { promise, resolve, reject };
}

describe("PortfolioLiveShell", () => {
  const fetchMock = vi.fn<typeof fetch>();

  beforeEach(() => {
    mockAccount = null;
    mockClient = null;
    mockDAppKit = null;
    fetchMock.mockReset();
    vi.stubGlobal("fetch", fetchMock);
    vi.mocked(readQuoteAssetMetadata).mockReset();
    vi.mocked(readWalletQuoteBalance).mockReset();
    vi.mocked(readManagerQuoteBalance).mockReset();
    vi.mocked(formatQuoteBalance).mockReset();
    vi.mocked(readQuoteAssetMetadata).mockResolvedValue({
      decimals: 6,
      symbol: "USDs",
    });
    vi.mocked(formatQuoteBalance).mockImplementation((balance) =>
      balance === null || balance === undefined ? "—" : `$${balance.toString()}`,
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("refreshes the portfolio snapshot for the connected wallet owner", async () => {
    mockAccount = {
      address:
        "0x2222222222222222222222222222222222222222222222222222222222222222",
    };

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
          ...portfolioShellMock,
          metrics: [
            { label: "Account value", value: "$1,115.00", change: "2 open positions" },
            { label: "Trading balance", value: "$900.00", change: "$220.00 committed" },
            { label: "Settled PnL", value: "+$135.00", change: "Redeemable $40.00" },
          ],
        },
      }),
    );

    render(
      <PortfolioLiveShell
        initialData={{
          runtime: {
            networkLabel: "Testnet",
            sourceLabel: "Predict server",
            sourceTone: "warning",
          },
          source: {
            mode: "remote",
            predictServerUrl: "https://predict.example.test",
          },
          snapshot: portfolioShellMock,
        }}
      />,
    );

    await waitFor(() => {
      expect(screen.getByText("$1,115.00")).toBeInTheDocument();
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/portfolio?owner=0x2222222222222222222222222222222222222222222222222222222222222222",
      expect.objectContaining({
        cache: "no-store",
      }),
    );
    expect(screen.getByText("$900.00")).toBeInTheDocument();
  });

  it("submits manager deposits from the portfolio rail and refreshes the owner snapshot", async () => {
    mockAccount = {
      address:
        "0x2222222222222222222222222222222222222222222222222222222222222222",
    };
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
      getObjects: vi.fn(),
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
            ...portfolioShellMock,
            meta: {
              ...portfolioShellMock.meta,
              managerId: "0xmanager",
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
            ...portfolioShellMock,
            meta: {
              ...portfolioShellMock.meta,
              managerId: "0xmanager",
            },
            metrics: [
              { label: "Account value", value: "$1,300.00", change: "2 open positions" },
              { label: "Trading balance", value: "$1,050.00", change: "$250.00 committed" },
              { label: "Settled PnL", value: "+$135.00", change: "Redeemable $40.00" },
            ],
          },
        }),
      );

    render(
      <PortfolioLiveShell
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
            ...portfolioShellMock,
            meta: {
              ...portfolioShellMock.meta,
              managerId: "0xmanager",
            },
          },
        }}
      />,
    );

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        "/api/portfolio?owner=0x2222222222222222222222222222222222222222222222222222222222222222",
        expect.objectContaining({
          cache: "no-store",
        }),
      );
    });
    await waitFor(() => {
      expect(readWalletQuoteBalance).toHaveBeenCalled();
    });

    fireEvent.change(screen.getByLabelText(/transfer amount/i), {
      target: { value: "250" },
    });
    fireEvent.click(screen.getByRole("button", { name: /deposit/i }));

    await waitFor(() => {
      expect(mockDAppKit?.signAndExecuteTransaction).toHaveBeenCalledTimes(1);
    });
    await waitFor(() => {
      expect(screen.getByText("$1,300.00")).toBeInTheDocument();
    });
  });

  it("ignores stale action completion UI updates after switching owners mid-withdraw", async () => {
    const ownerA =
      "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const ownerB =
      "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const pendingConfirmation = deferredResponse();

    mockAccount = { address: ownerA };
    mockDAppKit = {
      signAndExecuteTransaction: vi.fn().mockResolvedValue({
        $kind: "Transaction",
        Transaction: {
          digest: "0xwithdraw",
        },
      }),
    };
    mockClient = {
      waitForTransaction: vi.fn().mockReturnValue(pendingConfirmation.promise),
      getObjects: vi.fn(),
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
            ...portfolioShellMock,
            meta: {
              ...portfolioShellMock.meta,
              managerId: "0xmanager-a",
              managerState: "ready",
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
            ...portfolioShellMock,
            meta: {
              ...portfolioShellMock.meta,
              managerId: "0xmanager-b",
              managerState: "ready",
            },
          },
        }),
      );

    const view = render(
      <PortfolioLiveShell
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
            ...portfolioShellMock,
            meta: {
              ...portfolioShellMock.meta,
              managerId: "0xmanager-a",
              managerState: "ready",
            },
          },
        }}
      />,
    );

    await waitFor(() => {
      expect(readManagerQuoteBalance).toHaveBeenCalled();
    });

    fireEvent.click(screen.getByRole("tab", { name: /withdraw/i }));
    fireEvent.change(screen.getByLabelText(/transfer amount/i), {
      target: { value: "250" },
    });
    fireEvent.click(screen.getByRole("button", { name: /withdraw/i }));

    await waitFor(() => {
      expect(screen.getByText("Withdrawing funds...")).toBeInTheDocument();
    });

    mockAccount = { address: ownerB };
    view.rerender(
      <PortfolioLiveShell
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
            ...portfolioShellMock,
            meta: {
              ...portfolioShellMock.meta,
              managerId: "0xmanager-a",
              managerState: "ready",
            },
          },
        }}
      />,
    );

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        `/api/portfolio?owner=${ownerB}`,
        expect.objectContaining({ cache: "no-store" }),
      );
    });

    fireEvent.click(screen.getByRole("tab", { name: /withdraw/i }));
    fireEvent.change(screen.getByLabelText(/transfer amount/i), {
      target: { value: "777" },
    });

    await act(async () => {
      pendingConfirmation.resolve({
        $kind: "Transaction",
        Transaction: {
          digest: "0xwithdraw",
          effects: {
            changedObjects: [],
          },
        },
      });
      await Promise.resolve();
    });

    expect(screen.queryByText("Funds withdrawn.")).not.toBeInTheDocument();
    expect(screen.queryByText("Withdrawing funds...")).not.toBeInTheDocument();
    expect(screen.getByLabelText(/transfer amount/i)).toHaveValue("777");
  });

  it("shows live wallet and manager balances on the transfer rail in deposit mode", async () => {
    mockAccount = {
      address:
        "0x2222222222222222222222222222222222222222222222222222222222222222",
    };
    mockClient = {
      waitForTransaction: vi.fn(),
      getObjects: vi.fn(),
    };
    vi.mocked(readWalletQuoteBalance).mockResolvedValue(4250n);
    vi.mocked(readManagerQuoteBalance).mockResolvedValue(3100n);

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
          ...portfolioShellMock,
          transferRail: {
            ...portfolioShellMock.transferRail,
            balances: [
              { label: "Available to trade", value: "$3,100.00" },
              { label: "Collateral in positions", value: "$6,500.00" },
            ],
          },
          meta: {
            ...portfolioShellMock.meta,
            managerState: "ready",
          },
        },
      }),
    );

    render(
      <PortfolioLiveShell
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
          snapshot: portfolioShellMock,
        }}
      />,
    );

    await waitFor(() => {
      expect(readWalletQuoteBalance).toHaveBeenCalled();
    });

    expect(screen.getByText("From wallet")).toBeInTheDocument();
    expect(screen.getByText("To trading")).toBeInTheDocument();
    expect(screen.getByText("$4250")).toBeInTheDocument();
    expect(screen.getByText("$3100")).toBeInTheDocument();
    expect(screen.getByText("Available to trade")).toBeInTheDocument();
    expect(screen.getByText("$3,100.00")).toBeInTheDocument();
  });

  it("swaps the live wallet and manager balances in withdraw mode", async () => {
    mockAccount = {
      address:
        "0x2222222222222222222222222222222222222222222222222222222222222222",
    };
    mockClient = {
      waitForTransaction: vi.fn(),
      getObjects: vi.fn(),
    };
    vi.mocked(readWalletQuoteBalance).mockResolvedValue(4250n);
    vi.mocked(readManagerQuoteBalance).mockResolvedValue(3100n);

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
          ...portfolioShellMock,
          meta: {
            ...portfolioShellMock.meta,
            managerState: "ready",
          },
        },
      }),
    );

    render(
      <PortfolioLiveShell
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
          snapshot: portfolioShellMock,
        }}
      />,
    );

    await waitFor(() => {
      expect(readManagerQuoteBalance).toHaveBeenCalled();
    });

    fireEvent.click(screen.getByRole("tab", { name: /withdraw/i }));

    expect(screen.getByText("From trading")).toBeInTheDocument();
    expect(screen.getByText("To wallet")).toBeInTheDocument();
    expect(screen.getByText("$3100")).toBeInTheDocument();
    expect(screen.getByText("$4250")).toBeInTheDocument();
  });

  it("shows unknown live balances as em dashes and skips manager reads until the manager is ready", async () => {
    mockAccount = {
      address:
        "0x2222222222222222222222222222222222222222222222222222222222222222",
    };
    mockClient = {
      waitForTransaction: vi.fn(),
      getObjects: vi.fn(),
    };
    vi.mocked(readWalletQuoteBalance).mockRejectedValue(new Error("wallet balance unavailable"));

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
          ...portfolioShellMock,
          metrics: [
            { label: "Account value", value: "$47,000.00", change: "2 open positions" },
            { label: "Trading balance", value: "$0.00", change: "$0.00 committed" },
            { label: "Settled PnL", value: "+$135.00", change: "Redeemable $40.00" },
          ],
          meta: {
            ...portfolioShellMock.meta,
            managerId: null,
            managerState: "missing",
          },
        },
      }),
    );

    render(
      <PortfolioLiveShell
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
            ...portfolioShellMock,
            meta: {
              ...portfolioShellMock.meta,
              managerId: null,
              managerState: "missing",
            },
          },
        }}
      />,
    );

    await waitFor(() => {
      expect(readWalletQuoteBalance).toHaveBeenCalled();
    });

    const laneValues = screen.getAllByText("—");
    expect(laneValues.length).toBeGreaterThanOrEqual(2);
    expect(readManagerQuoteBalance).not.toHaveBeenCalled();
  });

  it("blocks the portfolio transfer flow when the indexed owner has duplicate managers", async () => {
    mockAccount = {
      address:
        "0x2222222222222222222222222222222222222222222222222222222222222222",
    };
    mockDAppKit = {
      signAndExecuteTransaction: vi.fn(),
    };
    mockClient = {
      waitForTransaction: vi.fn(),
      getObjects: vi.fn(),
    };

    fetchMock.mockResolvedValueOnce(
      jsonResponse({
        runtime: {
          networkLabel: "Testnet",
          sourceLabel: "Predict server",
          sourceTone: "warning",
        },
        source: {
          mode: "remote",
          predictServerUrl: "https://predict.example.test",
        },
        snapshot: {
          ...portfolioShellMock,
          metrics: [
            { label: "Account value", value: "$47,000.00", change: "2 open positions" },
            { label: "Trading balance", value: "$0.00", change: "$0.00 committed" },
            { label: "Settled PnL", value: "+$135.00", change: "Redeemable $40.00" },
          ],
          meta: {
            ...portfolioShellMock.meta,
            managerId: null,
            managerState: "duplicate",
            managerCount: 2,
            tradingBalance: 0,
          },
        },
      }),
    );

    render(
      <PortfolioLiveShell
        initialData={{
          runtime: {
            networkLabel: "Testnet",
            sourceLabel: "Predict server",
            sourceTone: "warning",
          },
          source: {
            mode: "remote",
            predictServerUrl: "https://predict.example.test",
          },
          snapshot: {
            ...portfolioShellMock,
            meta: {
              ...portfolioShellMock.meta,
              managerId: null,
              managerState: "duplicate",
              managerCount: 2,
              tradingBalance: 0,
            },
          },
        }}
      />,
    );

    await waitFor(() => {
      expect(screen.getByText("$47,000.00")).toBeInTheDocument();
    });
    await waitFor(() => {
      expect(readWalletQuoteBalance).toHaveBeenCalled();
    });

    fireEvent.change(screen.getByLabelText(/transfer amount/i), {
      target: { value: "250" },
    });
    fireEvent.click(screen.getByRole("button", { name: /deposit/i }));

    expect(mockDAppKit.signAndExecuteTransaction).not.toHaveBeenCalled();
    expect(screen.getByText("Multiple PredictManagers were found for this wallet.")).toBeInTheDocument();
  });

  it("ignores stale owner refresh responses after an account switch", async () => {
    const ownerA =
      "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const ownerB =
      "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    mockAccount = { address: ownerA };
    mockClient = {
      waitForTransaction: vi.fn(),
      getObjects: vi.fn(),
    };

    const ownerAResponse = deferredResponse();
    const ownerBResponse = deferredResponse();

    fetchMock
      .mockReturnValueOnce(ownerAResponse.promise)
      .mockReturnValueOnce(ownerBResponse.promise);

    const view = render(
      <PortfolioLiveShell
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
            ...portfolioShellMock,
            metrics: [
              { label: "Account value", value: "$100.00", change: "1 open position" },
              { label: "Trading balance", value: "$50.00", change: "$10.00 committed" },
              { label: "Settled PnL", value: "+$5.00", change: "Redeemable $1.00" },
            ],
          },
        }}
      />,
    );

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        `/api/portfolio?owner=${ownerA}`,
        expect.objectContaining({ cache: "no-store" }),
      );
    });

    mockAccount = { address: ownerB };
    view.rerender(
      <PortfolioLiveShell
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
            ...portfolioShellMock,
            metrics: [
              { label: "Account value", value: "$100.00", change: "1 open position" },
              { label: "Trading balance", value: "$50.00", change: "$10.00 committed" },
              { label: "Settled PnL", value: "+$5.00", change: "Redeemable $1.00" },
            ],
          },
        }}
      />,
    );

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        `/api/portfolio?owner=${ownerB}`,
        expect.objectContaining({ cache: "no-store" }),
      );
    });

    await act(async () => {
      ownerBResponse.resolve(
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
            ...portfolioShellMock,
            metrics: [
              { label: "Account value", value: "$222.00", change: "2 open positions" },
              { label: "Trading balance", value: "$120.00", change: "$20.00 committed" },
              { label: "Settled PnL", value: "+$12.00", change: "Redeemable $2.00" },
            ],
          },
        }),
      );
      await Promise.resolve();
    });

    await waitFor(() => {
      expect(screen.getByText("$222.00")).toBeInTheDocument();
    });

    await act(async () => {
      ownerAResponse.resolve(
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
            ...portfolioShellMock,
            metrics: [
              { label: "Account value", value: "$111.00", change: "stale owner" },
              { label: "Trading balance", value: "$80.00", change: "$10.00 committed" },
              { label: "Settled PnL", value: "+$8.00", change: "Redeemable $1.00" },
            ],
          },
        }),
      );
      await Promise.resolve();
    });

    expect(screen.getByText("$222.00")).toBeInTheDocument();
    expect(screen.queryByText("$111.00")).not.toBeInTheDocument();
  });

  it("resets owner-specific status messages when the wallet context changes", async () => {
    const ownerA =
      "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const ownerB =
      "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    mockAccount = { address: ownerA };
    mockClient = {
      waitForTransaction: vi.fn(),
      getObjects: vi.fn(),
    };
    mockDAppKit = {
      signAndExecuteTransaction: vi.fn(),
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
            ...portfolioShellMock,
            meta: {
              ...portfolioShellMock.meta,
              managerId: "0xmanager-a",
              managerState: "ready",
              managerCount: 1,
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
            ...portfolioShellMock,
            meta: {
              ...portfolioShellMock.meta,
              managerId: "0xmanager-b",
              managerState: "ready",
              managerCount: 1,
            },
          },
        }),
      );

    const view = render(
      <PortfolioLiveShell
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
            ...portfolioShellMock,
            meta: {
              ...portfolioShellMock.meta,
              managerId: "0xmanager-a",
              managerState: "ready",
              managerCount: 1,
            },
          },
        }}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: /deposit/i }));
    expect(screen.getByText("Enter an amount to deposit.")).toBeInTheDocument();

    mockAccount = { address: ownerB };
    view.rerender(
      <PortfolioLiveShell
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
            ...portfolioShellMock,
            meta: {
              ...portfolioShellMock.meta,
              managerId: "0xmanager-a",
              managerState: "ready",
              managerCount: 1,
            },
          },
        }}
      />,
    );

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        `/api/portfolio?owner=${ownerB}`,
        expect.objectContaining({ cache: "no-store" }),
      );
    });

    await waitFor(() => {
      expect(screen.queryByText("Enter an amount to deposit.")).not.toBeInTheDocument();
    });
  });
});
