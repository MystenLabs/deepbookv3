use diesel_migrations::{embed_migrations, EmbeddedMigrations};

pub mod models;
pub mod schema;

pub const MIGRATIONS: EmbeddedMigrations = embed_migrations!("migrations");

#[cfg(test)]
mod tests {
    use std::fs;

    #[test]
    fn event_ordering_migration_runs_before_predict_scope_indexes() {
        let mut names = fs::read_dir(concat!(env!("CARGO_MANIFEST_DIR"), "/migrations"))
            .expect("migrations dir")
            .map(|entry| entry.expect("dir entry").file_name().into_string().expect("utf8 dir name"))
            .collect::<Vec<_>>();
        names.sort();

        let add_event_ordering = names
            .iter()
            .position(|name| name.contains("add_event_ordering"))
            .expect("add_event_ordering migration");
        let predict_scope_indexes = names
            .iter()
            .position(|name| name.contains("oracle_predict_scope_and_api_indexes"))
            .expect("oracle_predict_scope_and_api_indexes migration");

        assert!(
            add_event_ordering < predict_scope_indexes,
            "event-ordering columns must exist before predict-scope backfill/index migration runs; got {names:?}",
        );
    }
}
