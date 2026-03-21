import {
  ARTIFACTS_DIR,
  DIGESTS_PATH,
  STATE_PATH,
  type DigestEntry,
  type DigestsFile,
  type ScenarioRow,
  type SimState,
  loadScenario,
  ts,
  writeJson,
} from "./shared.js";
import {
  activateOracleTx,
  address,
  adminDepositTx,
  buildFastExecutorState,
  createManagerTx,
  createOracleCapTx,
  createOracleTx,
  createPredictTx,
  depositToManagerTx,
  executeAndWait,
  executeFast,
  loadFastExecutor,
  mintTx,
  registerOracleCapTx,
  updatePricesTx,
  updateSviTx,
} from "./runtime.js";

const DUSDC_DECIMALS = 1_000_000n;
const QUANTITY_SCALE = 1000n;
const EXPIRY_MS = BigInt(Date.now()) + 7n * 24n * 60n * 60n * 1000n;

function parseArgs() {
  return {
    setupOnly: process.argv.includes("--setup-only"),
  };
}

function findFirst(rows: ScenarioRow[], action: string): ScenarioRow {
  const row = rows.find((entry) => entry.action === action);
  if (!row) {
    throw new Error(`Scenario is missing a required ${action} row`);
  }
  return row;
}

async function setupSimulation(rows: ScenarioRow[]): Promise<SimState> {
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
      oracleCapId,
      underlyingAsset: "BTC",
      expiry: EXPIRY_MS,
    }),
    "create_oracle"
  );
  const oracleChange = result.objectChanges.find(
    (change: any) => change.type === "created" && change.objectType.includes("OracleSVI") && !change.objectType.includes("Cap")
  );
  const oracleId: string = oracleChange.objectId;
  console.log(`[${ts()}]   Oracle: ${oracleId}`);

  await executeAndWait(registerOracleCapTx(oracleId, oracleCapId), "register_oracle_cap");
  await executeAndWait(activateOracleTx(oracleId, oracleCapId), "activate_oracle");
  console.log(`[${ts()}]   Oracle activated`);

  const firstPrice = findFirst(rows, "update_prices");
  const firstSvi = findFirst(rows, "update_svi");

  await executeAndWait(
    updatePricesTx(oracleId, oracleCapId, BigInt(firstPrice.spot), BigInt(firstPrice.forward)),
    "update_prices"
  );
  await executeAndWait(
    updateSviTx(
      oracleId,
      oracleCapId,
      {
        a: BigInt(firstSvi.a),
        b: BigInt(firstSvi.b),
        rho: BigInt(firstSvi.rho),
        rhoNegative: firstSvi.rho_negative === "true",
        m: BigInt(firstSvi.m),
        mNegative: firstSvi.m_negative === "true",
        sigma: BigInt(firstSvi.sigma),
      },
      BigInt(firstSvi.risk_free_rate)
    ),
    "update_svi"
  );
  console.log(`[${ts()}]   Initial oracle data set`);

  const vaultSeed = 500_000n * DUSDC_DECIMALS;
  await executeAndWait(adminDepositTx(predictId, vaultSeed), "admin_deposit");
  console.log(`[${ts()}]   Vault funded: ${vaultSeed / DUSDC_DECIMALS} DUSDC`);

  result = await executeAndWait(createManagerTx(), "create_manager");
  const managerEvent = result.events.find((event: any) => event.type.includes("ManagerCreated"));
  const managerId: string = managerEvent.parsedJson.manager_id;
  console.log(`[${ts()}]   Manager: ${managerId}`);

  const userFunds = 500_000n * DUSDC_DECIMALS;
  await executeAndWait(depositToManagerTx(managerId, userFunds), "deposit_to_manager");
  console.log(`[${ts()}]   Manager funded: ${userFunds / DUSDC_DECIMALS} DUSDC`);

  const fastExecutor = await buildFastExecutorState([predictId, oracleId, oracleCapId, managerId]);

  const state: SimState = {
    predictId,
    oracleId,
    oracleCapId,
    managerId,
    expiry: String(EXPIRY_MS),
    fastExecutor,
  };

  writeJson(STATE_PATH, state);
  console.log(`[${ts()}]   State saved to ${ARTIFACTS_DIR}`);

  return state;
}

async function executeScenario(rows: ScenarioRow[], state: SimState): Promise<DigestsFile> {
  const expiry = BigInt(state.expiry);
  const mintRows = rows.filter((row) => row.action === "mint");

  console.log(`\n[${ts()}] Loaded ${rows.length} rows (${mintRows.length} mints)`);
  loadFastExecutor(state.fastExecutor);
  console.log(`[${ts()}] --- Executing ${rows.length} actions ---\n`);

  const digests: DigestEntry[] = [];
  let mintIndex = 0;
  let oracleUpdateCount = 0;

  for (let index = 0; index < rows.length; index++) {
    const row = rows[index];
    const startedAt = performance.now();

    if (row.action === "update_prices") {
      const digest = await executeFast(
        updatePricesTx(state.oracleId, state.oracleCapId, BigInt(row.spot), BigInt(row.forward), "fast")
      );
      digests.push({ index, action: "update_prices", digest, wallMs: performance.now() - startedAt });
      oracleUpdateCount++;
      continue;
    }

    if (row.action === "update_svi") {
      const digest = await executeFast(
        updateSviTx(
          state.oracleId,
          state.oracleCapId,
          {
            a: BigInt(row.a),
            b: BigInt(row.b),
            rho: BigInt(row.rho),
            rhoNegative: row.rho_negative === "true",
            m: BigInt(row.m),
            mNegative: row.m_negative === "true",
            sigma: BigInt(row.sigma),
          },
          BigInt(row.risk_free_rate),
          "fast"
        )
      );
      digests.push({ index, action: "update_svi", digest, wallMs: performance.now() - startedAt });
      continue;
    }

    if (row.action === "mint") {
      mintIndex++;
      const isUp = row.is_up === "true";
      const digest = await executeFast(
        mintTx(
          {
            predictId: state.predictId,
            managerId: state.managerId,
            oracleId: state.oracleId,
            expiry,
            strike: BigInt(row.strike),
            isUp,
            quantity: BigInt(row.quantity) / QUANTITY_SCALE,
          },
          "fast"
        )
      );

      const wallMs = performance.now() - startedAt;
      digests.push({
        index,
        action: "mint",
        digest,
        wallMs,
        strike: row.strike,
        isUp,
        quantity: row.quantity,
      });

      const direction = isUp ? "UP" : "DN";
      const strikeUsd = (Number(BigInt(row.strike)) / 1e9).toFixed(0);
      process.stdout.write(`[${ts()}]   [${mintIndex}/${mintRows.length}] ${direction} $${strikeUsd} ${wallMs.toFixed(0)}ms\n`);
    }
  }

  const output: DigestsFile = {
    predictId: state.predictId,
    oracleId: state.oracleId,
    managerId: state.managerId,
    summary: {
      totalRows: rows.length,
      byAction: {
        update_prices: oracleUpdateCount,
        update_svi: rows.filter((row) => row.action === "update_svi").length,
        mint: mintIndex,
      },
    },
    digests,
  };

  writeJson(DIGESTS_PATH, output);

  const mintDigests = digests.filter((entry) => entry.action === "mint");
  const averageMs = mintDigests.reduce((sum, entry) => sum + entry.wallMs, 0) / mintDigests.length;

  console.log(`\n[${ts()}] --- Done ---`);
  console.log(`[${ts()}]   ${digests.length} txs, ${mintIndex} mints, ${oracleUpdateCount} oracle updates`);
  console.log(`[${ts()}]   Avg mint: ${averageMs.toFixed(0)}ms`);
  console.log(`[${ts()}]   Digests saved to ${DIGESTS_PATH}`);

  return output;
}

async function main() {
  const args = parseArgs();
  const rows = loadScenario();
  const state = await setupSimulation(rows);

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
