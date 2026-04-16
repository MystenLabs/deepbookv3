import { describe, it, expect } from "vitest";
import { expectedExpiriesForTier, expectedExpirySet } from "../expiry";

const T = (iso: string) => Date.parse(iso);

describe("expectedExpiriesForTier", () => {
  it("15m: returns next 4 quarter-hours after now (strictly greater)", () => {
    const now = T("2026-04-16T14:07:30Z");
    const got = expectedExpiriesForTier("15m", now);
    expect(got).toEqual([
      T("2026-04-16T14:15:00Z"),
      T("2026-04-16T14:30:00Z"),
      T("2026-04-16T14:45:00Z"),
      T("2026-04-16T15:00:00Z"),
    ]);
  });

  it("15m: when now is exactly on a quarter-hour, next 4 start strictly after", () => {
    const now = T("2026-04-16T14:15:00Z");
    const got = expectedExpiriesForTier("15m", now);
    expect(got[0]).toBe(T("2026-04-16T14:30:00Z"));
    expect(got).toHaveLength(4);
  });

  it("1h: returns next 4 hour marks", () => {
    const now = T("2026-04-16T14:07:30Z");
    expect(expectedExpiriesForTier("1h", now)).toEqual([
      T("2026-04-16T15:00:00Z"),
      T("2026-04-16T16:00:00Z"),
      T("2026-04-16T17:00:00Z"),
      T("2026-04-16T18:00:00Z"),
    ]);
  });

  it("1d: returns next 4 days at 08:00 UTC", () => {
    const now = T("2026-04-16T14:07:30Z");
    expect(expectedExpiriesForTier("1d", now)).toEqual([
      T("2026-04-17T08:00:00Z"),
      T("2026-04-18T08:00:00Z"),
      T("2026-04-19T08:00:00Z"),
      T("2026-04-20T08:00:00Z"),
    ]);
  });

  it("1d: if now is before 08:00 UTC, still skips today", () => {
    const now = T("2026-04-16T06:00:00Z");
    expect(expectedExpiriesForTier("1d", now)[0]).toBe(T("2026-04-17T08:00:00Z"));
  });

  it("1w: returns next 4 Fridays at 08:00 UTC", () => {
    // 2026-04-16 is a Thursday; next Friday is 2026-04-17
    const now = T("2026-04-16T14:07:30Z");
    expect(expectedExpiriesForTier("1w", now)).toEqual([
      T("2026-04-17T08:00:00Z"),
      T("2026-04-24T08:00:00Z"),
      T("2026-05-01T08:00:00Z"),
      T("2026-05-08T08:00:00Z"),
    ]);
  });

  it("1w: if called on Friday before 08:00 UTC, today qualifies", () => {
    const now = T("2026-04-17T07:00:00Z");
    expect(expectedExpiriesForTier("1w", now)[0]).toBe(T("2026-04-17T08:00:00Z"));
  });

  it("1w: if called on Friday after 08:00 UTC, skip to next Friday", () => {
    const now = T("2026-04-17T09:00:00Z");
    expect(expectedExpiriesForTier("1w", now)[0]).toBe(T("2026-04-24T08:00:00Z"));
  });
});

describe("expectedExpirySet", () => {
  it("returns flat set across enabled tiers", () => {
    const now = T("2026-04-16T14:07:30Z");
    const set = expectedExpirySet(["1h", "1d"], now);
    expect(set.get("1h")).toHaveLength(4);
    expect(set.get("1d")).toHaveLength(4);
    expect(set.has("15m")).toBe(false);
  });
});
