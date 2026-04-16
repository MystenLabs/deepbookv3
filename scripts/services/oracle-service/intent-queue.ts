import type { Intent, IntentQueue } from "./types";

export function newQueue(): IntentQueue {
  return { pending: [], inflight: new Map(), deadLetter: [] };
}

export function enqueue(queue: IntentQueue, intent: Intent): void {
  if (intent.kind === "settle_nudge") {
    queue.pending.unshift(intent);
    return;
  }
  queue.pending.push(intent);
}

export function peekNextPending(queue: IntentQueue): Intent | undefined {
  return queue.pending[0];
}

export function markInflight(
  queue: IntentQueue,
  txDigest: string,
  intents: Intent[],
): void {
  // Caller is responsible for shifting intents out of pending before calling
  // this, since the set of intents included in a PTB may be a subset of what
  // was at the head (in the AdminCap-skip case).
  for (const i of intents) {
    const idx = queue.pending.indexOf(i);
    if (idx >= 0) queue.pending.splice(idx, 1);
  }
  queue.inflight.set(txDigest, intents);
}

export function finalizeSuccess(queue: IntentQueue, txDigest: string): Intent[] {
  const intents = queue.inflight.get(txDigest) ?? [];
  queue.inflight.delete(txDigest);
  return intents;
}

export function finalizeFailure(
  queue: IntentQueue,
  txDigest: string,
  maxRetries: number,
): Intent[] {
  const intents = queue.inflight.get(txDigest) ?? [];
  queue.inflight.delete(txDigest);
  const requeued: Intent[] = [];
  for (const i of intents) {
    const retries = i.retries + 1;
    if (retries > maxRetries) {
      queue.deadLetter.push({ ...i, retries });
    } else {
      const updated = { ...i, retries };
      queue.pending.unshift(updated);
      requeued.push(updated);
    }
  }
  return requeued;
}
