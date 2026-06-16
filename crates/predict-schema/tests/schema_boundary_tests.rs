use std::fs;

const ORACLE_SCHEMA_MARKERS: &[&str] = &[
    "pyth_observation",
    "block_scholes_observation",
    "oracle_source_registered",
    "oracle_bound",
    "oracle_spot_1m",
];

#[test]
fn predict_schema_does_not_define_oracle_tables() {
    let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let checked_dirs = [manifest_dir.join("migrations"), manifest_dir.join("src")];
    for dir in checked_dirs {
        assert_no_oracle_markers(&dir);
    }
}

fn assert_no_oracle_markers(dir: &std::path::Path) {
    for entry in fs::read_dir(dir).expect("read predict schema dir") {
        let path = entry.expect("read predict schema entry").path();
        if path.is_dir() {
            assert_no_oracle_markers(&path);
            continue;
        }
        let contents = fs::read_to_string(&path).expect("read predict schema file");
        for marker in ORACLE_SCHEMA_MARKERS {
            assert!(
                !contents.contains(marker),
                "predict schema file {} unexpectedly references oracle schema marker `{}`",
                path.display(),
                marker,
            );
        }
    }
}
