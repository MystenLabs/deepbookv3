# Predict Error-Constant Coverage Matrix

> **Audit artifact + Phase-2 worklist.** Every `const E*` declared in
> `packages/predict/sources/**` and `packages/predict_math/sources/**`, whether an
> `expected_failure` test triggers it, and the covering test fn. Module-qualified.

**Regenerate:** `python3 .redesign/gen_coverage_matrix.py` (from the repo root).

## Summary — 125/157 covered, 12 documented (defensive / needs-special / gas-bound), 20 open

| Priority band | Open (untested, undocumented) |
|---|---|
| P0 | 0 |
| P1 | 0 |
| P2 | 0 |
| P3 | 20 |

Priority bands:
- **P0** — `expiry_market` public-flow gates + the invariant-level hot-flow pass.
- **P1** — economic / lifecycle / auth error paths: oracle, pyth, pricing, plp, incentive, order, registry, manager.
- **P2** — strike-index internals + accounting leaves + math.
- **P3** — config-bounds envelopes (trivial-to-trigger, lowest blast radius).

A constant that is a genuinely-unreachable defensive invariant is marked
`DEFENSIVE` with the reason — no fabricated path, no test-only source seam added to reach it.

## P0

### `expiry_market` — 6/7
| Error const | Covered | Covering test |
|---|---|---|
| `EWrongMarketOracle` | ✅ | `redeem_with_wrong_oracle_aborts` |
| `EWrongPythSource` | ✅ | `mint_with_wrong_pyth_source_aborts` |
| `EValuationExceedsCash` | 📄 documented | DEFENSIVE — pool_nav asserts the valuation lock first (outside a sync EValuationNotInProgress masks it); inside a sync the rebalance tops up cash before pool_nav, and every cash-mutating flow ends with assert_cash_backing whose conservative payout_liability bound already implies required_cash. Pure solvency safety net. |
| `EPackageVersionDisabled` | ✅ | `mint_with_current_version_disabled_aborts` |
| `EMintPaused` | ✅ | `mint_while_expiry_mint_paused_aborts` |
| `EFullCloseRequired` | ✅ | `redeem_settled_partial_close_aborts` |
| `EProofRequiredForLiveRedeem` | ✅ | `redeem_settled_on_live_order_aborts` |

## P1

### `builder_code` — 0/1
| Error const | Covered | Covering test |
|---|---|---|
| `ENotOwner` | 📄 documented | UNREACHABLE-IN-UNIT — claim_all_builder_fees takes &sui::accumulator::AccumulatorRoot, created exclusively by the system at the pinned framework rev (no #[test_only] constructor or test_scenario provisioning). |

### `incentive` — 4/4
| Error const | Covered | Covering test |
|---|---|---|
| `EZeroDeposit` | ✅ | `deposit_zero_coin_aborts` |
| `EZeroStreamDuration` | ✅ | `deposit_zero_duration_aborts` |
| `EStreamDurationTooLong` | ✅ | `deposit_duration_over_max_aborts` |
| `EFeedMismatch` | ✅ | `supply_with_wrong_feed_incentive_source_aborts` |

### `market_oracle` — 16/16
| Error const | Covered | Covering test |
|---|---|---|
| `EInvalidMarketOracleCap` | ✅ | `update_svi_with_unregistered_cap_aborts` |
| `EMarketNotActive` | ✅ | `mint_after_expiry_before_settlement_aborts` |
| `EMarketSettled` | ✅ | `price_push_on_settled_oracle_aborts` |
| `ESpotDeviationTooLarge` | ✅ | `spot_step_beyond_max_deviation_aborts` |
| `EBasisDeviationTooLarge` | ✅ | `basis_step_beyond_max_deviation_aborts` |
| `EBasisOutOfRange` | ✅ | `first_push_basis_outside_absolute_range_aborts` |
| `EZeroSpot` | ✅ | `zero_spot_push_aborts` |
| `EZeroForward` | ✅ | `zero_forward_push_aborts` |
| `EStalePriceSourceUpdate` | ✅ | `price_push_with_non_advancing_source_timestamp_aborts` |
| `EStaleSVISourceUpdate` | ✅ | `svi_update_with_non_advancing_source_timestamp_aborts` |
| `EWrongPythSource` | ✅ | `pyth_observation_from_unbound_source_aborts` |
| `EFuturePriceSourceUpdate` | ✅ | `price_push_with_future_source_timestamp_aborts` |
| `EFutureSVISourceUpdate` | ✅ | `svi_update_with_future_source_timestamp_aborts` |
| `EInvalidSviRho` | ✅ | `assert_valid_svi_rejects_rho_magnitude_above_one` |
| `EInvalidSviSigma` | ✅ | `assert_valid_svi_rejects_sigma_above_max`; `assert_valid_svi_rejects_sigma_below_min` |
| `EPackageVersionDisabled` | ✅ | `update_svi_after_current_version_disabled_aborts` |

### `order` — 7/7
| Error const | Covered | Covering test |
|---|---|---|
| `EInvalidOrderId` | ✅ | `from_order_id_rejects_bits_above_envelope` |
| `EInvalidOpenedAt` | ✅ | `new_rejects_opened_at_over_u48` |
| `EInvalidBoundaryIndex` | ✅ | `new_rejects_boundary_index_over_grid_max` |
| `EInvalidFloorShares` | ✅ | `new_rejects_floor_shares_above_quantity` |
| `EInvalidBoundaryRange` | ✅ | `new_rejects_lower_not_below_higher` |
| `EInvalidQuantity` | ✅ | `new_rejects_non_lot_quantity` |
| `EInvalidSequence` | ✅ | `new_rejects_sequence_over_u40` |

### `plp` — 9/11
| Error const | Covered | Covering test |
|---|---|---|
| `EExpiryMarketNotActive` | ✅ | `sync_expiry_on_unregistered_settled_market_aborts` |
| `EWrongPoolVault` | ✅ | `finish_pool_sync_with_other_vault_sync_aborts` |
| `EExpiryMarketAlreadySynced` | ✅ | `sync_expiry_twice_in_one_sync_aborts` |
| `EMissingExpirySync` | ✅ | `finish_pool_sync_without_syncing_active_expiry_aborts` |
| `EZeroSupply` | ✅ | `supply_with_zero_payment_aborts` |
| `EZeroWithdraw` | ✅ | `withdraw_with_zero_plp_aborts` |
| `EInvalidInitialSupply` | 📄 documented | DEFENSIVE — bootstrap (total_supply==0) with nonzero pool value needs idle inflow without supply; every idle inflow path is supply (blocked at bootstrap by this guard) or expiry cash returns, and an expiry cannot be registered at zero supply (register_expiry requires idle >= the max-funding cap). Only a heavy multi-flow (swept premium -> full LP exit -> admin change) could approach it; no minimal production-valid fixture. |
| `EZeroShares` | ✅ | `supply_dust_payment_rounding_to_zero_shares_aborts` |
| `EZeroPoolValue` | 📄 documented | DEFENSIVE — requires lp_pool_value to clamp to exactly 0 while total_supply > 0 (the documented active-mark-collapse scenario); the clamp math itself is unit-tested in plp_tests::lp_pool_value_floors_at_zero_*. |
| `EPackageVersionDisabled` | ✅ | `start_pool_sync_with_current_version_disabled_aborts` |
| `ENoPlpHolders` | ✅ | `incentive_deposit_with_no_plp_holders_aborts` |

### `predict_manager` — 7/8
| Error const | Covered | Covering test |
|---|---|---|
| `EInsufficientPosition` | ✅ | `remove_position_that_does_not_exist_aborts` |
| `ENotOwner` | ✅ | `assert_owner_aborts_for_non_owner`; `non_owner_cannot_mint_trade_cap`; `unset_builder_code_by_non_owner_aborts` |
| `EInvalidProof` | ✅ | `cross_manager_proof_validation_aborts` |
| `EInvalidCap` | ✅ | `revoked_trade_cap_cannot_generate_proof` |
| `EMaxCapsReached` | 📄 documented | GAS-BOUND — needs MAX_CAPS (1000) prior cap mints; allow_listed is a linear-scan VecSet so filling it is quadratic gas and exceeds the standard --gas-limit 100000000000 (~750 mints fit, 1000 do not). Guard verified present; not coverable at the suite's standard budget. |
| `ECapNotInList` | ✅ | `revoking_unknown_cap_aborts` |
| `EExpirySummaryHasOpenPositions` | ✅ | `resolve_expiry_summary_with_open_positions_aborts` |
| `EPositionAlreadyExists` | ✅ | `add_position_duplicate_aborts` |

### `pricing` — 9/9
| Error const | Covered | Covering test |
|---|---|---|
| `EZeroForward` | ✅ | `build_curve_with_zero_forward_aborts` |
| `ECannotBeNegative` | ✅ | `build_curve_with_degenerate_sigma_negative_inner_term_aborts` |
| `EZeroVariance` | ✅ | `build_curve_with_zero_total_variance_aborts` |
| `EInvalidRange` | ✅ | `live_quote_with_equal_range_bounds_aborts` |
| `EInvalidCurveRange` | ✅ | `build_curve_with_zero_tick_size_aborts` |
| `EBlockScholesPriceStale` | ✅ | `live_quote_with_stale_block_scholes_prices_aborts` |
| `EBlockScholesSVIStale` | ✅ | `live_quote_with_fresh_prices_but_stale_svi_aborts` |
| `EInvalidStrikeRatio` | ✅ | `build_curve_with_sub_resolution_strike_ratio_aborts` |
| `EPythSpotStale` | ✅ | `assert_pyth_spot_fresh_with_stale_source_aborts` |

### `pyth_source` — 1/7
| Error const | Covered | Covering test |
|---|---|---|
| `EStaleSourceUpdate` | 📄 documented | NEEDS-SPECIAL — only in update_from_lazer, which consumes a real signed pyth_lazer::Update (no Move-side test constructor; requires deployed State + trusted ECDSA signers). Integration/testnet coverage only. |
| `EZeroSpot` | ✅ | `supply_with_zero_spot_incentive_source_aborts` |
| `EFutureSourceUpdate` | 📄 documented | NEEDS-SPECIAL — same update_from_lazer blocker as EStaleSourceUpdate. |
| `EPackageVersionDisabled` | 📄 documented | NEEDS-SPECIAL — first gate of update_from_lazer; same Lazer blocker. |
| `ELazerFeedNotFound` | 📄 documented | DEFENSIVE (unit scope) — private extract_spot behind the un-constructible LazerUpdate. |
| `ELazerPriceUnavailable` | 📄 documented | DEFENSIVE (unit scope) — same extract_spot blocker; three sites share the code. |
| `ELazerNegativePrice` | 📄 documented | DEFENSIVE (unit scope) — normalize_pyth_price behind the Lazer blocker; real Pyth prices are non-negative. |

### `registry` — 11/11
| Error const | Covered | Covering test |
|---|---|---|
| `EFeedIdMismatch` | ✅ | `create_expiry_market_with_wrong_pyth_source_object_aborts` |
| `EPythSourceAlreadyCreated` | ✅ | `create_pyth_source_duplicate_feed_aborts` |
| `EInvalidExpiry` | ✅ | `create_expiry_market_with_expiry_at_now_aborts` |
| `EExpiryMarketAlreadyCreated` | ✅ | `create_expiry_market_duplicate_expiry_aborts` |
| `EPauseCapNotValid` | ✅ | `revoked_pause_cap_cannot_disable_version` |
| `EPackageVersionDisabled` | ✅ | `create_pyth_source_with_current_version_disabled_aborts` |
| `EVersionAlreadyEnabled` | ✅ | `enable_version_already_enabled_aborts` |
| `EVersionNotEnabled` | ✅ | `disable_version_never_enabled_aborts` |
| `ECannotDisableLastVersion` | ✅ | `disable_last_remaining_version_aborts` |
| `EPythFeedNotRegistered` | ✅ | `set_pyth_feed_tick_size_unknown_feed_aborts` |
| `EIncentiveAssetNotConfigured` | ✅ | `deposit_unconfigured_incentive_asset_aborts` |

### `settlement_state` — 1/2
| Error const | Covered | Covering test |
|---|---|---|
| `EMarketNotSettled` | ✅ | `settlement_price_read_before_settlement_aborts` |
| `EInvalidSettlementTimestamp` | 📄 documented | DEFENSIVE — the settlement-recording site enforces source_ts > expiry before storing, so the read-time re-assert cannot fail for any settled oracle produced by production flows. |

## P2

### `expiry_cash` — 2/2
| Error const | Covered | Covering test |
|---|---|---|
| `EInsufficientCash` | ✅ | `assert_backing_underfunded_aborts`; `pay_authorized_underfunded_aborts`; `release_surplus_preserves_required_cash` |
| `EUnresolvedTradingFeesUnderflow` | ✅ | `resolve_more_fee_basis_than_collected_aborts` |

### `i64` — 1/1
| Error const | Covered | Covering test |
|---|---|---|
| `EZeroDivisor` | ✅ | `div_scaled_by_zero_aborts` |

### `liquidation_book` — 4/4
| Error const | Covered | Covering test |
|---|---|---|
| `EActiveOrderAlreadyExists` | ✅ | `insert_same_active_order_twice_aborts` |
| `EActiveOrderNotFound` | ✅ | `remove_from_empty_book_aborts`; `remove_uninserted_order_from_nonempty_book_aborts` |
| `ELiquidatedOrderAlreadyExists` | ✅ | `insert_liquidated_order_aborts` |
| `ELiquidatedOrderNotFound` | ✅ | `clear_never_liquidated_order_aborts` |

### `math` — 4/4
| Error const | Covered | Covering test |
|---|---|---|
| `EInputZero` | ✅ | `ln_of_zero_aborts` |
| `EInvalidPrecision` | ✅ | `sqrt_precision_above_float_aborts`; `sqrt_precision_zero_aborts` |
| `EPow10ExponentTooLarge` | ✅ | `pow10_nineteen_aborts` |
| `EExpOverflow` | ✅ | `exp_above_u64_fit_bound_aborts`; `exp_just_above_u64_fit_bound_aborts` |

### `pool_accounting` — 7/7
| Error const | Covered | Covering test |
|---|---|---|
| `EUnknownRegisteredExpiry` | ✅ | `unknown_expiry_flow_read_aborts` |
| `ERegisteredExpiryAlreadyExists` | ✅ | `register_expiry_twice_aborts` |
| `EMaxExpiryFundingExceeded` | ✅ | `lowering_funding_cap_below_net_funding_aborts`; `send_expiry_cash_above_funding_cap_aborts` |
| `ETerminalAccountingStarted` | ✅ | `send_expiry_cash_after_terminal_accounting_aborts` |
| `EMaxActiveExpiryMarkets` | ✅ | `register_expiry_above_active_limit_aborts` |
| `EInsufficientActiveAllocationBacking` | ✅ | `register_expiry_without_idle_backing_aborts` |
| `EInvalidActiveFundingAggregate` | ✅ | `cap_update_with_inconsistent_old_cap_aborts` |

### `strike_exposure` — 2/2
| Error const | Covered | Covering test |
|---|---|---|
| `ESettledLiabilityNotMaterialized` | ✅ | `destroy_live_indexes_before_materialize_aborts` |
| `EInvalidCloseQuantity` | ✅ | `redeem_above_order_quantity_aborts` |

### `strike_grid` — 5/5
| Error const | Covered | Covering test |
|---|---|---|
| `EInvalidTickSize` | ✅ | `new_centered_aborts_with_unaligned_tick_size`; `new_centered_aborts_with_zero_tick_size` |
| `EInvalidStrikeGrid` | ✅ | `insert_finite_above_grid_aborts`; `insert_finite_below_grid_aborts`; `insert_full_open_range_aborts`; `insert_lower_above_higher_aborts`; `insert_lower_equal_higher_aborts`; `insert_unaligned_strike_aborts` |
| `EOracleTickSizeTooSmallForSpot` | ✅ | `new_centered_aborts_when_tick_size_too_small_for_spot` |
| `EInvalidOracleSpot` | ✅ | `new_centered_aborts_without_spot` |
| `EOracleTickSizeTooLargeForSpot` | ✅ | `new_centered_aborts_when_tick_size_too_large_for_spot` |

### `strike_nav_matrix` — 4/4
| Error const | Covered | Covering test |
|---|---|---|
| `EInsufficientQuantity` | ✅ | `remove_more_floor_shares_than_inserted_aborts`; `remove_range_above_inserted_quantity_aborts` |
| `EInvalidCurveRange` | ✅ | `live_value_with_empty_curve_aborts` |
| `EZeroQuantity` | ✅ | `insert_range_with_zero_quantity_aborts` |
| `EInvalidPreallocatedTicks` | ✅ | `new_with_preallocated_ticks_above_tick_count_aborts` |

### `strike_payout_tree` — 2/2
| Error const | Covered | Covering test |
|---|---|---|
| `EInsufficientPayoutTerms` | ✅ | `remove_from_empty_tree_aborts`; `remove_more_than_inserted_aborts` |
| `EInvalidPayoutTerms` | ✅ | `insert_terminal_greater_than_backing_aborts` |

## P3

### `config_constants` — 19/29
| Error const | Covered | Covering test |
|---|---|---|
| `EInvalidBaseFee` | ❌ | — |
| `EInvalidMinFee` | ❌ | — |
| `EInvalidMinAskPrice` | ❌ | — |
| `EInvalidMaxAskPrice` | ❌ | — |
| `EInvalidPythSpotFreshnessMs` | ✅ | `set_pyth_spot_freshness_ms_above_max_aborts`; `set_pyth_spot_freshness_ms_zero_aborts` |
| `EInvalidBlockScholesPricesFreshnessMs` | ✅ | `set_block_scholes_prices_freshness_ms_above_max_aborts`; `set_block_scholes_prices_freshness_ms_zero_aborts` |
| `EInvalidBlockScholesSVIFreshnessMs` | ✅ | `set_block_scholes_svi_freshness_ms_above_max_aborts`; `set_block_scholes_svi_freshness_ms_zero_aborts` |
| `EInvalidProtocolReserveProfitShare` | ✅ | `reserve_profit_share_above_float_aborts` |
| `EInvalidSettlementFreshnessMs` | ✅ | `set_settlement_freshness_ms_above_max_aborts`; `set_settlement_freshness_ms_below_min_aborts` |
| `EInvalidMaxSpotDeviation` | ✅ | `set_basis_bounds_max_spot_deviation_too_large_aborts`; `set_basis_bounds_max_spot_deviation_zero_aborts` |
| `EInvalidMaxBasisDeviation` | ✅ | `set_basis_bounds_max_basis_deviation_too_large_aborts`; `set_basis_bounds_max_basis_deviation_zero_aborts` |
| `EInvalidMinBasis` | ✅ | `set_basis_bounds_min_basis_above_envelope_aborts`; `set_basis_bounds_min_basis_below_envelope_aborts` |
| `EInvalidMaxBasis` | ✅ | `set_basis_bounds_max_basis_above_envelope_aborts`; `set_basis_bounds_max_basis_below_envelope_aborts` |
| `EInvalidMaxExpiryFunding` | ❌ | — |
| `EInvalidTradingLossRebateRate` | ❌ | — |
| `EInvalidTerminalFloorIndex` | ❌ | — |
| `EInvalidExpiryFeeWindowMs` | ❌ | — |
| `EInvalidExpiryFeeMaxMultiplier` | ❌ | — |
| `EInvalidLowerBenefitPower` | ✅ | `set_benefit_powers_lower_below_min_aborts` |
| `EInvalidUpperBenefitPower` | ✅ | `set_benefit_powers_upper_below_min_aborts` |
| `EInvalidBenefitPowers` | ✅ | `set_benefit_powers_non_steeper_upper_aborts` |
| `EInvalidValuationLiquidationBudget` | ✅ | `valuation_budget_above_max_aborts`; `valuation_budget_below_min_aborts` |
| `EInvalidTradeLiquidationBudget` | ✅ | `trade_budget_above_max_aborts`; `trade_budget_below_min_aborts` |
| `EInvalidLiquidationLtv` | ❌ | — |
| `EInvalidOracleTickSize` | ✅ | `assert_oracle_tick_size_unaligned_aborts`; `create_pyth_source_unaligned_tick_size_aborts` |
| `EInvalidWithdrawFeeAlpha` | ✅ | `withdraw_fee_alpha_above_max_aborts`; `withdraw_fee_alpha_below_min_aborts` |
| `EInvalidEwmaAlpha` | ✅ | `set_params_alpha_above_max_aborts`; `set_params_alpha_zero_aborts` |
| `EInvalidEwmaZScoreThreshold` | ✅ | `set_params_threshold_above_max_aborts`; `set_params_threshold_below_min_aborts` |
| `EInvalidEwmaAdditionalFee` | ✅ | `set_params_fee_above_max_aborts` |

### `market_oracle_config` — 1/1
| Error const | Covered | Covering test |
|---|---|---|
| `EInvalidBasisBounds` | ✅ | `set_basis_bounds_min_equal_to_max_aborts`; `set_basis_bounds_min_greater_than_max_aborts` |

### `protocol_config` — 3/5
| Error const | Covered | Covering test |
|---|---|---|
| `ETradingPaused` | ✅ | `mint_while_trading_paused_aborts` |
| `EValuationInProgress` | ✅ | `mint_during_pool_sync_aborts` |
| `EValuationNotInProgress` | ✅ | `pool_nav_outside_pool_sync_aborts` |
| `EExpiryConfigAlreadyExists` | ❌ | — |
| `EExpiryConfigNotFound` | ❌ | — |

### `strike_exposure_config` — 0/8
| Error const | Covered | Covering test |
|---|---|---|
| `ETerminalFloorExceedsLiquidationLtv` | ❌ | — |
| `EOrderBelowLiquidationThreshold` | ❌ | — |
| `EAskPriceOutOfBounds` | ❌ | — |
| `EInvalidAskBound` | ❌ | — |
| `EInvalidFeeProbability` | ❌ | — |
| `EOrderPrincipalBelowMinimum` | ❌ | — |
| `EInvalidLeverageTier` | ❌ | — |
| `EInvalidLeverage` | ❌ | — |

## Regressions vs `main` — 11 constants covered there, uncovered here

Name-level (not module-qualified). These had `expected_failure` coverage in the granular
test files deleted during suite consolidation and still exist in HEAD sources:

- `EInvalidAskBound`
- `EInvalidBaseFee`
- `EInvalidExpiryFeeMaxMultiplier`
- `EInvalidExpiryFeeWindowMs`
- `EInvalidLeverage`
- `EInvalidMaxAskPrice`
- `EInvalidMinAskPrice`
- `EInvalidMinFee`
- `EInvalidTradingLossRebateRate`
- `ELazerNegativePrice`
- `EOrderPrincipalBelowMinimum`

