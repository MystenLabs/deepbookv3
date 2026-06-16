use std::fs;

const ORACLE_SCHEMA_MARKERS: &[&str] = &[
    "pyth_observation",
    "block_scholes_observation",
    "oracle_source_registered",
    "oracle_bound",
    "oracle_spot_1m",
];

#[test]
fn oracle_migrations_create_oracle_tables() {
    let migrations_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations");
    let mut migration_sql = String::new();
    for entry in fs::read_dir(migrations_dir).expect("read oracle migrations dir") {
        let up_sql = entry.expect("read migration entry").path().join("up.sql");
        if up_sql.exists() {
            migration_sql.push_str(&fs::read_to_string(&up_sql).expect("read migration up.sql"));
        }
    }

    for marker in ORACLE_SCHEMA_MARKERS {
        assert!(
            migration_sql.contains(marker),
            "oracle migrations should define oracle schema marker `{}`",
            marker,
        );
    }
}
