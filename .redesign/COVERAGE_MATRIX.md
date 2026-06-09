# Predict Error-Constant Coverage Matrix

> **Audit artifact + Phase-2 worklist.** Every `const E*` declared in
> `packages/predict/sources/**` and `packages/predict_math/sources/**`, whether an
> `expected_failure` test triggers it, and the covering test fn. Module-qualified.

**Regenerate:** `python3 .redesign/gen_coverage_matrix.py` (from the repo root).

## Summary — 60/157 covered, 97 uncovered

| Priority band | Uncovered |
|---|---|
| P0 | 4 |
| P1 | 56 |
| P2 | 14 |
| P3 | 23 |

Priority bands:
- **P0** — `expiry_market` public-flow gates + the invariant-level hot-flow pass.
- **P1** — economic / lifecycle / auth error paths: oracle, pyth, pricing, plp, incentive, order, registry, manager.
- **P2** — strike-index internals + accounting leaves + math.
- **P3** — config-bounds envelopes (trivial-to-trigger, lowest blast radius).

A constant that is a genuinely-unreachable defensive invariant is marked
`DEFENSIVE` with the reason — no fabricated path, no test-only source seam added to reach it.

## P0

### `expiry_market` — 3/7
| Error const | Covered | Covering test |
|---|---|---|
| `EWrongMarketOracle` | ✅ | `redeem_with_wrong_oracle_aborts` |
| `EWrongPythSource` | ❌ | — |
| `EValuationExceedsCash` | ❌ | — |
| `EPackageVersionDisabled` | ❌ | — |
| `EMintPaused` | ❌ | — |
| `EFullCloseRequired` | ✅ | `redeem_settled_partial_close_aborts` |
| `EProofRequiredForLiveRedeem` | ✅ | `redeem_settled_on_live_order_aborts` |

## P1

### `builder_code` — 0/1
| Error const | Covered | Covering test |
|---|---|---|
| `ENotOwner` | ❌ | — |

### `incentive` — 0/4
| Error const | Covered | Covering test |
|---|---|---|
| `EZeroDeposit` | ❌ | — |
| `EZeroStreamDuration` | ❌ | — |
| `EStreamDurationTooLong` | ❌ | — |
| `EFeedMismatch` | ❌ | — |

### `market_oracle` — 3/16
| Error const | Covered | Covering test |
|---|---|---|
| `EInvalidMarketOracleCap` | ❌ | — |
| `EMarketNotActive` | ✅ | `mint_after_expiry_before_settlement_aborts` |
| `EMarketSettled` | ❌ | — |
| `ESpotDeviationTooLarge` | ❌ | — |
| `EBasisDeviationTooLarge` | ❌ | — |
| `EBasisOutOfRange` | ❌ | — |
| `EZeroSpot` | ❌ | — |
| `EZeroForward` | ❌ | — |
| `EStalePriceSourceUpdate` | ❌ | — |
| `EStaleSVISourceUpdate` | ❌ | — |
| `EWrongPythSource` | ❌ | — |
| `EFuturePriceSourceUpdate` | ❌ | — |
| `EFutureSVISourceUpdate` | ❌ | — |
| `EInvalidSviRho` | ✅ | `assert_valid_svi_rejects_rho_magnitude_above_one` |
| `EInvalidSviSigma` | ✅ | `assert_valid_svi_rejects_sigma_above_max`; `assert_valid_svi_rejects_sigma_below_min` |
| `EPackageVersionDisabled` | ❌ | — |

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

### `plp` — 0/11
| Error const | Covered | Covering test |
|---|---|---|
| `EExpiryMarketNotActive` | ❌ | — |
| `EWrongPoolVault` | ❌ | — |
| `EExpiryMarketAlreadySynced` | ❌ | — |
| `EMissingExpirySync` | ❌ | — |
| `EZeroSupply` | ❌ | — |
| `EZeroWithdraw` | ❌ | — |
| `EInvalidInitialSupply` | ❌ | — |
| `EZeroShares` | ❌ | — |
| `EZeroPoolValue` | ❌ | — |
| `EPackageVersionDisabled` | ❌ | — |
| `ENoPlpHolders` | ❌ | — |

### `predict_manager` — 7/8
| Error const | Covered | Covering test |
|---|---|---|
| `EInsufficientPosition` | ✅ | `remove_position_that_does_not_exist_aborts` |
| `ENotOwner` | ✅ | `assert_owner_aborts_for_non_owner`; `non_owner_cannot_mint_trade_cap`; `unset_builder_code_by_non_owner_aborts` |
| `EInvalidProof` | ✅ | `cross_manager_proof_validation_aborts` |
| `EInvalidCap` | ✅ | `revoked_trade_cap_cannot_generate_proof` |
| `EMaxCapsReached` | ❌ | — |
| `ECapNotInList` | ✅ | `revoking_unknown_cap_aborts` |
| `EExpirySummaryHasOpenPositions` | ✅ | `resolve_expiry_summary_with_open_positions_aborts` |
| `EPositionAlreadyExists` | ✅ | `add_position_duplicate_aborts` |

### `pricing` — 0/9
| Error const | Covered | Covering test |
|---|---|---|
| `EZeroForward` | ❌ | — |
| `ECannotBeNegative` | ❌ | — |
| `EZeroVariance` | ❌ | — |
| `EInvalidRange` | ❌ | — |
| `EInvalidCurveRange` | ❌ | — |
| `EBlockScholesPriceStale` | ❌ | — |
| `EBlockScholesSVIStale` | ❌ | — |
| `EInvalidStrikeRatio` | ❌ | — |
| `EPythSpotStale` | ❌ | — |

### `pyth_source` — 0/7
| Error const | Covered | Covering test |
|---|---|---|
| `EStaleSourceUpdate` | ❌ | — |
| `EZeroSpot` | ❌ | — |
| `EFutureSourceUpdate` | ❌ | — |
| `EPackageVersionDisabled` | ❌ | — |
| `ELazerFeedNotFound` | ❌ | — |
| `ELazerPriceUnavailable` | ❌ | — |
| `ELazerNegativePrice` | ❌ | — |

### `registry` — 3/11
| Error const | Covered | Covering test |
|---|---|---|
| `EFeedIdMismatch` | ❌ | — |
| `EPythSourceAlreadyCreated` | ✅ | `create_pyth_source_duplicate_feed_aborts` |
| `EInvalidExpiry` | ❌ | — |
| `EExpiryMarketAlreadyCreated` | ❌ | — |
| `EPauseCapNotValid` | ❌ | — |
| `EPackageVersionDisabled` | ✅ | `create_pyth_source_with_current_version_disabled_aborts` |
| `EVersionAlreadyEnabled` | ❌ | — |
| `EVersionNotEnabled` | ❌ | — |
| `ECannotDisableLastVersion` | ❌ | — |
| `EPythFeedNotRegistered` | ✅ | `set_pyth_feed_tick_size_unknown_feed_aborts` |
| `EIncentiveAssetNotConfigured` | ❌ | — |

### `settlement_state` — 0/2
| Error const | Covered | Covering test |
|---|---|---|
| `EMarketNotSettled` | ❌ | — |
| `EInvalidSettlementTimestamp` | ❌ | — |

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

### `liquidation_book` — 0/4
| Error const | Covered | Covering test |
|---|---|---|
| `EActiveOrderAlreadyExists` | ❌ | — |
| `EActiveOrderNotFound` | ❌ | — |
| `ELiquidatedOrderAlreadyExists` | ❌ | — |
| `ELiquidatedOrderNotFound` | ❌ | — |

### `math` — 4/4
| Error const | Covered | Covering test |
|---|---|---|
| `EInputZero` | ✅ | `ln_of_zero_aborts` |
| `EInvalidPrecision` | ✅ | `sqrt_precision_above_float_aborts`; `sqrt_precision_zero_aborts` |
| `EPow10ExponentTooLarge` | ✅ | `pow10_nineteen_aborts` |
| `EExpOverflow` | ✅ | `exp_above_u64_fit_bound_aborts`; `exp_just_above_u64_fit_bound_aborts` |

### `pool_accounting` — 4/7
| Error const | Covered | Covering test |
|---|---|---|
| `EUnknownRegisteredExpiry` | ✅ | `unknown_expiry_flow_read_aborts` |
| `ERegisteredExpiryAlreadyExists` | ✅ | `register_expiry_twice_aborts` |
| `EMaxExpiryFundingExceeded` | ❌ | — |
| `ETerminalAccountingStarted` | ❌ | — |
| `EMaxActiveExpiryMarkets` | ✅ | `register_expiry_above_active_limit_aborts` |
| `EInsufficientActiveAllocationBacking` | ✅ | `register_expiry_without_idle_backing_aborts` |
| `EInvalidActiveFundingAggregate` | ❌ | — |

### `strike_exposure` — 0/2
| Error const | Covered | Covering test |
|---|---|---|
| `ESettledLiabilityNotMaterialized` | ❌ | — |
| `EInvalidCloseQuantity` | ❌ | — |

### `strike_grid` — 4/5
| Error const | Covered | Covering test |
|---|---|---|
| `EInvalidTickSize` | ❌ | — |
| `EInvalidStrikeGrid` | ✅ | `insert_finite_above_grid_aborts`; `insert_finite_below_grid_aborts`; `insert_full_open_range_aborts`; `insert_lower_above_higher_aborts`; `insert_lower_equal_higher_aborts`; `insert_unaligned_strike_aborts` |
| `EOracleTickSizeTooSmallForSpot` | ✅ | `new_centered_aborts_when_tick_size_too_small_for_spot` |
| `EInvalidOracleSpot` | ✅ | `new_centered_aborts_without_spot` |
| `EOracleTickSizeTooLargeForSpot` | ✅ | `new_centered_aborts_when_tick_size_too_large_for_spot` |

### `strike_nav_matrix` — 0/4
| Error const | Covered | Covering test |
|---|---|---|
| `EInsufficientQuantity` | ❌ | — |
| `EInvalidCurveRange` | ❌ | — |
| `EZeroQuantity` | ❌ | — |
| `EInvalidPreallocatedTicks` | ❌ | — |

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

### `protocol_config` — 0/5
| Error const | Covered | Covering test |
|---|---|---|
| `ETradingPaused` | ❌ | — |
| `EValuationInProgress` | ❌ | — |
| `EValuationNotInProgress` | ❌ | — |
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

## Regressions vs `main` — 47 constants covered there, uncovered here

Name-level (not module-qualified). These had `expected_failure` coverage in the granular
test files deleted during suite consolidation and still exist in HEAD sources:

- `EBasisDeviationTooLarge`
- `EBasisOutOfRange`
- `ECannotDisableLastVersion`
- `EExpiryMarketAlreadySynced`
- `EFeedMismatch`
- `EFuturePriceSourceUpdate`
- `EFutureSVISourceUpdate`
- `EIncentiveAssetNotConfigured`
- `EInsufficientQuantity`
- `EInvalidAskBound`
- `EInvalidBaseFee`
- `EInvalidCurveRange`
- `EInvalidExpiryFeeMaxMultiplier`
- `EInvalidExpiryFeeWindowMs`
- `EInvalidLeverage`
- `EInvalidMarketOracleCap`
- `EInvalidMaxAskPrice`
- `EInvalidMinAskPrice`
- `EInvalidMinFee`
- `EInvalidPreallocatedTicks`
- `EInvalidTradingLossRebateRate`
- `ELazerNegativePrice`
- `EMarketNotSettled`
- `EMarketSettled`
- `EMaxExpiryFundingExceeded`
- `EMissingExpirySync`
- `ENoPlpHolders`
- `EOrderPrincipalBelowMinimum`
- `EPauseCapNotValid`
- `EPythSpotStale`
- `ESettledLiabilityNotMaterialized`
- `ESpotDeviationTooLarge`
- `EStalePriceSourceUpdate`
- `EStaleSVISourceUpdate`
- `EStreamDurationTooLong`
- `ETerminalAccountingStarted`
- `ETradingPaused`
- `EValuationInProgress`
- `EValuationNotInProgress`
- `EVersionAlreadyEnabled`
- `EVersionNotEnabled`
- `EWrongPythSource`
- `EZeroDeposit`
- `EZeroForward`
- `EZeroQuantity`
- `EZeroSpot`
- `EZeroStreamDuration`

