import type { Config } from "./config";
import type { Logger } from "./logger";
import type { ServiceState, Tier } from "./types";
import { enqueue } from "./intent-queue";
import { expectedExpirySet } from "./expiry";

export type RotationManager = {
  start: () => void;
  stop: () => void;
  runOnce: () => void;
};

export function makeRotationManager(
  state: ServiceState,
  config: Config,
  log: Logger,
): RotationManager {
  let timer: ReturnType<typeof setInterval> | null = null;

  function runOnce(): void {
    const now = Date.now();
    const expected = expectedExpirySet(config.tiersEnabled, now);

    for (const tier of config.tiersEnabled) {
      const wantList = expected.get(tier) ?? [];
      const haveMap = state.registry.byExpiry.get(tier) ?? new Map();

      for (const expiryMs of wantList) {
        if (haveMap.has(expiryMs)) continue;
        const alreadyQueued = state.intents.pending.some(
          (i) => i.kind === "create_oracle" && i.tier === tier && i.expiryMs === expiryMs,
        );
        const alreadyInflight = [...state.intents.inflight.values()].flat().some(
          (i) => i.kind === "create_oracle" && i.tier === tier && i.expiryMs === expiryMs,
        );
        if (alreadyQueued || alreadyInflight) continue;

        enqueue(state.intents, { kind: "create_oracle", tier, expiryMs, retries: 0 });
        log.info({ event: "rotation_scheduled", tier, expiryMs });
      }
    }
  }

  return {
    start: () => {
      runOnce();
      timer = setInterval(runOnce, config.rotationTickMs);
    },
    stop: () => {
      if (timer) clearInterval(timer);
      timer = null;
    },
    runOnce,
  };
}
