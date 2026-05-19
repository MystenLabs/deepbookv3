import {
  RESULTS_PATH,
  RESULTS_SCHEMA_VERSION,
  STATE_PATH,
  type ActionName,
  type ActionSummary,
  type ExecutionResult,
  type RejectedMintResult,
  type ResultsFile,
  type ScenarioRow,
  type SimState,
  loadScenario,
  readJson,
  ts,
  validateSimState,
  writeJson,
} from "./shared.js";
import {
  address,
  POOL_VAULT_ID,
  PROTOCOL_CONFIG_ID,
  createManagerTx,
  createExpiryMarketTx,
  createMarketOracleCapTx,
  createPythSourceTx,
  depositToManagerTx,
  deriveManagerId,
  execute,
  executeAndWait,
  finalizeDusdcCurrencyRegistrationTx,
  mintTx,
  refreshOracleAndMintTx,
  setMarketOracleBasisBoundsTx,
  supplyTx,
  supplyWithExpiryValuationTx,
  updateBlockScholesPricesTx,
  updateSviTx,
} from "./runtime.js";

const DUSDC_DECIMALS = 1_000_000n;
const EXPIRY_MS = BigInt(Date.now()) + 7n * 24n * 60n * 60n * 1000n;
const FLOAT_SCALING = 1_000_000_000n;
// Must satisfy the on-chain invariant:
// max_strike - min_strike == tick_size * 100_000
const ORACLE_MIN_STRIKE = 25_000n * FLOAT_SCALING;
const ORACLE_TICK_SIZE = 1n * FLOAT_SCALING;
const ORACLE_MAX_STRIKE = ORACLE_MIN_STRIKE + 100_000n * ORACLE_TICK_SIZE;
const NAV_SUPPLY_INTERVAL = 100;
const NAV_SUPPLY_AMOUNT = 1n * DUSDC_DECIMALS;

type MintRow = Extract<ScenarioRow, { action: "mint" }>;

function alignStrikeToGrid(strike: bigint): bigint {
  const relative = strike - ORACLE_MIN_STRIKE;
  const tickIndex = relative / ORACLE_TICK_SIZE;
  const snapped = ORACLE_MIN_STRIKE + tickIndex * ORACLE_TICK_SIZE;
  if (snapped < ORACLE_MIN_STRIKE) return ORACLE_MIN_STRIKE;
  if (snapped > ORACLE_MAX_STRIKE) return ORACLE_MAX_STRIKE;
  return snapped;
}

function parseArgs() {
  let maxRows: number | undefined;
  const maxRowsIdx = process.argv.indexOf("--max-rows");
  if (maxRowsIdx !== -1 && process.argv[maxRowsIdx + 1]) {
    maxRows = parseInt(process.argv[maxRowsIdx + 1], 10);
  }
  return {
    setupOnly: process.argv.includes("--setup-only"),
    executeOnly: process.argv.includes("--execute-only"),
    continueOnRejects: process.argv.includes("--continue-on-rejects"),
    maxRows,
  };
}

function summarizeRows(rows: ExecutionResult[]): ActionSummary {
  return {
    count: rows.length,
    gas: {
      avg: rows.reduce((sum, row) => sum + row.gasTotal, 0) / rows.length,
      min: Math.min(...rows.map((row) => row.gasTotal)),
      max: Math.max(...rows.map((row) => row.gasTotal)),
    },
    wallMs: {
      avg: rows.reduce((sum, row) => sum + row.wallMs, 0) / rows.length,
      min: Math.min(...rows.map((row) => row.wallMs)),
      max: Math.max(...rows.map((row) => row.wallMs)),
    },
  };
}

function buildResultsFile(
  byAction: Record<ActionName, ExecutionResult[]>,
  rejectedMints: RejectedMintResult[],
  targetMints: number,
  attemptedMints: number
): ResultsFile {
  const summaryByAction: ResultsFile["summary"]["byAction"] = {};

  for (const action of ["update_prices", "update_svi", "mint", "supply"] as const) {
    if (byAction[action].length > 0) {
      summaryByAction[action] = summarizeRows(byAction[action]);
    }
  }

  return {
    schema_version: RESULTS_SCHEMA_VERSION,
    summary: {
      totalTxs: byAction.update_prices.length + byAction.update_svi.length + byAction.mint.length + byAction.supply.length,
      attemptedMints,
      successfulMints: byAction.mint.length,
      rejectedMints: rejectedMints.length,
      targetMints,
      byAction: summaryByAction,
    },
    mints: byAction.mint,
    supplies: byAction.supply,
    rejectedMints,
  };
}

async function recordNavSupplyCheckpoint(
  byAction: Record<ActionName, ExecutionResult[]>,
  state: SimState,
  targetMints: number
): Promise<void> {
  const successfulMints = byAction.mint.length;
  if (successfulMints === 0 || successfulMints % NAV_SUPPLY_INTERVAL !== 0) return;

  const startedAt = performance.now();
  const gas = await execute(
    () => supplyWithExpiryValuationTx({
      poolVaultId: state.poolVaultId,
      protocolConfigId: state.protocolConfigId,
      expiryMarketId: state.expiryMarketId,
      oracleId: state.oracleId,
      pythSourceId: state.pythSourceId,
      amount: NAV_SUPPLY_AMOUNT,
    }),
    "supply"
  );
  const wallMs = performance.now() - startedAt;
  byAction.supply.push({ wallMs, ...gas });

  process.stdout.write(`[${ts()}]   [NAV ${successfulMints}/${targetMints}] supply ${wallMs.toFixed(0)}ms\n`);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function direction(row: MintRow): "UP" | "DN" {
  return row.isUp ? "UP" : "DN";
}

function scaledUsd(value: bigint): string {
  return (Number(value) / 1e9).toFixed(0);
}

function mintContext(
  row: MintRow,
  alignedStrike: bigint,
  attemptedMintIndex: number,
  targetMints: number
): string {
  return `mint ${attemptedMintIndex}/${targetMints} csv_line=${row.lineNumber} ${direction(row)} strike=$${scaledUsd(alignedStrike)} quantity=${row.quantity}`;
}

function rejectedMintResult(
  row: MintRow,
  alignedStrike: bigint,
  attemptedMintIndex: number,
  wallMs: number,
  error: unknown
): RejectedMintResult {
  return {
    attemptedMintIndex,
    csvLine: row.lineNumber,
    direction: direction(row),
    strike: row.strike.toString(),
    alignedStrike: alignedStrike.toString(),
    quantity: row.quantity.toString(),
    wallMs,
    error: errorMessage(error),
  };
}

async function setupSimulation(): Promise<SimState> {
  console.log(`[${ts()}] --- Setup ---`);

  let result = await executeAndWait(
    finalizeDusdcCurrencyRegistrationTx(),
    "finalize_dusdc_currency_registration"
  );
  const dusdcCurrencyChange = result.objectChanges.find(
    (change: any) =>
      change.type === "created" &&
      change.objectType.includes("coin_registry::Currency") &&
      change.objectType.includes("dusdc::DUSDC")
  );
  const dusdcCurrencyId: string = dusdcCurrencyChange.objectId;
  console.log(`[${ts()}]   DUSDC Currency: ${dusdcCurrencyId}`);

  const poolVaultId = POOL_VAULT_ID;
  const protocolConfigId = PROTOCOL_CONFIG_ID;
  console.log(`[${ts()}]   PoolVault: ${poolVaultId}`);
  console.log(`[${ts()}]   ProtocolConfig: ${protocolConfigId}`);

  result = await executeAndWait(createMarketOracleCapTx(address), "create_market_oracle_cap");
  const oracleCapChange = result.objectChanges.find(
    (change: any) => change.type === "created" && change.objectType.includes("MarketOracleCap")
  );
  const oracleCapId: string = oracleCapChange.objectId;
  console.log(`[${ts()}]   OracleCap: ${oracleCapId}`);

  result = await executeAndWait(createPythSourceTx(1), "create_pyth_source");
  const pythSourceChange = result.objectChanges.find(
    (change: any) => change.type === "created" && change.objectType.includes("PythSource")
  );
  const pythSourceId: string = pythSourceChange.objectId;
  console.log(`[${ts()}]   PythSource: ${pythSourceId}`);

  const vaultSeed = 500_000n * DUSDC_DECIMALS;
  await executeAndWait(supplyTx(poolVaultId, protocolConfigId, vaultSeed), "supply");
  console.log(`[${ts()}]   Vault funded: ${vaultSeed / DUSDC_DECIMALS} DUSDC`);

  result = await executeAndWait(
    createExpiryMarketTx({
      poolVaultId,
      protocolConfigId,
      pythSourceId,
      oracleCapId,
      expiry: EXPIRY_MS,
      minStrike: ORACLE_MIN_STRIKE,
      tickSize: ORACLE_TICK_SIZE,
    }),
    "create_expiry_market",
    50_000_000_000n
  );
  const oracleChange = result.objectChanges.find(
    (change: any) => change.type === "created" && change.objectType.includes("MarketOracle") && !change.objectType.includes("Cap")
  );
  const oracleId: string = oracleChange.objectId;
  const expiryMarketChange = result.objectChanges.find(
    (change: any) => change.type === "created" && change.objectType.includes("ExpiryMarket")
  );
  const expiryMarketId: string = expiryMarketChange.objectId;
  console.log(`[${ts()}]   ExpiryMarket: ${expiryMarketId}`);
  console.log(`[${ts()}]   Oracle: ${oracleId}`);

  // Scenario CSV has historical spot moves up to ~8% between consecutive
  // update_prices rows. Default per-push bounds (2%) would trip the circuit
  // breaker; widen to the admin ceiling (10%) so the sim replays the trace.
  await executeAndWait(
    setMarketOracleBasisBoundsTx(
      oracleId,
      protocolConfigId,
      oracleCapId,
      100_000_000n,
      100_000_000n,
      900_000_000n,
      1_100_000_000n
    ),
    "set_basis_bounds"
  );
  console.log(`[${ts()}]   Basis bounds widened for oracle`);

  const managerId = deriveManagerId(address);
  await executeAndWait(createManagerTx(), "create_manager");
  console.log(`[${ts()}]   Manager: ${managerId}`);

  const userFunds = 500_000n * DUSDC_DECIMALS;
  await executeAndWait(depositToManagerTx(managerId, userFunds), "deposit_to_manager");
  console.log(`[${ts()}]   Manager funded: ${userFunds / DUSDC_DECIMALS} DUSDC`);

  const state: SimState = {
    poolVaultId,
    protocolConfigId,
    expiryMarketId,
    pythSourceId,
    oracleId,
    oracleCapId,
    managerId,
  };

  writeJson(STATE_PATH, state);
  console.log(`[${ts()}]   State saved to ${STATE_PATH}`);

  return state;
}

async function executeScenario(
  rows: ScenarioRow[],
  state: SimState,
  continueOnRejects: boolean
): Promise<void> {
  const mintRows = rows.filter((row): row is MintRow => row.action === "mint");

  console.log(`\n[${ts()}] Loaded ${rows.length} rows (${mintRows.length} mints)`);
  if (continueOnRejects) {
    console.log(`[${ts()}] Continue-on-rejects enabled; run still requires ${mintRows.length} successful mints`);
  }
  console.log(`[${ts()}] --- Executing ${rows.length} actions ---\n`);

  const byAction: Record<ActionName, ExecutionResult[]> = {
    update_prices: [],
    update_svi: [],
    mint: [],
    supply: [],
  };
  const rejectedMints: RejectedMintResult[] = [];
  let attemptedMintIndex = 0;
  let i = 0;
  while (i < rows.length) {
    const row = rows[i];
    const startedAt = performance.now();

    const nextRow = i + 1 < rows.length ? rows[i + 1] : null;
    const nextNextRow = i + 2 < rows.length ? rows[i + 2] : null;
    if (
      row.action === "update_prices" &&
      nextRow?.action === "update_svi" &&
      nextNextRow?.action === "mint"
    ) {
      attemptedMintIndex++;
      const alignedStrike = alignStrikeToGrid(nextNextRow.strike);
      let mintSucceeded = false;
      try {
        const gas = await execute(
          () => refreshOracleAndMintTx({
            expiryMarketId: state.expiryMarketId,
            protocolConfigId: state.protocolConfigId,
            managerId: state.managerId,
            oracleId: state.oracleId,
            oracleCapId: state.oracleCapId,
            pythSourceId: state.pythSourceId,
            strike: alignedStrike,
            isUp: nextNextRow.isUp,
            quantity: nextNextRow.quantity,
            spot: row.spot,
            forward: row.forward,
            svi: {
              a: nextRow.a,
              b: nextRow.b,
              rho: nextRow.rho,
              rhoNegative: nextRow.rhoNegative,
              m: nextRow.m,
              mNegative: nextRow.mNegative,
              sigma: nextRow.sigma,
            },
          }),
          "refresh_oracle_and_mint"
        );

        const wallMs = performance.now() - startedAt;
        byAction.mint.push({ wallMs, ...gas });

        process.stdout.write(`[${ts()}]   [${byAction.mint.length}/${mintRows.length}] ${direction(nextNextRow)} $${scaledUsd(alignedStrike)} ${wallMs.toFixed(0)}ms\n`);
        mintSucceeded = true;
      } catch (error) {
        const wallMs = performance.now() - startedAt;
        if (!continueOnRejects) {
          throw new Error(`${mintContext(nextNextRow, alignedStrike, attemptedMintIndex, mintRows.length)} failed: ${errorMessage(error)}`);
        }
        rejectedMints.push(rejectedMintResult(nextNextRow, alignedStrike, attemptedMintIndex, wallMs, error));
        process.stdout.write(`[${ts()}]   [reject ${attemptedMintIndex}/${mintRows.length}] ${direction(nextNextRow)} $${scaledUsd(alignedStrike)} ${wallMs.toFixed(0)}ms ${errorMessage(error)}\n`);
      }
      if (mintSucceeded) {
        await recordNavSupplyCheckpoint(byAction, state, mintRows.length);
      }
      i += 3;
      continue;
    }

    if (row.action === "update_prices") {
      const gas = await execute(
        () => updateBlockScholesPricesTx(
          state.oracleId,
          state.protocolConfigId,
          state.pythSourceId,
          state.oracleCapId,
          row.spot,
          row.forward
        ),
        "update_prices"
      );
      byAction.update_prices.push({ wallMs: performance.now() - startedAt, ...gas });
      i++;
      continue;
    }

    if (row.action === "update_svi") {
      const gas = await execute(
        () => updateSviTx(
          state.oracleId,
          state.protocolConfigId,
          state.oracleCapId,
          {
            a: row.a,
            b: row.b,
            rho: row.rho,
            rhoNegative: row.rhoNegative,
            m: row.m,
            mNegative: row.mNegative,
            sigma: row.sigma,
          }
        ),
        "update_svi"
      );
      byAction.update_svi.push({ wallMs: performance.now() - startedAt, ...gas });
      i++;
      continue;
    }

    attemptedMintIndex++;
    const alignedStrike = alignStrikeToGrid(row.strike);
    let mintSucceeded = false;
    try {
      const gas = await execute(
        () => mintTx({
          expiryMarketId: state.expiryMarketId,
          protocolConfigId: state.protocolConfigId,
          managerId: state.managerId,
          oracleId: state.oracleId,
          pythSourceId: state.pythSourceId,
          strike: alignedStrike,
          isUp: row.isUp,
          quantity: row.quantity,
        }),
        "mint"
      );

      const wallMs = performance.now() - startedAt;
      byAction.mint.push({ wallMs, ...gas });

      process.stdout.write(`[${ts()}]   [${byAction.mint.length}/${mintRows.length}] ${direction(row)} $${scaledUsd(alignedStrike)} ${wallMs.toFixed(0)}ms\n`);
      mintSucceeded = true;
    } catch (error) {
      const wallMs = performance.now() - startedAt;
      if (!continueOnRejects) {
        throw new Error(`${mintContext(row, alignedStrike, attemptedMintIndex, mintRows.length)} failed: ${errorMessage(error)}`);
      }
      rejectedMints.push(rejectedMintResult(row, alignedStrike, attemptedMintIndex, wallMs, error));
      process.stdout.write(`[${ts()}]   [reject ${attemptedMintIndex}/${mintRows.length}] ${direction(row)} $${scaledUsd(alignedStrike)} ${wallMs.toFixed(0)}ms ${errorMessage(error)}\n`);
    }
    if (mintSucceeded) {
      await recordNavSupplyCheckpoint(byAction, state, mintRows.length);
    }
    i++;
  }

  const results = buildResultsFile(byAction, rejectedMints, mintRows.length, attemptedMintIndex);
  writeJson(RESULTS_PATH, results);

  const mintSummary = results.summary.byAction.mint;
  console.log(`\n[${ts()}] --- Done ---`);
  console.log(`[${ts()}]   ${results.summary.totalTxs} txs, ${results.mints.length}/${mintRows.length} successful mints`);
  if (rejectedMints.length > 0) {
    console.log(`[${ts()}]   ${rejectedMints.length} rejected mints recorded`);
  }
  if (mintSummary) {
    console.log(
      `[${ts()}]   Avg mint: ${mintSummary.wallMs.avg.toFixed(0)}ms, avg gas: ${(mintSummary.gas.avg / 1e9).toFixed(6)} SUI`
    );
  }
  const supplySummary = results.summary.byAction.supply;
  if (supplySummary) {
    console.log(
      `[${ts()}]   Avg NAV supply: ${supplySummary.wallMs.avg.toFixed(0)}ms, avg gas: ${(supplySummary.gas.avg / 1e9).toFixed(6)} SUI`
    );
  }
  console.log(`[${ts()}]   Results saved to ${RESULTS_PATH}`);

  if (byAction.mint.length !== mintRows.length) {
    throw new Error(`Simulation produced ${byAction.mint.length}/${mintRows.length} successful mints; see rejectedMints in ${RESULTS_PATH}`);
  }
}

async function main() {
  const args = parseArgs();
  let rows = loadScenario();
  if (args.maxRows !== undefined) {
    console.log(`[${ts()}] Limiting to ${args.maxRows} rows`);
    rows = rows.slice(0, args.maxRows);
  }

  if (args.executeOnly) {
    const state = validateSimState(readJson<SimState>(STATE_PATH));
    await executeScenario(rows, state, args.continueOnRejects);
    return;
  }

  const state = await setupSimulation();

  if (args.setupOnly) {
    console.log(`[${ts()}] Setup complete`);
    return;
  }

  await executeScenario(rows, state, args.continueOnRejects);
}

main().catch((error) => {
  console.error("Simulation failed:", error);
  process.exit(1);
});
