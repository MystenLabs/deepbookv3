# DeepBook Indexer Test Suite

This directory contains the test suite for the DeepBook indexer, including snapshot tests and checkpoint data for margin events.

## Overview

The test suite uses snapshot testing with real checkpoint data from Sui to verify that the indexer correctly processes and stores margin events. Tests are organized by event type and use actual checkpoint files downloaded from Sui testnet.

## Directory Structure

```
tests/
├── README.md                           # This file
├── snapshot_tests.rs                   # Main test file with snapshot tests
├── checkpoints/                        # Checkpoint data directory
│   ├── margin_manager_created/         # MarginManagerEvent checkpoints
│   ├── asset_supplied/                 # AssetSupplied event checkpoints
│   ├── margin_pool_created/            # MarginPoolCreated event checkpoints
│   ├── deepbook_pool_registered/       # DeepbookPoolRegistered event checkpoints
│   └── [other_event_types]/            # Other event type directories
└── snapshots/                          # Generated snapshot files
    ├── snapshot_tests__margin_manager_created__margin_manager_created.snap
    ├── snapshot_tests__asset_supplied__asset_supplied.snap
    └── [other_snapshots]
```

## Finding and Downloading Checkpoint Files

### 1. Using Sui GraphQL API

Sui testnet provides a GraphQL API at `https://graphql.testnet.sui.io/graphql` for querying events and finding checkpoint numbers.

#### Query for Events

```bash
curl -X POST https://graphql.testnet.sui.io/graphql \
     -H "Content-Type: application/json" \
     -d '{
          "query": "query { events(filter: { type: \"0x442d21fd044b90274934614c3c41416c83582f42eaa8feb4fecea301aa6bdd54::margin_registry::DeepbookPoolRegistered\" }) { nodes { transaction { effects { checkpoint { sequenceNumber } } } sender { address } timestamp } } }"
     }'
```

#### Get Checkpoint Information

```bash
curl -X POST https://graphql.testnet.sui.io/graphql \
     -H "Content-Type: application/json" \
     -d '{
          "query": "query { checkpoint(sequenceNumber: 248053954) { sequenceNumber timestamp } }"
     }'
```

### 2. Downloading Checkpoint Files

Once you have the checkpoint sequence number, download the checkpoint file:

```bash
# Navigate to the appropriate event directory
cd <project_root>/crates/indexer/tests/checkpoints/[event_type]

# Download the checkpoint file
curl -o [checkpoint_number].chk "https://checkpoints.testnet.sui.io/[checkpoint_number].chk"
```

#### Example: Downloading DeepbookPoolRegistered Event

```bash
# Create directory if it doesn't exist
mkdir -p <project_root>/crates/indexer/tests/checkpoints/deepbook_pool_registered

# Download checkpoint 248053954
cd <project_root>/crates/indexer/tests/checkpoints/deepbook_pool_registered
curl -o 248053954.chk "https://checkpoints.testnet.sui.io/248053954.chk"
```

### 3. Verifying Checkpoint Files

Check that the checkpoint file is downloadable and has content:

```bash
curl -I "https://checkpoints.testnet.sui.io/248053954.chk"
```

Expected response should include:
- `HTTP/2 200` (success)
- `content-length: [size]` (file size > 0)
- `content-type: application/octet-stream`

## Event Types and Package Information

### DeepBook Margin Package

- **Package ID (Testnet):** `0x442d21fd044b90274934614c3c41416c83582f42eaa8feb4fecea301aa6bdd54`
- **Network:** Sui Testnet
- **GraphQL Endpoint:** `https://graphql.testnet.sui.io/graphql`



### 3. Snapshot Management

#### Review New Snapshots
```bash
cargo insta review
```

#### Accept All Snapshots
```bash
cargo insta accept
```

#### Run All Snapshot Tests
```bash
cargo insta test
```


## Adding New Event Tests

### 1. Find Events on Testnet

Use the GraphQL API to search for events:

```bash
curl -X POST https://graphql.testnet.sui.io/graphql \
     -H "Content-Type: application/json" \
     -d '{
          "query": "query { events(filter: { type: \"[EVENT_TYPE]\" }) { nodes { transaction { effects { checkpoint { sequenceNumber } } } sender { address } timestamp } } }"
     }'
```

### 2. Download Checkpoint Files

```bash
# Create directory for the event type
mkdir -p <project_root>/crates/indexer/tests/checkpoints/[event_type]

# Download checkpoint files
cd <project_root>/crates/indexer/tests/checkpoints/[event_type]
curl -o [checkpoint_number].chk "https://checkpoints.testnet.sui.io/[checkpoint_number].chk"
```

### 3. Update Test File

Remove the `#[ignore]` attribute from the test in `snapshot_tests.rs`:

```rust
#[tokio::test]
// #[ignore] // TODO: Add checkpoint test data  <-- Remove this line
async fn [event_type]_test() -> Result<(), anyhow::Error> {
    let handler = [EventHandler]::new(DeepbookEnv::Testnet);
    data_test("[event_type]", handler, ["[event_type]"]).await?;
    Ok(())
}
```

### 4. Run the Test

```bash
cd <project_root>
PATH="/usr/lib/postgresql/16/bin:$PATH" cargo test [event_type]_test --package deepbook-indexer
```

### 5. Review and Accept Snapshot

```bash
cd <project_root>
cargo insta review
# Type 'y' to accept the snapshot
```

## Troubleshooting

### Common Issues

#### 1. `initdb` Command Not Found
```bash
# Install PostgreSQL development tools
sudo apt install -y postgresql-server-dev-all

# Ensure PATH includes PostgreSQL binaries
export PATH="/usr/lib/postgresql/16/bin:$PATH"
```

#### 2. Database Connection Issues
The tests use temporary databases, so no external database setup is required. If you see connection errors, ensure PostgreSQL development tools are properly installed.

#### 3. Checkpoint File Not Found
- Verify the checkpoint number is correct
- Check that the checkpoint file exists: `curl -I "https://checkpoints.testnet.sui.io/[checkpoint].chk"`
- Ensure the checkpoint is from the testnet (not mainnet)

#### 4. No Events Found
- Verify the event type string is correct
- Check that events exist on the testnet using GraphQL API
- Some events may not have been triggered yet on testnet

### Debug Commands

#### Check PostgreSQL Installation
```bash
which initdb
initdb --version
```

#### Verify Checkpoint Files
```bash
ls -la <project_root>/crates/indexer/tests/checkpoints/*/
```

#### Check Test Compilation
```bash
cd <project_root>
cargo check --package deepbook-indexer
```

## References

- [Sui GraphQL API Documentation](https://docs.sui.io/guides/developer/getting-started/graphql-rpc)
- [Sui Testnet Checkpoints](https://checkpoints.testnet.sui.io/)
- [Insta Snapshot Testing](https://insta.rs/)
