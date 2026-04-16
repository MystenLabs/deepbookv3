import { describe, it, expect } from "vitest";
import type { Intent, IntentQueue } from "../types";
import {
  newQueue,
  enqueue,
  peekNextPending,
  markInflight,
  finalizeSuccess,
  finalizeFailure,
} from "../intent-queue";

function makeIntent(oracleId: string): Intent {
  return { kind: "compact", oracleId, retries: 0 };
}

describe("IntentQueue", () => {
  it("enqueues in FIFO order", () => {
    const q = newQueue();
    enqueue(q, makeIntent("a"));
    enqueue(q, makeIntent("b"));
    expect(peekNextPending(q)?.oracleId).toBe("a");
  });

  it("settle_nudge jumps to the head", () => {
    const q = newQueue();
    enqueue(q, makeIntent("a"));
    enqueue(q, makeIntent("b"));
    enqueue(q, { kind: "settle_nudge", oracleId: "urgent", retries: 0 });
    const head = peekNextPending(q);
    expect(head?.kind).toBe("settle_nudge");
    expect(head?.oracleId).toBe("urgent");
  });

  it("markInflight removes from pending and records under digest", () => {
    const q = newQueue();
    enqueue(q, makeIntent("a"));
    const intents = [q.pending[0]];
    markInflight(q, "digest1", intents);
    expect(q.pending).toHaveLength(0);
    expect(q.inflight.get("digest1")).toEqual(intents);
  });

  it("finalizeSuccess clears inflight entry", () => {
    const q = newQueue();
    enqueue(q, makeIntent("a"));
    markInflight(q, "digest1", [q.pending[0]]);
    q.pending.shift(); // simulate what markInflight promised to do
    finalizeSuccess(q, "digest1");
    expect(q.inflight.has("digest1")).toBe(false);
  });

  it("finalizeFailure returns intents to pending head with incremented retries", () => {
    const q = newQueue();
    const i = makeIntent("a");
    q.inflight.set("digest1", [i]);
    finalizeFailure(q, "digest1", 5);
    expect(q.inflight.has("digest1")).toBe(false);
    expect(q.pending[0].retries).toBe(1);
  });

  it("finalizeFailure moves intent to deadLetter after max retries", () => {
    const q = newQueue();
    const i = { ...makeIntent("a"), retries: 5 };
    q.inflight.set("digest1", [i]);
    finalizeFailure(q, "digest1", 5);
    expect(q.pending).toHaveLength(0);
    expect(q.deadLetter).toHaveLength(1);
    expect(q.deadLetter[0].oracleId).toBe("a");
  });
});
