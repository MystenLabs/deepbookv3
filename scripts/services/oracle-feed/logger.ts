import pino from "pino";
import type { LogEvent } from "./types";

export type LogFields = {
  event: LogEvent;
  tickId?: number;
  laneId?: number;
  oracleId?: string;
  txDigest?: string;
  [key: string]: unknown;
};

const rootLogger = pino({
  level: process.env.LOG_LEVEL ?? "info",
  formatters: {
    level: (label) => ({ level: label }),
  },
  timestamp: () => `,"time":${Date.now()}`,
});

export type Component =
  | "executor"
  | "subscriber"
  | "healthz"
  | "service";

export function makeLogger(component: Component) {
  const child = rootLogger.child({ component });
  return {
    debug: (fields: LogFields) => child.debug(fields),
    info: (fields: LogFields) => child.info(fields),
    warn: (fields: LogFields) => child.warn(fields),
    error: (fields: LogFields) => child.error(fields),
    fatal: (fields: LogFields) => child.fatal(fields),
  };
}

export type Logger = ReturnType<typeof makeLogger>;
