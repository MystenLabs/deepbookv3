# DeepBook indexer - WIP

The DeepBook Indexer uses sui-indexer-alt framework for indexing DeepBook move events. 
It processes checkpoints from the Sui blockchain and extracts event data for use in 
applications or analysis.

---

## Getting Started

### Prerequisites

Ensure that the following dependencies are installed:

- **Rust** (latest stable version recommended)
- **PostgreSQL** (version 13 or higher)

### Installation

Clone the repository:

```bash
git clone https://github.com/MystenLabs/deepbookv3.git
cd deepbookv3/crates/indexer
```

### Running the Indexer

To run the DeepBook Indexer, you need to specify the environment and which packages to index:

#### Basic Usage

```bash
DATABASE_URL="postgresql://user:pass@localhost/test_db" \
cargo run --package deepbook-indexer -- --env testnet --packages deepbook
```

#### Parameters

- `--env` (required) – Choose the SUI network environment:
  - `testnet` – For development and testing
  - `mainnet` – For production (note: margin trading not yet deployed on mainnet)

- `--packages` (required) – Specify which event types to index:
  - `deepbook` – Core DeepBook events (orders, trades, pools, governance)
  - `deepbook-margin` – Margin trading events (lending, borrowing, liquidations)
  - You can specify multiple packages: `--packages deepbook deepbook-margin`

- `--database-url` (optional) – PostgreSQL connection string. Can also be set via `DATABASE_URL` environment variable.

- `--metrics-address` (optional, default: `0.0.0.0:9184`) – Prometheus metrics endpoint address.

#### Examples

**Index only core DeepBook events on testnet:**
```bash
DATABASE_URL="postgresql://user:pass@localhost/test_db" \
cargo run --package deepbook-indexer -- --env testnet --packages deepbook
```

**Index both core and margin events on testnet:**
```bash
DATABASE_URL="postgresql://user:pass@localhost/test_db" \
cargo run --package deepbook-indexer -- --env testnet --packages deepbook deepbook-margin
```

**Index only core events on mainnet:**
```bash
DATABASE_URL="postgresql://user:pass@localhost/test_db" \
cargo run --package deepbook-indexer -- --env mainnet --packages deepbook
```

#### Important Notes

- **Margin events on mainnet**: The margin trading package is not yet deployed on mainnet, so `--packages deepbook-margin` will fail on mainnet.
- **Database migrations**: The indexer automatically runs database migrations on startup.
- **Environment variable**: You can set `DATABASE_URL` as an environment variable instead of using the `--database-url` parameter.

---