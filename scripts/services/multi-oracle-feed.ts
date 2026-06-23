
import { config } from "dotenv";
config({ override: true });
import { MultiOracleService, OracleState, OracleConfig } from "./multi-oracle-service.ts";
import { ValidationEngine, PositionState } from "./validation-engine.ts";
import { getClient, getSigner, getFreshObject } from "../utils/utils.ts";
import { Transaction } from "@mysten/sui/transactions";
import { PredictClient } from "../utils/predict_client.ts";
import { generateSignal, fetchMarketData, fetchFundingRate, SignalResult } from "./signal_engine.ts";
import { loadConfig, resolveMarkets } from "../config/market-config.ts";
import * as fs from "fs";
import * as path from "path";

async function runMultiMarketService() {
  console.log("\n[MULTI-MARKET] Initializing v3.0 (Dynamic Config + Backtesting)...");
  
  const getEnv = (key: string, def?: string) => process.env[key] || def;
  
  const packageId = getEnv("PACKAGE_ID")!;
  const oracleCapId = getEnv("ORACLE_CAP_ID")!;
  const PREDICT_ID = getEnv("PREDICT_ID")!;
  const MANAGER_ID = getEnv("MANAGER_ID")!;
  const REGISTRY_ID = getEnv("REGISTRY_ID")!;
  
  const DEEP_TYPE = getEnv("DEEP_TYPE", "0xbb2549a5991ceec6231a9b8bf824ec63b985922d648d5480ed32a2e219f6ca71::deep::DEEP")!;
  
  const network = (getEnv("NETWORK") as any) || "testnet";
  const client = getClient(network);
  const signer = getSigner();
  const address = signer.getPublicKey().toSuiAddress();
  
  const multiService = new MultiOracleService(packageId, oracleCapId, PREDICT_ID, network);
  const validation = new ValidationEngine(client as any);
  const predictClient = new PredictClient(client as any, packageId, PREDICT_ID);

  // Load markets from config file instead of hardcoding
  const appConfig = loadConfig();
  const MARKETS: OracleConfig[] = resolveMarkets(appConfig).map(m => ({
      ...m,
      quoteAsset: m.quoteAsset || DEEP_TYPE,
  }));

  let cycleCount = 0;
  const dashboardStatePath = path.join(process.cwd(), "dashboard_state.json");
  let lastSignal: { direction: string; score: number } | null = null;
  let lastSignals: Record<string, any> = {};

  while(true) {
      try {
          cycleCount++;
          console.log(`\n[${new Date().toISOString()}] --- CYCLE #${cycleCount} ---`);
          
          for (const market of MARKETS) {
              try {
                  const { oracleId, asset, quoteAsset } = market;
                  const state = await multiService.validateState(oracleId);
                  
                  console.log(`[MARKET] ${asset}/${quoteAsset.split('::').pop()} | State: ${state}`);

                  let oracleUpdatedThisCycle = false;

                  if (state === OracleState.INACTIVE) {
                      console.log(`[ALERT] ${asset} Oracle is INACTIVE. Activating...`);
                      await multiService.activateOracle(oracleId).catch(e => {
                          console.error(`[ACTIVATION-ERROR] ${asset} activation failed:`, e.message);
                          // If activation fails, it might be already active or unusable. 
                          // We'll let the next cycle handle it or rotation if it stays EXPIRED.
                      });
                      continue;
                  }

                  if (state === OracleState.EXPIRED) {
                      console.log(`[ALERT] ${asset} Oracle expiring soon! Rotating...`);
                      const newId = await multiService.rotateOracle(REGISTRY_ID, asset, market.minStrike, market.tickSize);
                      market.oracleId = newId; 
                      continue;
                  }

                  switch(state) {
                      case OracleState.UPDATING:
                          const oracleObj = await getFreshObject(client as any, oracleId);
                          const expiry = Number((oracleObj.data?.content as any)?.fields?.expiry || 0);
                          
                          const marketData = await fetchMarketData(asset).catch(() => null);
                          const fundingRate = await fetchFundingRate(asset).catch(() => 0);
                          
                          // Always update oracle first so spot_timestamp_ms is set
                          try {
                              const updateDigest = await multiService.executeUpdate(oracleId, asset, expiry/1000);
                              validation.logEvent("oracle_update", { digest: updateDigest, oracleId, asset });
                              oracleUpdatedThisCycle = true;
                          } catch (e: any) {
                              console.error(`[UPDATE-ERROR] ${asset}: ${e.message}`);
                              break;
                          }

                          const metricsForSignal = validation.getMetrics();
                          const winRate = metricsForSignal.total > 0 ? 
                              (metricsForSignal.claimed + metricsForSignal.claimable) / metricsForSignal.total : 0.45;

                          const signal: SignalResult = marketData
                              ? generateSignal(marketData, winRate, 1.0, 1.0)
                              : { direction: "HOLD" as const, score: 0, confidence: 0, components: { rsi: 50, ema: 0, momentum: 0, funding: 0, volume: 1, volatility: 0, ml: 0 }, kellySize: 0, session: "OFF" as const };

                          lastSignals[asset] = { 
                              direction: signal.direction, 
                              score: Math.round(signal.score * 1000),
                              confidence: Math.round(signal.confidence * 100),
                              kelly: Math.round(signal.kellySize * 100),
                              rsi: signal.components.rsi,
                              ema: signal.components.ema,
                              momentum: signal.components.momentum,
                              volume: signal.components.volume,
                              ml: signal.components.ml,
                              session: signal.session,
                              fundingRate
                          };
                          lastSignal = { direction: signal.direction, score: signal.score };

                          if (signal.direction === "HOLD" || signal.confidence < 0.05) {
                              console.log(`[SKIP] ${asset} signal=${signal.direction} confidence=${signal.confidence.toFixed(2)} score=${signal.score.toFixed(3)} rsi=${signal.components.rsi.toFixed(1)} mom=${(signal.components.momentum*100).toFixed(2)}%`);
                              break;
                          }

                          console.log(`[PLAN] ${asset} signal: ${signal.direction} | score=${signal.score.toFixed(3)} conf=${signal.confidence.toFixed(2)} kelly=${(signal.kellySize*100).toFixed(1)}% | rsi=${signal.components.rsi.toFixed(1)} mom=${(signal.components.momentum*100).toFixed(2)}% | session=${signal.session}`);

                          const baseQuantity = quoteAsset === DEEP_TYPE ? 10_000_000_000n : 100_000n;
                          const quantity = BigInt(Math.floor(Number(baseQuantity) * Math.max(0.3, signal.kellySize * 2)));
                          const isUp = signal.direction === "UP";

                          // Add pending action first, then execute immediately
                          multiService.addPendingAction({
                              oracleId, managerId: MANAGER_ID, quoteAsset,
                              marketKey: { expiry: BigInt(expiry), isUp },
                              quantity
                          });

                          // Execute trade IMMEDIATELY after oracle update (within same cycle)
                          try {
                              console.log(`[TRADE-IMMEDIATE] ${asset} ${signal.direction} | quantity=${quantity}`);
                              const immediateRes = await multiService.executeTrade(oracleId);
                              if (immediateRes) {
                                  const freshObj = await getFreshObject(client as any, oracleId);
                                  const freshFields = (freshObj.data?.content as any)?.fields;
                                  const freshExpiry = Number(freshFields?.expiry || 0);
                                  const freshOracleData = await multiService.fetchData(asset, freshExpiry/1000);
                                  
                                  await validation.trackMint(
                                      immediateRes.digest, oracleId, asset,
                                      signal.direction,
                                      freshOracleData.spot,
                                      quantity,
                                      freshExpiry,
                                      immediateRes.strike
                                  );
                                  console.log(`[TRADE-SUCCESS] ${asset} ${signal.direction} | digest=${immediateRes.digest}`);
                              } else {
                                  console.log(`[TRADE-SKIP] ${asset} executeTrade returned null`);
                              }
                          } catch (e: any) {
                              console.error(`[TRADE-FAILED] ${asset}: ${e.message}`);
                          }
                          break;

                      case OracleState.FRESH:
                      case OracleState.TRADE_READY:
                          // Pre-flight: re-check oracle freshness before trade to avoid assert_fresh abort
                          try {
                              const preCheck = await getFreshObject(client as any, oracleId);
                              const preFields = (preCheck.data?.content as any)?.fields;
                              const preClock = await client.getObject({ id: "0x6", options: { showContent: true } });
                              const preNow = BigInt((preClock.data?.content as any)?.fields?.timestamp_ms || 0);
                              const preTs = BigInt(preFields?.spot_timestamp_ms || "0");
                              const preThreshold = BigInt(preFields?.bounds?.fields?.spot_staleness_threshold_ms || 60000);
                              // Allow 2x the threshold since oracle was already validated as FRESH/TRADE_READY
                              const effectiveThreshold = preThreshold * 2n;
                              if (preNow - preTs >= effectiveThreshold) {
                                  console.log(`[SKIP-TRADE] ${asset} oracle stale before trade (${preNow - preTs}ms >= ${effectiveThreshold}ms). Will refresh next cycle.`);
                                  break;
                              }
                          } catch {}
                          
                          // Use signal engine for trade direction
                          const tradeMarketData = await fetchMarketData(asset).catch(() => null);
                          let tradeDirection: "UP" | "DOWN" = "UP";
                          if (tradeMarketData) {
                              const tradeSignal = generateSignal(tradeMarketData);
                              tradeDirection = tradeSignal.direction === "HOLD" ? "UP" : tradeSignal.direction;
                          }

                          const tradeRes = await multiService.executeTrade(oracleId);
                          if (tradeRes) {
                              const oracleObjFresh = await getFreshObject(client as any, oracleId);
                              const fields = (oracleObjFresh.data?.content as any)?.fields;
                              const expiryFresh = Number(fields?.expiry || 0);
                              const oracleData = await multiService.fetchData(asset, expiryFresh/1000);
                              
                              await validation.trackMint(
                                  tradeRes.digest, oracleId, asset, 
                                  tradeDirection,
                                  oracleData.spot, 
                                  quoteAsset === DEEP_TYPE ? 10_000_000_000n : 100_000n, 
                                  expiryFresh, 
                                  tradeRes.strike
                              );
                          }
                          break;
                  }
              } catch (e: any) {
                  console.error(`[MARKET-ERROR] Failed processing ${market.asset}:`, e.message);
              }
          }

          // Settle expired oracles for open positions
          const openPositions = validation.getOpenPositions();
          const uniqueExpiredOracles = new Map<string, { market: string; expiry: number }>();
          for (const pos of openPositions) {
              if (Date.now() > pos.expiry) {
                  uniqueExpiredOracles.set(pos.oracleId, { market: pos.market, expiry: pos.expiry });
              }
          }

          for (const [oracleId, info] of uniqueExpiredOracles.entries()) {
              try {
                  await multiService.settleOracle(oracleId, info.market);
              } catch (e: any) {
                  console.error(`[SETTLE-LOOP] Failed to settle oracle ${oracleId}:`, e.message);
              }
          }

          // Verify settlement for expired oracles
          for (const pos of openPositions) {
              if (Date.now() > pos.expiry) {
                  try {
                      await validation.verifySettlement(pos.oracleId);
                  } catch (e: any) {
                      console.error(`[VERIFY-SETTLE-LOOP] Failed to verify settlement for oracle ${pos.oracleId}:`, e.message);
                  }
              }
          }

          // Maintenance: Claims for all markets
          const allPositions = validation.getAllPositions();
          const claimable = allPositions.filter(p => (p as any).state === PositionState.CLAIMABLE);
          for (const pos of claimable) {
              const attempts = (pos as any).claimAttempts || 0;
              if (attempts >= 3) {
                  if (attempts === 3) {
                      console.warn(`[CLAIM] Marking ${pos.market} position ${pos.positionId} as FAILED after 3 failed attempts`);
                      (pos as any).state = PositionState.FAILED;
                      (pos as any).claimAttempts = 4;
                      validation.saveState();
                  }
                  continue;
              }
              try {
                  console.log(`[CLAIM] Redeeming position for ${pos.market}...`);
                  const market = MARKETS.find(m => m.asset === pos.market);
                  if (!market) continue;

                  const tx = new Transaction();
                  predictClient.redeem(tx, {
                      managerId: MANAGER_ID,
                      oracleId: pos.oracleId,
                      marketKey: { 
                          oracleId: pos.oracleId, expiry: BigInt(pos.expiry), 
                          strike: BigInt(pos.strike), isUp: pos.direction === "UP" 
                      },
                      quantity: BigInt(pos.quantity),
                      quoteAsset: market.quoteAsset
                  });
                  const res = await client.signAndExecuteTransaction({ transaction: tx, signer });
                  await client.waitForTransaction({ digest: res.digest });
                  await validation.markClaimed(pos.positionId, res.digest, BigInt(pos.quantity));
              } catch (e: any) {
                  (pos as any).claimAttempts = attempts + 1;
                  console.error(`[CLAIM] Failed for ${pos.market} (attempt ${(pos as any).claimAttempts}/3):`, e.message);
                  validation.saveState();
              }
          }

          // Phase 8: Monitoring
          let totalGas = 0n;
          let totalDeep = 0n;
          try {
              const coins = await client.getCoins({ owner: address });
              totalGas = coins.data.reduce((sum, c) => sum + BigInt(c.balance), 0n);
              if (totalGas < 1_000_000_000n) console.warn("[MONITOR] Low Gas: ", Number(totalGas)/1e9, "SUI");

              const deepCoins = await client.getCoins({ owner: address, coinType: DEEP_TYPE });
              totalDeep = deepCoins.data.reduce((sum, c) => sum + BigInt(c.balance), 0n);
              if (totalDeep < 1_000_000_000n) console.warn("[MONITOR] Low DEEP (wallet): ", Number(totalDeep)/1e6, "DEEP - note: main balance is in PredictManager");
          } catch (e: any) {
              console.warn("[MONITOR] Failed to check balances:", e.message);
          }

          // Cycle summary
          const metricsSummary = validation.getMetrics();
          const winRate = metricsSummary.total > 0 ? 
              ((metricsSummary.claimed + metricsSummary.claimable) / metricsSummary.total * 100).toFixed(1) : "0.0";
          console.log(`[CYCLE #${cycleCount}] Win Rate: ${winRate}% | Total: ${metricsSummary.total} | Open: ${metricsSummary.open} | Claimed: ${metricsSummary.claimed} | Settled: ${metricsSummary.settled}`);

          // Save state for dashboard
          let btcSpot = 0n;
          let btcForward = 0n;
          try {
              const btcM = MARKETS.find(m => m.asset === "BTC");
              if (btcM) {
                  const btcObj = await getFreshObject(client as any, btcM.oracleId);
                  if (btcObj.data) {
                      const fields = (btcObj.data.content as any)?.fields;
                      btcSpot = BigInt(fields?.prices?.fields?.spot || 0);
                      const basis = BigInt(fields?.prices?.fields?.basis || 0);
                      btcForward = (btcSpot * basis) / 1000000000n;
                  }
              }
          } catch (e: any) {
              console.error("[DASHBOARD] Failed to fetch BTC price for dashboard:", e.message);
          }

          const allPos = validation.getAllPositions();
          const byMarket: Record<string, any> = {};
          for (const pos of allPos) {
              if (!byMarket[pos.market]) {
                  byMarket[pos.market] = { total: 0, winners: 0, losses: 0, up: 0, down: 0 };
              }
              const mStats = byMarket[pos.market];
              mStats.total++;
              if (pos.direction === "UP") mStats.up++;
              else mStats.down++;
              
              if (pos.state === "CLAIMED" || pos.state === "CLAIMABLE") {
                  mStats.winners++;
              } else if (pos.state === "SETTLED" || pos.state === "FAILED") {
                  mStats.losses++;
              }
          }

          const recentPositions = allPos.slice(-20).reverse().map(pos => ({
              market: pos.market,
              direction: pos.direction,
              state: pos.state,
              entryPrice: pos.entryPrice,
              strike: pos.strike,
              createdAt: pos.createdAt
          }));

          const metrics = validation.getMetrics();
          const btcMarket = MARKETS.find(m => m.asset === "BTC");

          fs.writeFileSync(dashboardStatePath, JSON.stringify({
              cycle: cycleCount,
              lastUpdate: new Date().toISOString(),
              tradingEnabled: true,
              status: "Running",
              address,
              managerId: MANAGER_ID,
              network,
              sui_balance: `${(Number(totalGas)/1e9).toFixed(2)} SUI`,
              balances: {
                  sui: (Number(totalGas)/1e9).toFixed(2),
                  DEEP: Number(totalDeep)/1e6,
              },
              analysis: {
                  spot: btcSpot.toString(),
                  forward: btcForward.toString(),
                  signal: lastSignal?.direction || "HOLD",
                  signals: lastSignals,
              },
              oracle: {
                  id: btcMarket ? btcMarket.oracleId : "0x...",
                  expiry: 0
              },
              positions: {
                  total: metrics.total,
                  open: metrics.open,
                  claimable: metrics.claimable,
                  claimed: metrics.claimed,
                  settled: metrics.settled,
                  winners: metrics.claimed + metrics.claimable,
                  winRate: metrics.total > 0 ? ((metrics.claimed + metrics.claimable) / metrics.total * 100).toFixed(1) : "0.0"
              },
              byMarket,
              recentPositions
          }, null, 2));

          if (process.argv.includes("--once")) {
              console.log("[MULTI-MARKET] Test cycle complete. Exiting...");
              process.exit(0);
          }

      } catch (e) { console.error("[LOOP] Fatal Error:", e); }
          await new Promise(r => setTimeout(r, appConfig.trading.cycleIntervalMs));
  }
}

runMultiMarketService().catch(console.error);
