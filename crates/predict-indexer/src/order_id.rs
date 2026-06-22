//! Decoder for the packed Predict order ID.
//!
//! Mirrors the u256 layout owned by `packages/predict/sources/order.move`:
//!
//! ```text
//! [200,232) quantity_lots_key = (2^32-1) - quantity_lots   (32b, complement)
//! [136,200) floor_shares_key  = (2^64-1) - floor_shares    (64b, complement)
//! [ 88,136) opened_at_ms (48b)
//! [ 64, 88) lower_boundary_index (24b)
//! [ 40, 64) higher_boundary_index (24b)
//! [  0, 40) sequence (40b)
//! ```
//!
//! `quantity_lots` and `floor_shares` are stored as complements so that larger
//! quantities/floors sort first in the liquidation book's ascending id order.
//! Any layout change in `order.move` must be mirrored here; the unit tests pin
//! the layout against the independently-derived reference ids from
//! `packages/predict/tests/order/order_tests.move`.

use move_core_types::u256::U256;

/// `constants::position_lot_size!()` in `packages/predict`.
pub const POSITION_LOT_SIZE: u64 = 10_000;

const QUANTITY_LOTS_OFFSET: u8 = 200;
const FLOOR_SHARES_OFFSET: u8 = 136;
const OPENED_AT_OFFSET: u8 = 88;
const LOWER_BOUNDARY_INDEX_OFFSET: u8 = 64;
const HIGHER_BOUNDARY_INDEX_OFFSET: u8 = 40;

const U24_MASK: u64 = (1 << 24) - 1;
const U32_MASK: u64 = (1 << 32) - 1;
const U40_MASK: u64 = (1 << 40) - 1;
const U48_MASK: u64 = (1 << 48) - 1;

/// Contract terms decoded from one packed order id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodedOrderId {
    pub quantity_lots: u64,
    /// `quantity_lots * POSITION_LOT_SIZE`, in position base units.
    pub quantity: u64,
    pub floor_shares: u64,
    pub opened_at_ms: u64,
    pub lower_boundary_index: u64,
    pub higher_boundary_index: u64,
    pub sequence: u64,
}

/// Decode the packed order id. Assumes a chain-validated id (the contract
/// rejects malformed ids at creation), so no validation is re-applied here.
pub fn decode_order_id(id: U256) -> DecodedOrderId {
    // `unchecked_as_u64` truncates to the low 64 bits, which is exactly the
    // 64-bit floor-shares field after its shift; narrower fields mask further.
    let bits = |offset: u8| (id >> offset).unchecked_as_u64();

    let quantity_lots = U32_MASK - (bits(QUANTITY_LOTS_OFFSET) & U32_MASK);
    let floor_shares = u64::MAX - bits(FLOOR_SHARES_OFFSET);

    DecodedOrderId {
        quantity_lots,
        quantity: quantity_lots * POSITION_LOT_SIZE,
        floor_shares,
        opened_at_ms: bits(OPENED_AT_OFFSET) & U48_MASK,
        lower_boundary_index: bits(LOWER_BOUNDARY_INDEX_OFFSET) & U24_MASK,
        higher_boundary_index: bits(HIGHER_BOUNDARY_INDEX_OFFSET) & U24_MASK,
        sequence: id.unchecked_as_u64() & U40_MASK,
    }
}
