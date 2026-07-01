// Per-actor JSONL run trace. Each actor (keeper, each trader) appends one line per op to
// its own file under INSTANCE_DIR/trace/, so concurrent writers never interleave. The
// `analyze` command reads them all to compute gas-vs-moneyness, op counts, the pool-NAV
// trend, and the bug oracle (aborts not from our packages).
import { appendFileSync, mkdirSync } from "node:fs";

const TRACE_DIR = `${process.env.INSTANCE_DIR ?? "."}/trace`;
let dirReady = false;
let warnedTraceFail = false;

export function appendTrace(actor: string, record: Record<string, unknown>): void {
  if (!dirReady) {
    try { mkdirSync(TRACE_DIR, { recursive: true }); } catch { /* exists */ }
    dirReady = true;
  }
  try {
    appendFileSync(`${TRACE_DIR}/${actor}.jsonl`, `${JSON.stringify({ ts: Date.now(), ...record })}\n`);
  } catch (e) {
    // Best-effort (never fail the op), but warn ONCE so dropped fail/crash records aren't silent.
    if (!warnedTraceFail) {
      warnedTraceFail = true;
      console.error(`[trace] WARN appendTrace failed; records may be lost: ${String(e).slice(0, 100)}`);
    }
  }
}

// Net gas (computation + storage - rebate) from a tx result's effects.
export function gasOf(result: any): number {
  const g = result?.effects?.gasUsed;
  if (!g) return 0;
  return Number(g.computationCost) + Number(g.storageCost) - Number(g.storageRebate);
}

// Just the computation cost (MIST). The Sui per-tx COMPUTATION cap (max_gas_computation_bucket =
// 5M units x RGP) is on THIS, not net gas — nav-stress measures the flush against it (analyze.py).
export function computationOf(result: any): number {
  return Number(result?.effects?.gasUsed?.computationCost ?? 0);
}

// Parse the aborting module + code from a Move error; null if it is not a MoveAbort
// (e.g. an arithmetic/VM error or an RPC failure — which the bug oracle flags hardest).
export function abortInfo(err: unknown): { module: string; code: number } | null {
  const s = err instanceof Error ? err.message : String(err);
  // Handle both raw (`Identifier("x")`) and JSON-escaped (`Identifier(\"x\")`) forms.
  const m = s.match(/Identifier\(\\?"([A-Za-z0-9_]+)\\?"\)[\s\S]*?\}, (\d+)\)/);
  return m ? { module: m[1], code: Number(m[2]) } : null;
}

// Short error tag for a failure trace: the abort "module:code", or a trimmed raw error.
export function errorTag(err: unknown): string {
  const a = abortInfo(err);
  if (a) return `${a.module}:${a.code}`;
  const s = err instanceof Error ? err.message : String(err);
  return s.slice(0, 120);
}
