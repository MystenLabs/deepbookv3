// Pure readers for the delayed-execution queue events a harness transaction emits. Kept free
// of runtime imports so the unit tests can exercise them without a localnet environment.
//
// The queue events are declared in `deepbook_predict_orders::queue_events`, and a fill also emits
// Predict's `OrderMinted` or `LiveOrderRedeemed`. Events are matched by module and name, never
// by the package a transaction called.

export interface QueueEvent {
  type?: string;
  parsedJson?: any;
}

const named = (events: QueueEvent[] | undefined, name: string): QueueEvent[] =>
  (events ?? []).filter((event) => event.type?.endsWith(`::queue_events::${name}`));

// The record a successful enqueue created, with the τ and fixed-rate channel its cohort waits
// on. The fill price must be stamped exactly τ on that channel.
export function enqueuedOrder(
  events: QueueEvent[] | undefined,
): { recordId: bigint; tauMs: bigint; channel: number } {
  const [event] = named(events, "OrderEnqueued");
  if (!event) throw new Error("enqueue emitted no OrderEnqueued event");
  const json = event.parsedJson;
  return {
    recordId: BigInt(json.record_id),
    tauMs: BigInt(json.timing.tau_ms),
    channel: Number(json.timing.pyth_channel),
  };
}

export type QueueOutcome =
  | { status: "filled"; quantity: bigint; amount: bigint; remainingQuantity: bigint }
  | { status: "refunded"; reason: number; positionReturned: boolean }
  | { status: "waiting" };

// What a commit+resolve transaction did to one record. A fill reports the filled (mint) or
// closed (sell) quantity and the quantity the record now holds; a refund reports its
// `order_queue` reason code. A record the transaction did not finish is still waiting.
export function recordOutcome(events: QueueEvent[] | undefined, recordId: bigint): QueueOutcome {
  const matches = (event: QueueEvent) => BigInt(event.parsedJson.record_id) === recordId;
  const filled = named(events, "QueuedOrderFilled").find(matches);
  if (filled) {
    const json = filled.parsedJson;
    return {
      status: "filled",
      quantity: BigInt(json.quantity),
      amount: BigInt(json.amount),
      remainingQuantity: positionQuantity(json.position),
    };
  }
  const refunded = named(events, "QueuedOrderRefunded").find(matches);
  if (refunded) {
    return {
      status: "refunded",
      reason: Number(refunded.parsedJson.reason),
      positionReturned: Boolean(refunded.parsedJson.position_returned),
    };
  }
  return { status: "waiting" };
}

// Where a trader's position is after an early sell of it. `enqueue_redeem_open` closes the
// source record and moves the whole position into the new sell record, so the sell record is
// the only one that can hold it afterwards:
// - a fill closing all of it leaves nothing to track;
// - a partial fill leaves the remainder in the sell record, now Open;
// - a refund reopens the sell record with the whole position;
// - a sell still waiting holds the position until a later resolve fills or refunds it.
// Tracking the closed source record instead would make the next sell abort `ERecordNotOpen`.
export function heldAfterSell<Held extends { recordId: bigint; quantity: bigint }>(
  held: Held,
  sellRecordId: bigint,
  outcome: QueueOutcome,
): Held | null {
  if (outcome.status === "filled") {
    return outcome.remainingQuantity > 0n
      ? { ...held, recordId: sellRecordId, quantity: outcome.remainingQuantity }
      : null;
  }
  return { ...held, recordId: sellRecordId };
}

// `order.move` packs the quantity into the order id as a 32-bit lot count at bit 100.
const QUANTITY_LOTS_OFFSET = 100n;
const U32_MASK = (1n << 32n) - 1n;
const POSITION_LOT_SIZE = 10_000n;

export function orderQuantity(orderId: bigint): bigint {
  return ((orderId >> QUANTITY_LOTS_OFFSET) & U32_MASK) * POSITION_LOT_SIZE;
}

// The quantity a record holds after a fill; its `HeldPosition` is zero after a full close.
function positionQuantity(position: any): bigint {
  return orderQuantity(BigInt(position?.order_id ?? 0));
}

// Whether a `try_settle` transaction settled the market: Predict emits `MarketSettled` once,
// from the call that records the price. A call without it found no observation at expiry yet.
export function marketSettledIn(events: QueueEvent[] | undefined): boolean {
  return (events ?? []).some((event) => event.type?.endsWith("::config_events::MarketSettled"));
}
