import { appendFileSync, writeFileSync, mkdirSync, existsSync } from "fs";
import path from "path";
import { LOGS_DIR, LOG_LEVEL } from "./config.js";
import type { LogLevel, LogEntry } from "./types.js";

const LEVEL_ORDER: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

export class Logger {
  private service: string;
  private logFile: string;
  private heartbeatFile: string;

  constructor(service: string) {
    this.service = service;
    if (!existsSync(LOGS_DIR)) mkdirSync(LOGS_DIR, { recursive: true });
    this.logFile = path.join(LOGS_DIR, `${service}.jsonl`);
    this.heartbeatFile = path.join(LOGS_DIR, `${service}.heartbeat`);
  }

  private shouldLog(level: LogLevel): boolean {
    return LEVEL_ORDER[level] >= LEVEL_ORDER[LOG_LEVEL];
  }

  private write(level: LogLevel, msg: string, meta?: Record<string, unknown>) {
    if (!this.shouldLog(level)) return;
    const entry: LogEntry = {
      ts: new Date().toISOString(),
      level,
      service: this.service,
      msg,
      ...(meta ? { meta } : {}),
    };
    const line = JSON.stringify(entry) + "\n";
    appendFileSync(this.logFile, line);
    // Also write to console for visibility
    if (level === "error") {
      console.error(`[${this.service}] ${level}: ${msg}`, meta ?? "");
    } else if (level === "warn") {
      console.warn(`[${this.service}] ${level}: ${msg}`, meta ?? "");
    } else {
      console.log(`[${this.service}] ${level}: ${msg}`, meta ? JSON.stringify(meta) : "");
    }
  }

  debug(msg: string, meta?: Record<string, unknown>) { this.write("debug", msg, meta); }
  info(msg: string, meta?: Record<string, unknown>) { this.write("info", msg, meta); }
  warn(msg: string, meta?: Record<string, unknown>) { this.write("warn", msg, meta); }
  error(msg: string, meta?: Record<string, unknown>) { this.write("error", msg, meta); }

  heartbeat() {
    writeFileSync(this.heartbeatFile, new Date().toISOString());
  }
}
