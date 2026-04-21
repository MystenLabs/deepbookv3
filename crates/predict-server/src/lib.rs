pub mod error;
mod metrics;
mod reader;
pub mod server;

#[cfg(test)]
mod tests {
    #[test]
    fn position_aggregate_sql_casts_sum_outputs_to_bigint() {
        let source = include_str!("reader.rs");

        for snippet in [
            "SUM(quantity)::bigint AS minted_quantity",
            "SUM(cost)::bigint AS total_cost",
            "SUM(quantity)::bigint AS redeemed_quantity",
            "SUM(payout)::bigint AS total_payout",
            "COALESCE(minted.minted_quantity, 0::bigint) AS minted_quantity",
            "COALESCE(redeemed.redeemed_quantity, 0::bigint) AS redeemed_quantity",
            "COALESCE(minted.total_cost, 0::bigint) AS total_cost",
            "COALESCE(redeemed.total_payout, 0::bigint) AS total_payout",
        ] {
            assert!(
                source.contains(snippet),
                "missing SQL cast snippet: {snippet}"
            );
        }
    }
}
