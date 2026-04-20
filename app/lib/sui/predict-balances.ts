import type { SuiGrpcClient } from "@mysten/sui/grpc";

import { typeTagSymbol } from "@/lib/formatters";

type PredictBalanceClient = Pick<
  SuiGrpcClient,
  "getBalance" | "getCoinMetadata" | "getObject" | "listDynamicFields"
>;

type QuoteAssetMetadata = {
  decimals: number;
  symbol: string;
};

type ManagerObjectJson = {
  balance_manager?: {
    balances?: {
      id?: {
        id?: string;
      };
    };
  };
};

const USD_LIKE_SYMBOL_PATTERN = /usd/i;

function unwrapFields<T>(value: T): T {
  let current: unknown = value;

  while (current && typeof current === "object" && "fields" in current) {
    current = (current as { fields?: unknown }).fields;
  }

  return current as T;
}

function balanceTypeTag(coinType: string) {
  return `0x2::balance::Balance<${coinType}>`;
}

function readManagerBalanceBagId(json: unknown) {
  const managerJson = unwrapFields(json) as ManagerObjectJson | null | undefined;
  const balanceManager = unwrapFields(managerJson?.balance_manager);
  const balances = unwrapFields(balanceManager?.balances);
  const id = unwrapFields(balances?.id);

  return typeof id?.id === "string" ? id.id : null;
}

function readLittleEndianU64(bytes: Uint8Array) {
  let value = 0n;

  for (let index = 0; index < bytes.length && index < 8; index += 1) {
    value |= BigInt(bytes[index] ?? 0) << BigInt(index * 8);
  }

  return value;
}

function formatWholeNumber(value: bigint) {
  const text = value.toString();

  return text.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function toRoundedCents(value: bigint, decimals: number) {
  if (decimals <= 0) {
    return value * 100n;
  }

  if (decimals === 1) {
    return value * 10n;
  }

  const scale = 10n ** BigInt(decimals - 2);
  return (value + scale / 2n) / scale;
}

function formatCents(cents: bigint) {
  const negative = cents < 0n;
  const absolute = negative ? -cents : cents;
  const whole = absolute / 100n;
  const fraction = (absolute % 100n).toString().padStart(2, "0");

  return `${negative ? "-" : ""}${formatWholeNumber(whole)}.${fraction}`;
}

export async function readWalletQuoteBalance(
  client: Pick<PredictBalanceClient, "getBalance">,
  params: {
    owner: string;
    coinType: string;
  },
) {
  const response = await client.getBalance({
    owner: params.owner,
    coinType: params.coinType,
  });

  return response.balance?.balance ? BigInt(response.balance.balance) : 0n;
}

export async function readQuoteAssetMetadata(
  client: Pick<PredictBalanceClient, "getCoinMetadata">,
  coinType: string,
): Promise<QuoteAssetMetadata> {
  const response = await client.getCoinMetadata({ coinType });
  const metadata = response.coinMetadata;

  return {
    decimals: metadata?.decimals ?? 0,
    symbol: metadata?.symbol || typeTagSymbol(coinType),
  };
}

export function formatQuoteBalance(
  balance: bigint | null | undefined,
  metadata: QuoteAssetMetadata,
) {
  if (balance === null || balance === undefined) {
    return "—";
  }

  const roundedCents = toRoundedCents(balance, metadata.decimals);
  const formatted = formatCents(roundedCents);

  if (USD_LIKE_SYMBOL_PATTERN.test(metadata.symbol)) {
    return `$${formatted}`;
  }

  return `${formatted} ${metadata.symbol}`;
}

export async function readManagerQuoteBalance(
  client: Pick<PredictBalanceClient, "getObject" | "listDynamicFields">,
  params: {
    managerId: string;
    coinType: string;
  },
) {
  const managerResponse = await client.getObject({
    objectId: params.managerId,
    include: {
      json: true,
    },
  });

  const bagId = readManagerBalanceBagId(managerResponse.object.json);
  if (!bagId) {
    return 0n;
  }

  const balanceType = balanceTypeTag(params.coinType);
  const fields = await client.listDynamicFields({
    parentId: bagId,
    include: {
      value: true,
    },
  });

  const match = fields.dynamicFields.find((field) => field.valueType === balanceType);
  const balanceBytes = match?.value?.bcs;

  if (!balanceBytes) {
    return 0n;
  }

  return readLittleEndianU64(balanceBytes);
}
