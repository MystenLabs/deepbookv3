use chrono::NaiveDateTime;
use deepbook_indexer::handlers::asset_supplied_handler::AssetSuppliedHandler;
use deepbook_indexer::handlers::asset_withdrawn_handler::AssetWithdrawnHandler;
use deepbook_indexer::handlers::balances_handler::BalancesHandler;
use deepbook_indexer::handlers::deep_burned_handler::DeepBurnedHandler;
use deepbook_indexer::handlers::deepbook_pool_config_updated_handler::DeepbookPoolConfigUpdatedHandler;
use deepbook_indexer::handlers::deepbook_pool_registered_handler::DeepbookPoolRegisteredHandler;
use deepbook_indexer::handlers::deepbook_pool_updated_handler::DeepbookPoolUpdatedHandler;
use deepbook_indexer::handlers::deepbook_pool_updated_registry_handler::DeepbookPoolUpdatedRegistryHandler;
use deepbook_indexer::handlers::flash_loan_handler::FlashLoanHandler;
use deepbook_indexer::handlers::interest_params_updated_handler::InterestParamsUpdatedHandler;
use deepbook_indexer::handlers::liquidation_handler::LiquidationHandler;
use deepbook_indexer::handlers::loan_borrowed_handler::LoanBorrowedHandler;
use deepbook_indexer::handlers::loan_repaid_handler::LoanRepaidHandler;
use deepbook_indexer::handlers::maintainer_cap_updated_handler::MaintainerCapUpdatedHandler;
use deepbook_indexer::handlers::margin_manager_created_handler::MarginManagerCreatedHandler;
use deepbook_indexer::handlers::margin_pool_config_updated_handler::MarginPoolConfigUpdatedHandler;
use deepbook_indexer::handlers::margin_pool_created_handler::MarginPoolCreatedHandler;
use deepbook_indexer::handlers::order_fill_handler::OrderFillHandler;
use deepbook_indexer::handlers::order_update_handler::OrderUpdateHandler;
use deepbook_indexer::handlers::pool_price_handler::PoolPriceHandler;
use deepbook_indexer::DeepbookEnv;
use deepbook_schema::MIGRATIONS;
use fastcrypto::hash::{HashFunction, Sha256};
use insta::assert_json_snapshot;
use serde_json::Value;
use sqlx::{Column, PgPool, Row, ValueRef};
use std::env;
use std::fs;
use std::path::Path;
use std::sync::Arc;
use sui_indexer_alt_framework::pipeline::concurrent::Handler;
use sui_indexer_alt_framework::pipeline::Processor;
use sui_indexer_alt_framework::store::Store;
use sui_pg_db::temp::TempDb;
use sui_pg_db::Connection;
use sui_pg_db::Db;
use sui_pg_db::DbArgs;
use sui_storage::blob::Blob;
use sui_types::full_checkpoint_content::CheckpointData;

#[tokio::test]
async fn balances_test() -> Result<(), anyhow::Error> {
    let handler = BalancesHandler::new(DeepbookEnv::Mainnet);
    data_test("balances", handler, ["balances"]).await?;
    Ok(())
}

#[tokio::test]
async fn flash_loan_test() -> Result<(), anyhow::Error> {
    let handler = FlashLoanHandler::new(DeepbookEnv::Mainnet);
    data_test("flash_loans", handler, ["flashloans"]).await?;
    Ok(())
}

#[tokio::test]
async fn order_fill_test() -> Result<(), anyhow::Error> {
    let handler = OrderFillHandler::new(DeepbookEnv::Mainnet);
    data_test("order_fill", handler, ["order_fills"]).await?;
    Ok(())
}
#[tokio::test]
async fn order_update_test() -> Result<(), anyhow::Error> {
    let handler = OrderUpdateHandler::new(DeepbookEnv::Mainnet);
    data_test("order_update", handler, ["order_updates"]).await?;
    Ok(())
}

#[tokio::test]
async fn pool_price_test() -> Result<(), anyhow::Error> {
    let handler = PoolPriceHandler::new(DeepbookEnv::Mainnet);
    data_test("pool_price", handler, ["pool_prices"]).await?;
    Ok(())
}

#[tokio::test]
async fn deep_burned_test() -> Result<(), anyhow::Error> {
    let handler = DeepBurnedHandler::new(DeepbookEnv::Mainnet);
    data_test("deep_burned", handler, ["deep_burned"]).await?;
    Ok(())
}

#[tokio::test]
async fn balances_indirect_interaction_test() -> Result<(), anyhow::Error> {
    // Test that balance events from transactions that interact with DeepBook
    // indirectly (through other protocols) are still captured
    let handler = BalancesHandler::new(DeepbookEnv::Mainnet);
    data_test("balances_indirect", handler, ["balances"]).await?;
    Ok(())
}

// Margin Manager Events Tests
#[tokio::test]
async fn margin_manager_created_test() -> Result<(), anyhow::Error> {
    let handler = MarginManagerCreatedHandler::new(DeepbookEnv::Testnet);
    data_test(
        "margin_manager_created",
        handler,
        ["margin_manager_created"],
    )
    .await?;
    Ok(())
}

#[tokio::test]
async fn loan_borrowed_test() -> Result<(), anyhow::Error> {
    let handler = LoanBorrowedHandler::new(DeepbookEnv::Testnet);
    data_test("loan_borrowed", handler, ["loan_borrowed"]).await?;
    Ok(())
}

#[tokio::test]
#[ignore] // TODO: Add checkpoint test data
async fn loan_repaid_test() -> Result<(), anyhow::Error> {
    let handler = LoanRepaidHandler::new(DeepbookEnv::Testnet);
    data_test("loan_repaid", handler, ["loan_repaid"]).await?;
    Ok(())
}

#[tokio::test]
#[ignore] // TODO: Add checkpoint test data
async fn liquidation_test() -> Result<(), anyhow::Error> {
    let handler = LiquidationHandler::new(DeepbookEnv::Testnet);
    data_test("liquidation", handler, ["liquidation"]).await?;
    Ok(())
}

// Margin Pool Operations Events Tests
#[tokio::test]
async fn asset_supplied_test() -> Result<(), anyhow::Error> {
    let handler = AssetSuppliedHandler::new(DeepbookEnv::Testnet);
    data_test("asset_supplied", handler, ["asset_supplied"]).await?;
    Ok(())
}

#[tokio::test]
#[ignore] // TODO: Add checkpoint test data
async fn asset_withdrawn_test() -> Result<(), anyhow::Error> {
    let handler = AssetWithdrawnHandler::new(DeepbookEnv::Testnet);
    data_test("asset_withdrawn", handler, ["asset_withdrawn"]).await?;
    Ok(())
}

// Margin Pool Admin Events Tests
#[tokio::test]
async fn margin_pool_created_test() -> Result<(), anyhow::Error> {
    let handler = MarginPoolCreatedHandler::new(DeepbookEnv::Testnet);
    data_test("margin_pool_created", handler, ["margin_pool_created"]).await?;
    Ok(())
}

#[tokio::test]
async fn deepbook_pool_updated_test() -> Result<(), anyhow::Error> {
    let handler = DeepbookPoolUpdatedHandler::new(DeepbookEnv::Testnet);
    data_test("deepbook_pool_updated", handler, ["deepbook_pool_updated"]).await?;
    Ok(())
}

#[tokio::test]
#[ignore] // TODO: Add checkpoint test data
async fn interest_params_updated_test() -> Result<(), anyhow::Error> {
    let handler = InterestParamsUpdatedHandler::new(DeepbookEnv::Testnet);
    data_test(
        "interest_params_updated",
        handler,
        ["interest_params_updated"],
    )
    .await?;
    Ok(())
}

#[tokio::test]
#[ignore] // TODO: Add checkpoint test data
async fn margin_pool_config_updated_test() -> Result<(), anyhow::Error> {
    let handler = MarginPoolConfigUpdatedHandler::new(DeepbookEnv::Testnet);
    data_test(
        "margin_pool_config_updated",
        handler,
        ["margin_pool_config_updated"],
    )
    .await?;
    Ok(())
}

// Margin Registry Events Tests
#[tokio::test]
async fn maintainer_cap_updated_test() -> Result<(), anyhow::Error> {
    let handler = MaintainerCapUpdatedHandler::new(DeepbookEnv::Testnet);
    data_test(
        "maintainer_cap_updated",
        handler,
        ["maintainer_cap_updated"],
    )
    .await?;
    Ok(())
}

#[tokio::test]
async fn deepbook_pool_registered_test() -> Result<(), anyhow::Error> {
    let handler = DeepbookPoolRegisteredHandler::new(DeepbookEnv::Testnet);
    data_test(
        "deepbook_pool_registered",
        handler,
        ["deepbook_pool_registered"],
    )
    .await?;
    Ok(())
}

#[tokio::test]
async fn deepbook_pool_updated_registry_test() -> Result<(), anyhow::Error> {
    let handler = DeepbookPoolUpdatedRegistryHandler::new(DeepbookEnv::Testnet);
    data_test(
        "deepbook_pool_updated_registry",
        handler,
        ["deepbook_pool_updated_registry"],
    )
    .await?;
    Ok(())
}

#[tokio::test]
#[ignore] // TODO: Add checkpoint test data
async fn deepbook_pool_config_updated_test() -> Result<(), anyhow::Error> {
    let handler = DeepbookPoolConfigUpdatedHandler::new(DeepbookEnv::Testnet);
    data_test(
        "deepbook_pool_config_updated",
        handler,
        ["deepbook_pool_config_updated"],
    )
    .await?;
    Ok(())
}

async fn data_test<H, I>(
    test_name: &str,
    handler: H,
    tables_to_check: I,
) -> Result<(), anyhow::Error>
where
    I: IntoIterator<Item = &'static str>,
    H: Handler + Processor,
    for<'a> H::Store: Store<Connection<'a> = Connection<'a>>,
{
    // Set up database URL based on environment
    // IMPORTANT: Keep temp_db in scope for the entire test, otherwise it gets cleaned up
    let (temp_db_opt, url) =
        if env::var("USE_REAL_DB").unwrap_or_else(|_| "false".to_string()) == "true" {
            // Use REAL PostgreSQL database - DATABASE_URL must be provided
            let database_url = env::var("DATABASE_URL")
                .expect("DATABASE_URL environment variable must be set when USE_REAL_DB=true");
            (None, database_url)
        } else {
            // Use MOCK database (existing behavior)
            let temp_db = TempDb::new()?;
            let url = temp_db.database().url().to_string();
            (Some(temp_db), url)
        };

    let db = Arc::new(Db::for_write(url.parse()?, DbArgs::default()).await?);

    // Only run migrations if using mock database (real DB already has migrations)
    if temp_db_opt.is_some() {
        db.run_migrations(Some(&MIGRATIONS)).await?;
    }

    let mut conn = db.connect().await?;

    // Test setup based on provided test_name
    let test_path = Path::new("tests/checkpoints").join(test_name);
    let checkpoints = get_checkpoints_in_folder(&test_path)?;

    // Run pipeline for each checkpoint
    for checkpoint in checkpoints {
        run_pipeline(&handler, &checkpoint, &mut conn).await?;
    }

    // Check results by comparing database tables with snapshots
    for table in tables_to_check {
        let rows = read_table(&table, &url).await?;

        // Only create snapshots if using mock database
        if temp_db_opt.is_some() {
            assert_json_snapshot!(format!("{test_name}__{table}"), rows);
        }
    }

    Ok(())
}

async fn run_pipeline<'c, T: Handler + Processor, P: AsRef<Path>>(
    handler: &T,
    path: P,
    conn: &mut Connection<'c>,
) -> Result<(), anyhow::Error>
where
    T::Store: Store<Connection<'c> = Connection<'c>>,
{
    let bytes = fs::read(path)?;
    let cp = Blob::from_bytes::<CheckpointData>(&bytes)?;
    let result = handler.process(&Arc::new(cp))?;
    T::commit(&result, conn).await?;
    Ok(())
}

/// Read the entire table from database as json value.
/// note: bytea values will be hashed to reduce output size.
async fn read_table(table_name: &str, db_url: &str) -> Result<Vec<Value>, anyhow::Error> {
    let pool = PgPool::connect(db_url).await?;
    let rows = sqlx::query(&format!("SELECT * FROM {table_name}"))
        .fetch_all(&pool)
        .await?;

    // To json
    Ok(rows
        .iter()
        .map(|row| {
            let mut obj = serde_json::Map::new();

            for column in row.columns() {
                let column_name = column.name();

                // timestamp is the insert time in deepbook DB, hardcoding it to a fix value.
                if column_name == "timestamp" {
                    obj.insert(
                        column_name.to_string(),
                        Value::String("1970-01-01 00:00:00.000000".to_string()),
                    );
                    continue;
                }

                let value = if let Ok(v) = row.try_get::<String, _>(column_name) {
                    Value::String(v)
                } else if let Ok(v) = row.try_get::<i32, _>(column_name) {
                    Value::String(v.to_string())
                } else if let Ok(v) = row.try_get::<i64, _>(column_name) {
                    Value::String(v.to_string())
                } else if let Ok(v) = row.try_get::<bool, _>(column_name) {
                    Value::Bool(v)
                } else if let Ok(v) = row.try_get::<Value, _>(column_name) {
                    v
                } else if let Ok(v) = row.try_get::<Vec<u8>, _>(column_name) {
                    // hash bytea contents
                    let mut hash_function = Sha256::default();
                    hash_function.update(v);
                    let digest2 = hash_function.finalize();
                    Value::String(digest2.to_string())
                } else if let Ok(v) = row.try_get::<NaiveDateTime, _>(column_name) {
                    Value::String(v.to_string())
                } else if let Ok(true) = row.try_get_raw(column_name).map(|v| v.is_null()) {
                    Value::Null
                } else {
                    panic!(
                        "Cannot parse DB value to json, type: {:?}, column: {column_name}",
                        row.try_get_raw(column_name)
                            .map(|v| v.type_info().to_string())
                    )
                };
                obj.insert(column_name.to_string(), value);
            }

            Value::Object(obj)
        })
        .collect())
}

fn get_checkpoints_in_folder(folder: &Path) -> Result<Vec<String>, anyhow::Error> {
    let mut files = Vec::new();

    // Read the directory
    for entry in fs::read_dir(folder)? {
        let entry = entry?;
        let path = entry.path();

        // Check if it's a file and ends with ".chk"
        if path.is_file() && path.extension().and_then(|s| s.to_str()) == Some("chk") {
            files.push(path.display().to_string());
        }
    }

    Ok(files)
}
