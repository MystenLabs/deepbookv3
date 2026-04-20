"use client";

import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  useCurrentAccount,
  useCurrentClient,
  useDAppKit,
} from "@mysten/dapp-kit-react";

import { TradeShell } from "@/components/trade/trade-shell";
import { getPublicAppConfig } from "@/lib/config";
import { getTradePageData } from "@/lib/api/predict-server";
import { useOracle } from "@/lib/sui/oracle-store";
import { readManagerQuoteBalance } from "@/lib/sui/predict-balances";
import { formatActionError, parseUsdAmountInput, signAndWaitForTransaction } from "@/lib/sui/predict-runtime";
import {
  buildMintPositionTransaction,
  buildRedeemPositionTransaction,
} from "@/lib/sui/predict-transactions";
import type {
  TradeExpiryItem,
  TradePositionRow,
  TradeStrikeItem,
} from "@/lib/mocks/trade";

type TradePageData = Awaited<ReturnType<typeof getTradePageData>>;

type TradeLiveShellProps = {
  initialData: TradePageData;
};

function positionKey(position: TradePositionRow) {
  return [
    position.oracleId ?? position.market,
    position.side,
    position.strikeValue ?? position.strike,
    position.quantity ?? "",
  ].join(":");
}

export function TradeLiveShell({ initialData }: TradeLiveShellProps) {
  const account = useCurrentAccount();
  const client = useCurrentClient();
  const dAppKit = useDAppKit();
  const publicConfig = useMemo(() => getPublicAppConfig(), []);
  const ownerAddress = account?.address ?? null;
  const [data, setData] = useState(initialData);
  const [selectedSide, setSelectedSide] = useState<"UP" | "DOWN">("UP");
  const [positionSizeValue, setPositionSizeValue] = useState(
    initialData.snapshot.positionSize.replace(/[$,\s]/g, ""),
  );
  const [isExecuting, setIsExecuting] = useState(false);
  const [ticketMessage, setTicketMessage] = useState<string | null>(null);
  const [pendingPositionKey, setPendingPositionKey] = useState<string | null>(null);
  const [managerChainBalance, setManagerChainBalance] = useState<bigint | null>(null);
  const [selectedOracleId, setSelectedOracleId] = useState(
    initialData.snapshot.meta?.selectedOracleId ??
      initialData.snapshot.expiries.find((expiry) => expiry.active)?.oracleId ??
      null,
  );
  const [selectedStrikeValue, setSelectedStrikeValue] = useState<number | null>(
    initialData.snapshot.meta?.selectedStrikeValue ??
      initialData.snapshot.strikes.find((strike) => strike.emphasis === "active")?.value ??
      null,
  );
  const syncedOwnerRef = useRef<string | null>(null);
  const baseUrl = data.source.predictServerUrl ?? publicConfig.predictServerUrl;
  const packageId = publicConfig.predictPackageId;

  const oracle = useOracle({
    oracleId: selectedOracleId,
    packageId,
    baseUrl,
    client,
  });

  const refreshTradeSnapshot = useCallback(
    async (override?: {
      ownerAddress?: string | null;
      oracleId?: string | null;
      strike?: number | null;
    }) => {
      const nextOwner = override?.ownerAddress ?? ownerAddress;
      const nextOracleId = override?.oracleId ?? selectedOracleId;
      const nextStrike = override?.strike ?? selectedStrikeValue;
      const params = new URLSearchParams();

      if (nextOwner) {
        params.set("owner", nextOwner);
      }
      if (nextOracleId) {
        params.set("oracle", nextOracleId);
      }
      if (typeof nextStrike === "number" && Number.isFinite(nextStrike)) {
        params.set("strike", String(nextStrike));
      }

      const search = params.size > 0 ? `?${params.toString()}` : "";
      const response = await fetch(`/api/trade${search}`, {
        cache: "no-store",
      });

      if (!response.ok) {
        throw new Error(`trade refresh failed with ${response.status}`);
      }

      const nextData = (await response.json()) as TradePageData;
      setData(nextData);
      setSelectedOracleId(nextData.snapshot.meta?.selectedOracleId ?? nextOracleId ?? null);
      setSelectedStrikeValue(
        nextData.snapshot.meta?.selectedStrikeValue ?? nextStrike ?? null,
      );
    },
    [ownerAddress, selectedOracleId, selectedStrikeValue],
  );

  useEffect(() => {
    if (data.source.mode !== "remote") {
      return;
    }

    if (syncedOwnerRef.current === ownerAddress) {
      return;
    }

    syncedOwnerRef.current = ownerAddress;
    void refreshTradeSnapshot({
      ownerAddress,
    }).catch((error: unknown) => {
      console.error(error);
    });
  }, [data.source.mode, ownerAddress, refreshTradeSnapshot]);

  useEffect(() => {
    const meta = data.snapshot.meta;

    if (
      !client ||
      !ownerAddress ||
      meta?.managerState !== "ready" ||
      !meta.managerId ||
      !meta.quoteAsset
    ) {
      setManagerChainBalance(null);
      return;
    }

    let cancelled = false;
    setManagerChainBalance(null);

    void readManagerQuoteBalance(client, {
      managerId: meta.managerId,
      coinType: meta.quoteAsset,
    })
      .then((balance) => {
        if (cancelled) {
          return;
        }

        setManagerChainBalance(balance);
      })
      .catch((error: unknown) => {
        if (cancelled) {
          return;
        }

        console.error(error);
        setManagerChainBalance(null);
      });

    return () => {
      cancelled = true;
    };
  }, [
    client,
    ownerAddress,
    data.snapshot.meta?.managerId,
    data.snapshot.meta?.managerState,
    data.snapshot.meta?.quoteAsset,
  ]);

  const handleSelectExpiry = (expiry: TradeExpiryItem) => {
    if (!expiry.oracleId || isExecuting) {
      return;
    }

    setTicketMessage(null);
    setSelectedOracleId(expiry.oracleId);
    // Reset strike when switching expiry; store picks up via hook re-run with new oracleId
    setSelectedStrikeValue(null);
  };

  const handleSelectStrike = (strike: TradeStrikeItem) => {
    if (typeof strike.value !== "number" || isExecuting) {
      return;
    }

    setTicketMessage(null);
    // Update local state; store picks up the change automatically
    setSelectedStrikeValue(strike.value);
  };

  const handleExecute = async () => {
    if (!account || !client || !dAppKit) {
      setTicketMessage("Connect wallet to trade.");
      return;
    }

    const meta = data.snapshot.meta;
    const quantity = parseUsdAmountInput(positionSizeValue);
    const oracleId = selectedOracleId ?? meta?.selectedOracleId;
    const strike = selectedStrikeValue ?? meta?.selectedStrikeValue;
    const expiryMs =
      data.snapshot.expiries.find((expiry) => expiry.oracleId === oracleId)?.expiryMs ??
      meta?.selectedExpiryMs;

    if (!meta?.canTrade || !meta?.managerId) {
      setTicketMessage(meta?.tradeBlockedReason ?? "Fund your PredictManager on Portfolio.");
      return;
    }

    if (!meta?.predictId || !meta.quoteAsset || !oracleId || !strike || quantity <= 0) {
      setTicketMessage("Trade context is incomplete.");
      return;
    }

    setIsExecuting(true);
    setTicketMessage("Submitting trade...");

    try {
      await signAndWaitForTransaction(
        dAppKit,
        client,
        buildMintPositionTransaction({
          packageId: publicConfig.predictPackageId,
          predictId: meta.predictId,
          managerId: meta.managerId,
          oracleId,
          quoteAsset: meta.quoteAsset,
          expiryMs: expiryMs ?? 0,
          strike,
          isUp: selectedSide === "UP",
          quantity,
        }),
      );

      setTicketMessage("Position opened.");
      await refreshTradeSnapshot();
    } catch (error) {
      setTicketMessage(formatActionError(error));
    } finally {
      setIsExecuting(false);
    }
  };

  const handlePositionAction = async (position: TradePositionRow) => {
    if (!account || !client || !dAppKit) {
      setTicketMessage("Connect wallet to manage positions.");
      return;
    }

    if (
      !data.snapshot.meta?.predictId ||
      !position.oracleId ||
      !position.quoteAsset ||
      !position.quantity ||
      typeof position.isUp !== "boolean" ||
      typeof position.strikeValue !== "number" ||
      typeof position.expiryMs !== "number"
    ) {
      setTicketMessage("Position context is incomplete.");
      return;
    }

    const meta = data.snapshot.meta;
    if (!meta?.predictId || !meta.managerId) {
      setTicketMessage("No connected manager was found.");
      return;
    }

    const nextPendingKey = positionKey(position);
    setPendingPositionKey(nextPendingKey);
    setTicketMessage(`${position.actionLabel ?? "Updating"} position...`);

    try {
      await signAndWaitForTransaction(
        dAppKit,
        client,
        buildRedeemPositionTransaction({
          packageId: publicConfig.predictPackageId,
          predictId: meta.predictId,
          managerId: meta.managerId,
          oracleId: position.oracleId,
          quoteAsset: position.quoteAsset,
          expiryMs: position.expiryMs,
          strike: position.strikeValue,
          isUp: position.isUp,
          quantity: position.quantity,
          settled: position.statusCode === "settled",
        }),
      );

      setTicketMessage(`${position.actionLabel ?? "Position"} completed.`);
      await refreshTradeSnapshot();
    } catch (error) {
      setTicketMessage(formatActionError(error));
    } finally {
      setPendingPositionKey(null);
    }
  };

  const syncBlockedReason =
    ownerAddress &&
    data.snapshot.meta?.managerState === "ready" &&
    (data.snapshot.meta?.tradingBalance ?? 0) <= 0 &&
    (managerChainBalance ?? 0n) > 0n
      ? "Deposit detected on-chain. Waiting for portfolio state to index."
      : null;

  return (
    <TradeShell
      snapshot={data.snapshot}
      oracleId={selectedOracleId}
      selectedOracleId={selectedOracleId}
      packageId={packageId}
      baseUrl={baseUrl}
      client={client}
      selectedStrikeValue={selectedStrikeValue}
      expiryMs={data.snapshot.meta?.selectedExpiryMs ?? 0}
      spotLabel={
        oracle.spot !== null
          ? `$${oracle.spot.toLocaleString("en-US", { maximumFractionDigits: 0 })}`
          : undefined
      }
      selectedSide={selectedSide}
      positionSizeValue={positionSizeValue}
      walletConnected={Boolean(account)}
      tradeEnabled={Boolean(data.snapshot.meta?.canTrade)}
      isExecuting={isExecuting}
      ticketMessage={
        ticketMessage ??
        (!account
          ? "Connect wallet to trade."
          : syncBlockedReason ?? data.snapshot.meta?.tradeBlockedReason ?? null)
      }
      portfolioLinkHref={
        account &&
        (data.snapshot.meta?.managerState === "missing" ||
          (data.snapshot.meta?.managerState === "ready" &&
            (data.snapshot.meta?.tradingBalance ?? 0) <= 0))
          ? "/portfolio"
          : null
      }
      portfolioLinkLabel="Fund on Portfolio"
      pendingPositionKey={pendingPositionKey}
      onSelectSide={setSelectedSide}
      onPositionSizeChange={setPositionSizeValue}
      onExecute={handleExecute}
      onSelectExpiry={handleSelectExpiry}
      onSelectStrike={handleSelectStrike}
      onPositionAction={handlePositionAction}
    />
  );
}
