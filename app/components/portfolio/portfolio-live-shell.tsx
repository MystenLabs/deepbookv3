"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  useCurrentAccount,
  useCurrentClient,
  useDAppKit,
} from "@mysten/dapp-kit-react";

import { PortfolioShell } from "@/components/portfolio/portfolio-shell";
import { getPortfolioPageData } from "@/lib/api/predict-server";
import { getPublicAppConfig } from "@/lib/config";
import {
  ensureManagerId,
  formatActionError,
  parseUsdAmountInput,
  signAndWaitForTransaction,
} from "@/lib/sui/predict-runtime";
import {
  formatQuoteBalance,
  readManagerQuoteBalance,
  readQuoteAssetMetadata,
  readWalletQuoteBalance,
} from "@/lib/sui/predict-balances";
import {
  buildManagerDepositTransaction,
  buildManagerWithdrawTransaction,
} from "@/lib/sui/predict-transactions";

type PortfolioPageData = Awaited<ReturnType<typeof getPortfolioPageData>>;

type PortfolioLiveShellProps = {
  initialData: PortfolioPageData;
};

export function PortfolioLiveShell({ initialData }: PortfolioLiveShellProps) {
  const account = useCurrentAccount();
  const client = useCurrentClient();
  const dAppKit = useDAppKit();
  const publicConfig = useMemo(() => getPublicAppConfig(), []);
  const ownerAddress = account?.address ?? null;
  const [data, setData] = useState(initialData);
  const [amountValue, setAmountValue] = useState("");
  const [isPending, setIsPending] = useState(false);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [walletBalanceValue, setWalletBalanceValue] = useState<string | null>(null);
  const [managerBalanceValue, setManagerBalanceValue] = useState<string | null>(null);
  const latestRefreshRequestRef = useRef(0);
  const latestOwnerRef = useRef<string | null>(ownerAddress);

  const refreshPortfolioSnapshot = useCallback(
    async (overrideOwner?: string | null) => {
      const nextOwner = overrideOwner ?? ownerAddress;
      const requestId = latestRefreshRequestRef.current + 1;
      latestRefreshRequestRef.current = requestId;
      const search = nextOwner ? `?owner=${encodeURIComponent(nextOwner)}` : "";
      const response = await fetch(`/api/portfolio${search}`, {
        cache: "no-store",
      });

      if (!response.ok) {
        throw new Error(`portfolio refresh failed with ${response.status}`);
      }

      const nextData = (await response.json()) as PortfolioPageData;
      if (
        requestId !== latestRefreshRequestRef.current ||
        nextOwner !== latestOwnerRef.current
      ) {
        return false;
      }

      setData(nextData);
      return true;
    },
    [ownerAddress],
  );

  useEffect(() => {
    latestOwnerRef.current = ownerAddress;
  }, [ownerAddress]);

  useEffect(() => {
    if (data.source.mode !== "remote") {
      return;
    }

    void refreshPortfolioSnapshot(ownerAddress).catch((error: unknown) => {
      console.error(error);
    });
  }, [data.source.mode, ownerAddress, refreshPortfolioSnapshot]);

  useEffect(() => {
    setAmountValue("");
    setIsPending(false);
    setStatusMessage(null);
  }, [ownerAddress]);

  useEffect(() => {
    const meta = data.snapshot.meta;

    if (!client || !ownerAddress || !meta?.quoteAsset) {
      setWalletBalanceValue(null);
      setManagerBalanceValue(null);
      return;
    }

    let cancelled = false;
    setWalletBalanceValue(null);
    setManagerBalanceValue(null);

    const refreshLiveBalances = async () => {
      try {
        const metadata = await readQuoteAssetMetadata(client, meta.quoteAsset);

        let nextWalletBalanceValue: string | null = null;
        let nextManagerBalanceValue: string | null = null;

        try {
          const walletBalance = await readWalletQuoteBalance(client, {
            owner: ownerAddress,
            coinType: meta.quoteAsset,
          });
          nextWalletBalanceValue = formatQuoteBalance(walletBalance, metadata);
        } catch {
          nextWalletBalanceValue = formatQuoteBalance(null, metadata);
        }

        if (meta.managerState === "ready" && meta.managerId) {
          try {
            const managerBalance = await readManagerQuoteBalance(client, {
              managerId: meta.managerId,
              coinType: meta.quoteAsset,
            });
            nextManagerBalanceValue = formatQuoteBalance(managerBalance, metadata);
          } catch {
            nextManagerBalanceValue = formatQuoteBalance(null, metadata);
          }
        } else {
          nextManagerBalanceValue = formatQuoteBalance(null, metadata);
        }

        if (cancelled) {
          return;
        }

        setWalletBalanceValue(nextWalletBalanceValue);
        setManagerBalanceValue(nextManagerBalanceValue);
      } catch {
        if (cancelled) {
          return;
        }

        setWalletBalanceValue("—");
        setManagerBalanceValue("—");
      }
    };

    void refreshLiveBalances();

    return () => {
      cancelled = true;
    };
  }, [client, ownerAddress, data.snapshot]);

  const handleDeposit = async () => {
    if (!account || !client || !dAppKit) {
      setStatusMessage("Connect wallet to move funds.");
      return;
    }

    const meta = data.snapshot.meta;
    const amount = parseUsdAmountInput(amountValue);

    if (meta?.managerState === "duplicate") {
      setStatusMessage("Multiple PredictManagers were found for this wallet.");
      return;
    }

    if (!meta?.quoteAsset || amount <= 0) {
      setStatusMessage("Enter an amount to deposit.");
      return;
    }

    setIsPending(true);
    setStatusMessage(
      meta?.managerState === "missing"
        ? "Creating manager and depositing funds..."
        : "Depositing funds...",
    );

    try {
      const managerId = await ensureManagerId({
        dAppKit,
        client,
        packageId: publicConfig.predictPackageId,
        ownerAddress: account.address,
        predictServerUrl: data.source.predictServerUrl,
        existingManagerId: meta.managerId,
      });

      await signAndWaitForTransaction(
        dAppKit,
        client,
        buildManagerDepositTransaction({
          packageId: publicConfig.predictPackageId,
          managerId,
          quoteAsset: meta.quoteAsset,
          amount,
        }),
      );

      setStatusMessage("Funds deposited.");
      setAmountValue("");
      await refreshPortfolioSnapshot(account.address);
    } catch (error) {
      setStatusMessage(formatActionError(error));
    } finally {
      setIsPending(false);
    }
  };

  const handleWithdraw = async () => {
    if (!account || !client || !dAppKit) {
      setStatusMessage("Connect wallet to move funds.");
      return;
    }

    const meta = data.snapshot.meta;
    const amount = parseUsdAmountInput(amountValue);

    if (meta?.managerState === "duplicate") {
      setStatusMessage("Multiple PredictManagers were found for this wallet.");
      return;
    }

    if (!meta?.managerId || !meta.quoteAsset || amount <= 0) {
      setStatusMessage("No manager balance is available to withdraw.");
      return;
    }

    setIsPending(true);
    setStatusMessage("Withdrawing funds...");

    try {
      await signAndWaitForTransaction(
        dAppKit,
        client,
        buildManagerWithdrawTransaction({
          packageId: publicConfig.predictPackageId,
          managerId: meta.managerId,
          quoteAsset: meta.quoteAsset,
          amount,
          recipient: account.address,
        }),
      );

      setStatusMessage("Funds withdrawn.");
      setAmountValue("");
      await refreshPortfolioSnapshot(account.address);
    } catch (error) {
      setStatusMessage(formatActionError(error));
    } finally {
      setIsPending(false);
    }
  };

  return (
    <PortfolioShell
      {...data.runtime}
      snapshot={data.snapshot}
      walletBalanceValue={walletBalanceValue}
      managerBalanceValue={managerBalanceValue}
      amountValue={amountValue}
      walletConnected={Boolean(account)}
      isPending={isPending}
      statusMessage={
        statusMessage ??
        (!account
          ? "Connect wallet to move funds."
          : data.snapshot.meta?.managerState === "duplicate"
            ? "Multiple PredictManagers were found for this wallet."
            : null)
      }
      depositDisabled={data.snapshot.meta?.managerState === "duplicate"}
      withdrawDisabled={data.snapshot.meta?.managerState !== "ready"}
      onAmountChange={setAmountValue}
      onDeposit={handleDeposit}
      onWithdraw={handleWithdraw}
    />
  );
}
