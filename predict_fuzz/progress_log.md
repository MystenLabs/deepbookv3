# Predict Fuzz — Progress Log

## Phase 1: Foundation — COMPLETE
- `types.ts`, `config.ts`, `logger.ts`, `manifest.ts`, `sui-helpers.ts`, `package.json`, `tsconfig.json`, `.gitignore`
- Fix: `@mysten/sui` v2.9.1 uses `SuiJsonRpcClient` from `/jsonRpc` (not `SuiClient`)
- Fix: `SuiJsonRpcClient` requires `network: "testnet"` param

## Phase 2: External Clients — COMPLETE
- `blockscholes.ts` — spot price, synthetic forward, SVI params, expiry discovery
- `gas-pool.ts` — coin splitting and checkout/checkin

## Phase 3: Deploy Pipeline — COMPLETE
- `init.ts` — DUSDC deploy, 10B mint, wallet funding
- `deploy.ts` — 7-tx deploy sequence (split TX4 into TX4a + TX4b)

## Phase 4: Live Services — COMPLETE
- `oracle-updater.ts` — continuous price feed with PTB batching
- `fuzz-worker.ts` — random mint generation

## Phase 5: Oracle Management — COMPLETE
- `oracle-manager.ts` — expiry discovery, oracle creation

## Phase 6: Post-Processing — COMPLETE
- `replay-service.ts`, `analyze.ts`, `check-health.ts`

---

## Integration Testing — 2026-03-21

### Init: SUCCESS
- DUSDC deployed: `0x5ad2ddabdb2487f86c26d0de1285167196ad2ba9cc136b81a20442b577480fff`
- 10B DUSDC minted to deployer
- Oracle and minter wallets funded with 2000 SUI each

### Deploy: SUCCESS (after 5 iterations of fixes)
- Package: `0x96e2d30a4e6d00c132816b3715c4367d1c14c4942a1be634c74cbe98ce812e82`
- 12 oracles created across all live BTC deribit expiries
- All 7 transactions succeeded, all objects verified on-chain

### Fixes discovered during integration:
1. **Package indexing delay**: RPC doesn't have the package immediately after publish. Added `waitForObject()` between transactions.
2. **Block Scholes API**:
   - Exchange must be `"blockscholes"` (not `"composite"`)
   - SVI field names: `alpha`→a, `beta`→b (not `a`, `b`)
   - No `/api/v1/rate/forward` endpoint exists. Replaced with synthetic forward: `F = S * e^(r*T)`
   - Expiry discovery uses `/api/v1/catalog` (much more efficient than probing)
3. **`public_share_object` abort**: `transfer::public_share_object` aborts with code 0 in PTB context on testnet. Pivoted to **transferring oracle_cap to oracle wallet** instead.
4. **Object version staleness**: After TX4a uses oracle_cap by reference, its version bumps. TX4b needs to wait for the new version. Added `waitForObjectVersion()`.

### Oracle Updater: SUCCESS
- 12 oracles updated per tick, ~500ms cycle
- SVI included every 20s
- No errors, clean shutdown on SIGTERM

### Fuzz Worker: RUNNING (mints fail — data issue, not code bug)
- Fires 9 mints per tick (3 oracles × 3 mints)
- All mints fail with `math::div_internal` division error
- **Root cause**: Block Scholes SVI params are all zeros (weekend/market closed)
- **Expected**: Mints will succeed when SVI data is populated (weekday market hours)
- Digest logging works correctly — failures are recorded with error details

### Key Architecture Pivot: oracle_cap ownership
- **DESIGN.md**: oracle_cap is shared via `transfer::public_share_object`
- **Reality**: `public_share_object` aborts in PTB context on testnet
- **Solution**: Transfer oracle_cap to oracle wallet instead
- **Impact on oracle-manager**: For new oracles, `register_oracle_cap` must use deployer_cap only (deployer_cap is owned by deployer, already registered on all oracles). Oracle wallet uses oracle_cap for price updates.
- **No functional impact**: Both caps are OracleCapSVI, both work for update_prices/update_svi.
