import { describe, expect, it } from "vitest";
import { evaluateHealth } from "../healthz";

const BASE = {
  now: 10_000_000,
  bootTs: 10_000_000 - 120_000,
  wsConnected: true,
  lastWsFrameAtMs: 10_000_000 - 1_000,
  lastPushMs: 10_000_000 - 2_000,
  managerInFlight: false,
  managerGraceMs: 60_000,
};

describe("evaluateHealth", () => {
  it("returns ok on a fresh push and connected ws", () => {
    expect(evaluateHealth(BASE)).toEqual({ ok: true });
  });

  it("flags ws_stale when the ws is disconnected and last frame is older than 60s", () => {
    const verdict = evaluateHealth({
      ...BASE,
      wsConnected: false,
      lastWsFrameAtMs: BASE.now - 61_000,
    });
    expect(verdict).toEqual({ ok: false, reason: "ws_stale" });
  });

  it("is still ok if ws is disconnected but a recent frame arrived", () => {
    expect(
      evaluateHealth({
        ...BASE,
        wsConnected: false,
        lastWsFrameAtMs: BASE.now - 30_000,
      }),
    ).toEqual({ ok: true });
  });

  it("flags push_stale when push is stale and manager is not in flight", () => {
    expect(
      evaluateHealth({
        ...BASE,
        lastPushMs: BASE.now - 20_000,
      }),
    ).toEqual({ ok: false, reason: "push_stale" });
  });

  it("stays ok when push is stale but manager is in flight within the grace window", () => {
    expect(
      evaluateHealth({
        ...BASE,
        lastPushMs: BASE.now - 30_000,
        managerInFlight: true,
        managerGraceMs: 60_000,
      }),
    ).toEqual({ ok: true });
  });

  it("flags push_stale when manager has been in flight past the grace window", () => {
    expect(
      evaluateHealth({
        ...BASE,
        lastPushMs: BASE.now - 120_000,
        managerInFlight: true,
        managerGraceMs: 60_000,
      }),
    ).toEqual({ ok: false, reason: "push_stale" });
  });

  it("uses the boot grace window when the service has never pushed", () => {
    const now = 10_000_000;
    expect(
      evaluateHealth({
        ...BASE,
        now,
        bootTs: now - 5_000,
        lastPushMs: 0,
      }),
    ).toEqual({ ok: true });
  });

  it("leaves the boot grace window eventually and requires a real push", () => {
    const now = 10_000_000;
    expect(
      evaluateHealth({
        ...BASE,
        now,
        bootTs: now - 120_000,
        lastPushMs: 0,
      }),
    ).toEqual({ ok: false, reason: "push_stale" });
  });
});
