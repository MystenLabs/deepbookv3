import {
  RESULTS_PATH,
  RESULTS_SCHEMA_VERSION,
  STATE_PATH,
  type ActionName,
  type ActionSummary,
  type ExecutionResult,
  type ResultsFile,
  type ScenarioRow,
  type SimState,
  loadScenario,
  readJson,
  ts,
  writeJson,
} from "./shared.js";
import {
  activateOracleTx,
  address,
  createManagerTx,
  createOracleCapTx,
  createOracleTx,
  createPredictTx,
  depositToManagerTx,
  execute,
  executeAndWait,
  mintTx,
  refreshOracleAndMintTx,
  registerOracleCapTx,
  supplyTx,
  updatePricesTx,
  updateSviTx,
} from "./runtime.js";

const DUSDC_DECIMALS = 1_000_000n;
const EXPIRY_MS = BigInt(Date.now()) + 7n * 24n * 60n * 60n * 1000n;
const FLOAT_SCALING = 1_000_000_000n;
// Must satisfy the on-chain invariant:
// max_strike - min_strike == tick_size * 100_000
const ORACLE_MIN_STRIKE = 50_000n * FLOAT_SCALING;
const ORACLE_MAX_STRIKE = 150_000n * FLOAT_SCALING;
const ORACLE_TICK_SIZE = 1n * FLOAT_SCALING;

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

function buildResultsFile(byAction: Record<ActionName, ExecutionResult[]>): ResultsFile {
  const summaryByAction: ResultsFile["summary"]["byAction"] = {};

  for (const action of ["update_prices", "update_svi", "mint"] as const) {
    if (byAction[action].length > 0) {
      summaryByAction[action] = summarizeRows(byAction[action]);
    }
  }

  return {
    schema_version: RESULTS_SCHEMA_VERSION,
    summary: {
      totalTxs: byAction.update_prices.length + byAction.update_svi.length + byAction.mint.length,
      byAction: summaryByAction,
    },
    mints: byAction.mint,
  };
}

async function setupSimulation(): Promise<SimState> {
  console.log(`[${ts()}] --- Setup ---`);

  let result = await executeAndWait(createPredictTx(), "create_predict");
  const predictEvent = result.events.find((event: any) => event.type.includes("PredictCreated"));
  const predictId: string = predictEvent.parsedJson.predict_id;
  console.log(`[${ts()}]   Predict: ${predictId}`);

  result = await executeAndWait(createOracleCapTx(address), "create_oracle_cap");
  const oracleCapChange = result.objectChanges.find(
    (change: any) => change.type === "created" && change.objectType.includes("OracleCapSVI")
  );
  const oracleCapId: string = oracleCapChange.objectId;
  console.log(`[${ts()}]   OracleCap: ${oracleCapId}`);

  result = await executeAndWait(
    createOracleTx({
      predictId,
      oracleCapId,
      underlyingAsset: "BTC",
      expiry: EXPIRY_MS,
      minStrike: ORACLE_MIN_STRIKE,
      tickSize: ORACLE_TICK_SIZE,
    }),
    "create_oracle",
    // Simulation setup preallocates the full strike matrix at oracle creation,
    // so this admin-only setup transaction needs a much larger gas budget than
    // the measured mint path.
    50_000_000_000n
  );
  const oracleChange = result.objectChanges.find(
    (change: any) => change.type === "created" && change.objectType.includes("OracleSVI") && !change.objectType.includes("Cap")
  );
  const oracleId: string = oracleChange.objectId;
  console.log(`[${ts()}]   Oracle: ${oracleId}`);

  await executeAndWait(registerOracleCapTx(oracleId, oracleCapId), "register_oracle_cap");
  await executeAndWait(activateOracleTx(oracleId, oracleCapId), "activate_oracle");
  console.log(`[${ts()}]   Oracle activated`);

  const vaultSeed = 500_000n * DUSDC_DECIMALS;
  await executeAndWait(supplyTx(predictId, vaultSeed), "supply");
  console.log(`[${ts()}]   Vault funded: ${vaultSeed / DUSDC_DECIMALS} DUSDC`);

  result = await executeAndWait(createManagerTx(), "create_manager");
  const managerEvent = result.events.find((event: any) => event.type.includes("ManagerCreated"));
  const managerId: string = managerEvent.parsedJson.manager_id;
  console.log(`[${ts()}]   Manager: ${managerId}`);

  const userFunds = 500_000n * DUSDC_DECIMALS;
  await executeAndWait(depositToManagerTx(managerId, userFunds), "deposit_to_manager");
  console.log(`[${ts()}]   Manager funded: ${userFunds / DUSDC_DECIMALS} DUSDC`);

  const state: SimState = {
    predictId,
    oracleId,
    oracleCapId,
    managerId,
    expiry: String(EXPIRY_MS),
  };

  writeJson(STATE_PATH, state);
  console.log(`[${ts()}]   State saved to ${STATE_PATH}`);

  return state;
}

async function executeScenario(rows: ScenarioRow[], state: SimState): Promise<void> {
  const expiry = BigInt(state.expiry);
  const mintRows = rows.filter((row): row is Extract<ScenarioRow, { action: "mint" }> => row.action === "mint");

  console.log(`\n[${ts()}] Loaded ${rows.length} rows (${mintRows.length} mints)`);
  console.log(`[${ts()}] --- Executing ${rows.length} actions ---\n`);

  const byAction: Record<ActionName, ExecutionResult[]> = {
    update_prices: [],
    update_svi: [],
    mint: [],
  };
  let mintIndex = 0;
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
      mintIndex++;
      const alignedStrike = alignStrikeToGrid(nextNextRow.strike);
      const gas = await execute(
        refreshOracleAndMintTx({
          predictId: state.predictId,
          managerId: state.managerId,
          oracleId: state.oracleId,
          oracleCapId: state.oracleCapId,
          expiry,
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
          riskFreeRate: nextRow.riskFreeRate,
        }),
        "refresh_oracle_and_mint"
      );

      const wallMs = performance.now() - startedAt;
      byAction.mint.push({ wallMs, ...gas });

      const direction = nextNextRow.isUp ? "UP" : "DN";
      const strikeUsd = (Number(alignedStrike) / 1e9).toFixed(0);
      process.stdout.write(`[${ts()}]   [${mintIndex}/${mintRows.length}] ${direction} $${strikeUsd} ${wallMs.toFixed(0)}ms\n`);
      i += 3;
      continue;
    }

    if (row.action === "update_prices") {
      const gas = await execute(
        () => updatePricesTx(state.oracleId, state.oracleCapId, row.spot, row.forward),
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
          state.oracleCapId,
          {
            a: row.a,
            b: row.b,
            rho: row.rho,
            rhoNegative: row.rhoNegative,
            m: row.m,
            mNegative: row.mNegative,
            sigma: row.sigma,
          },
          row.riskFreeRate
        ),
        "update_svi"
      );
      byAction.update_svi.push({ wallMs: performance.now() - startedAt, ...gas });
      i++;
      continue;
    }

    mintIndex++;
    const alignedStrike = alignStrikeToGrid(row.strike);
    const gas = await execute(
      () => mintTx({
        predictId: state.predictId,
        managerId: state.managerId,
        oracleId: state.oracleId,
        expiry,
        strike: alignedStrike,
        isUp: row.isUp,
        quantity: row.quantity,
      }),
      "mint"
    );

    const wallMs = performance.now() - startedAt;
    byAction.mint.push({ wallMs, ...gas });

    const direction = row.isUp ? "UP" : "DN";
    const strikeUsd = (Number(alignedStrike) / 1e9).toFixed(0);
    process.stdout.write(`[${ts()}]   [${mintIndex}/${mintRows.length}] ${direction} $${strikeUsd} ${wallMs.toFixed(0)}ms\n`);
    i++;
  }

  const results = buildResultsFile(byAction);
  writeJson(RESULTS_PATH, results);

  const mintSummary = results.summary.byAction.mint;
  console.log(`\n[${ts()}] --- Done ---`);
  console.log(`[${ts()}]   ${results.summary.totalTxs} txs, ${results.mints.length} mints`);
  if (mintSummary) {
    console.log(
      `[${ts()}]   Avg mint: ${mintSummary.wallMs.avg.toFixed(0)}ms, avg gas: ${(mintSummary.gas.avg / 1e9).toFixed(6)} SUI`
    );
  }
  console.log(`[${ts()}]   Results saved to ${RESULTS_PATH}`);
}

async function main() {
  const args = parseArgs();
  let rows = loadScenario();
  if (args.maxRows !== undefined) {
    console.log(`[${ts()}] Limiting to ${args.maxRows} rows`);
    rows = rows.slice(0, args.maxRows);
  }

  if (args.executeOnly) {
    const state = readJson<SimState>(STATE_PATH);
    await executeScenario(rows, state);
    return;
  }

  const state = await setupSimulation();

  if (args.setupOnly) {
    console.log(`[${ts()}] Setup complete`);
    return;
  }

  await executeScenario(rows, state);
}

main().catch((error) => {
  console.error("Simulation failed:", error);
  process.exit(1);
});
