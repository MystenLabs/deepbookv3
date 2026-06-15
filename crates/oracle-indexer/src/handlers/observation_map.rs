//! Shared mapping for the four generic observation handlers.
//!
//! The two observation event names (`ObservationRecorded` from `update()`,
//! `ObservationInserted` from `insert_at()`) carry the same payload shape, so
//! the recorded/inserted handlers share one `map_*` per payload, parameterized
//! by an `is_exact` flag (false for recorded/live, true for inserted/exact-ms).
//!
//! The events are cross-package generics
//! (`oracle_lane::ObservationRecorded<oracle_lane::OracleRead<pyth_feed::RawSpot>>`).
//! Event-name matching alone cannot tell RawSpot from RawSurface, so the
//! handlers call [`payload_is_pyth_spot`] / [`payload_is_bs_surface`], which
//! walk `ev.type_.type_params[0]` (the `OracleRead<...>` StructTag) then its
//! `.type_params[0]` (the payload StructTag) and check `(module, name)`.

use crate::meta::OracleEventMeta;
use crate::models::{BlockScholesObservationEvent, PythObservationEvent, I64};
use bigdecimal::BigDecimal;
use move_core_types::language_storage::{StructTag, TypeTag};
use predict_schema::models::{BlockScholesObservation as BsRow, PythObservation as PythRow};

/// Walk one generic step into a `StructTag`'s first type parameter, returning
/// the inner `StructTag` when it is a struct type.
fn first_struct_type_param(struct_tag: &StructTag) -> Option<&StructTag> {
    match struct_tag.type_params.first() {
        Some(TypeTag::Struct(inner)) => Some(inner.as_ref()),
        _ => None,
    }
}

/// The payload `StructTag` of an observation event type, i.e.
/// `OracleRead<Payload>`'s `Payload`. `event_type` is `Observation<OracleRead<Payload>>`,
/// so this descends two generic levels.
fn payload_struct_tag(event_type: &StructTag) -> Option<&StructTag> {
    let oracle_read = first_struct_type_param(event_type)?;
    first_struct_type_param(oracle_read)
}

/// Whether the event's concrete payload is `pyth_feed::RawSpot`.
pub fn payload_is_pyth_spot(event_type: &StructTag) -> bool {
    payload_struct_tag(event_type)
        .map(|p| (p.module.as_str(), p.name.as_str()) == ("pyth_feed", "RawSpot"))
        .unwrap_or(false)
}

/// Whether the event's concrete payload is `block_scholes_feed::RawSurface`.
pub fn payload_is_bs_surface(event_type: &StructTag) -> bool {
    payload_struct_tag(event_type)
        .map(|p| (p.module.as_str(), p.name.as_str()) == ("block_scholes_feed", "RawSurface"))
        .unwrap_or(false)
}

/// Collapse `I64 { magnitude, is_negative }` into one signed `BigDecimal`.
fn signed(value: &I64) -> BigDecimal {
    let magnitude = BigDecimal::from(value.magnitude);
    if value.is_negative {
        -magnitude
    } else {
        magnitude
    }
}

/// Map a decoded Pyth observation into a `pyth_observation` row.
pub fn map_pyth(ev: &PythObservationEvent, meta: &OracleEventMeta, is_exact: bool) -> PythRow {
    let raw = &ev.observation.value;
    PythRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        propbook_oracle_id: ev.propbook_oracle_id.to_string(),
        // u32 Pyth source id, fits in i64.
        pyth_source_id: raw.pyth_source_id as i64,
        price_magnitude: BigDecimal::from(raw.price_magnitude),
        price_is_negative: raw.price_is_negative,
        // u16 exponent magnitude, fits in i32.
        exponent_magnitude: raw.exponent_magnitude as i32,
        exponent_is_negative: raw.exponent_is_negative,
        source_timestamp_us: BigDecimal::from(raw.source_timestamp_us),
        normalized_spot: normalize_raw_spot(raw),
        source_timestamp_ms: ev.observation.source_timestamp_ms as i64,
        update_timestamp_ms: ev.observation.update_timestamp_ms as i64,
        is_exact,
    }
}

/// Map a decoded Block Scholes observation into a `block_scholes_observation`
/// row.
pub fn map_bs(ev: &BlockScholesObservationEvent, meta: &OracleEventMeta, is_exact: bool) -> BsRow {
    let raw = &ev.observation.value;
    let (normalized_spot, normalized_forward) = if raw.spot == 0 || raw.forward == 0 {
        (None, None)
    } else {
        (
            Some(BigDecimal::from(raw.spot)),
            Some(BigDecimal::from(raw.forward)),
        )
    };
    BsRow {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        propbook_oracle_id: ev.propbook_oracle_id.to_string(),
        // u32 BS source id, fits in i64.
        bs_source_id: raw.bs_source_id as i64,
        // unix ms expiry.
        expiry_ms: raw.expiry_ms as i64,
        spot: BigDecimal::from(raw.spot),
        forward: BigDecimal::from(raw.forward),
        svi_a: BigDecimal::from(raw.svi.a),
        svi_b: BigDecimal::from(raw.svi.b),
        svi_rho: signed(&raw.svi.rho),
        svi_m: signed(&raw.svi.m),
        svi_sigma: BigDecimal::from(raw.svi.sigma),
        normalized_spot,
        normalized_forward,
        source_timestamp_ms: ev.observation.source_timestamp_ms as i64,
        update_timestamp_ms: ev.observation.update_timestamp_ms as i64,
        is_exact,
    }
}

/// 1e9 price scaling target — `propbook::constants::float_scaling_decimals!()`.
const FLOAT_SCALING_DECIMALS: u32 = 9;

/// `math::pow10(shift)` for `shift <= 18` (10^18 < u64::MAX). Callers must guard
/// `shift <= 18` like the Move code does.
fn pow10(shift: u32) -> u64 {
    10u64.pow(shift)
}

/// `magnitude * 10^shift`, `None` on `shift > 18` or u64 overflow. Replicates
/// `pyth_feed::scale_up`.
fn scale_up(magnitude: u64, shift: u32) -> Option<u64> {
    if shift > 18 {
        return None;
    }
    let scaled = (magnitude as u128) * (pow10(shift) as u128);
    if scaled > u64::MAX as u128 {
        None
    } else {
        Some(scaled as u64)
    }
}

/// Off-chain replication of `pyth_feed::normalize_raw_spot`: derive the 1e9
/// normalized spot from the source-native Pyth fields. Returns `None` for a
/// negative price, an out-of-range exponent shift, or a zero result — exactly
/// the cases where the on-chain getter returns `None`.
fn normalize_raw_spot(raw: &crate::models::RawSpot) -> Option<BigDecimal> {
    if raw.price_is_negative {
        return None;
    }

    let target = FLOAT_SCALING_DECIMALS;
    let exp_mag = raw.exponent_magnitude as u32;

    let normalized = if raw.exponent_is_negative {
        if exp_mag <= target {
            scale_up(raw.price_magnitude, target - exp_mag)?
        } else {
            // Round down when the source has finer precision than the 1e9 scale.
            let shift = exp_mag - target;
            if shift > 18 {
                return None;
            }
            raw.price_magnitude / pow10(shift)
        }
    } else {
        scale_up(raw.price_magnitude, target + exp_mag)?
    };

    if normalized == 0 {
        None
    } else {
        Some(BigDecimal::from(normalized))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{
        BlockScholesObservationEvent, OracleReadRawSurface, RawSpot, RawSurface, SVIParams,
    };
    use sui_types::base_types::ObjectID;

    fn raw(
        price_magnitude: u64,
        price_is_negative: bool,
        exponent_magnitude: u16,
        exponent_is_negative: bool,
    ) -> RawSpot {
        RawSpot {
            pyth_source_id: 1,
            price_magnitude,
            price_is_negative,
            exponent_magnitude,
            exponent_is_negative,
            source_timestamp_us: 0,
        }
    }

    #[test]
    fn normalize_negative_exponent_scales_up() {
        // price 12345 with exponent -5: true value 0.12345, in 1e9 scaling is
        // 0.12345 * 1e9 = 123_450_000. Computed as 12345 * 10^(9-5) = 12345 * 10^4.
        let got = normalize_raw_spot(&raw(12_345, false, 5, true));
        assert_eq!(got, Some(BigDecimal::from(123_450_000u64)));
    }

    #[test]
    fn normalize_finer_than_target_rounds_down() {
        // exponent -12 is finer than the 1e9 target (-9): shift = 12 - 9 = 3, so
        // 1_234_567 / 10^3 = 1234 (integer division rounds down).
        let got = normalize_raw_spot(&raw(1_234_567, false, 12, true));
        assert_eq!(got, Some(BigDecimal::from(1_234u64)));
    }

    #[test]
    fn normalize_positive_exponent_scales_up() {
        // price 7 with exponent +2: true value 700, in 1e9 scaling is
        // 7 * 10^(9+2) = 7 * 10^11 = 700_000_000_000.
        let got = normalize_raw_spot(&raw(7, false, 2, false));
        assert_eq!(got, Some(BigDecimal::from(700_000_000_000u64)));
    }

    #[test]
    fn normalize_negative_price_is_none() {
        assert_eq!(normalize_raw_spot(&raw(12_345, true, 5, true)), None);
    }

    #[test]
    fn normalize_zero_result_is_none() {
        // price 5 with exponent -12: shift = 3, 5 / 1000 = 0 -> None.
        assert_eq!(normalize_raw_spot(&raw(5, false, 12, true)), None);
    }

    #[test]
    fn normalize_overflow_shift_is_none() {
        // exponent +20 with positive sign: target + exp = 29 > 18 -> None.
        assert_eq!(normalize_raw_spot(&raw(1, false, 20, false)), None);
    }

    #[test]
    fn map_bs_passes_through_amounts_and_collapses_signed_svi() {
        // Non-zero spot/forward: normalized passthrough is Some(spot)/Some(forward)
        // (the BS feed stores spot/forward already in 1e9 scaling, so the mapper
        // does not rescale — it only drops the zero sentinels). rho is negative,
        // m is positive, so `signed` collapses them to -3 and +4.
        let ev = BlockScholesObservationEvent {
            propbook_oracle_id: ObjectID::ZERO,
            observation: OracleReadRawSurface {
                source_timestamp_ms: 1_700_000_001_000,
                update_timestamp_ms: 1_700_000_002_000,
                value: RawSurface {
                    bs_source_id: 7,
                    expiry_ms: 1_800_000_000_000,
                    spot: 100_000_000_000,
                    forward: 105_000_000_000,
                    svi: SVIParams {
                        a: 1,
                        b: 2,
                        rho: I64 {
                            magnitude: 3,
                            is_negative: true,
                        },
                        m: I64 {
                            magnitude: 4,
                            is_negative: false,
                        },
                        sigma: 5,
                    },
                },
            },
        };
        let meta = OracleEventMeta::for_test("0xdig", "0xsender", 42, 3, 9_999, 1, "0xpkg");

        let row = map_bs(&ev, &meta, true);

        assert_eq!(row.bs_source_id, 7);
        assert_eq!(row.expiry_ms, 1_800_000_000_000);
        assert_eq!(row.spot, BigDecimal::from(100_000_000_000u64));
        assert_eq!(row.forward, BigDecimal::from(105_000_000_000u64));
        assert_eq!(
            row.normalized_spot,
            Some(BigDecimal::from(100_000_000_000u64))
        );
        assert_eq!(
            row.normalized_forward,
            Some(BigDecimal::from(105_000_000_000u64))
        );
        assert_eq!(row.svi_a, BigDecimal::from(1u64));
        assert_eq!(row.svi_b, BigDecimal::from(2u64));
        assert_eq!(row.svi_rho, BigDecimal::from(-3i64));
        assert_eq!(row.svi_m, BigDecimal::from(4i64));
        assert_eq!(row.svi_sigma, BigDecimal::from(5u64));
        assert_eq!(row.source_timestamp_ms, 1_700_000_001_000);
        assert_eq!(row.update_timestamp_ms, 1_700_000_002_000);
        assert!(row.is_exact);
    }
}
