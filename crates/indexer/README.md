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

To run the DeepBook Indexer, specify the PostgreSQL connection URL:

```bash
cargo run --package deepbook-indexer --bin deepbook-indexer -- --database-url=postgres://postgres:postgrespw@localhost:5432/deepbook
```
* `--database-url` – Connection string for the PostgreSQL database.

---