# Contributing to DeepBook V3 Predict

Thank you for your interest in contributing! This guide will help you get started.

## Development Setup

### Prerequisites

- [Sui CLI](https://docs.sui.io/build/install) (latest testnet version)
- [Rust](https://rustup.rs/) (stable)
- [Node.js](https://nodejs.org/) v18+ and [pnpm](https://pnpm.io/)
- [Docker](https://docs.docker.com/get-docker/) and Docker Compose
- [cargo-nextest](https://nexte.st/) for Rust tests

### Quick Start

```bash
# Clone the repo
git clone https://github.com/MystenLabs/deepbookv3.git
cd deepbookv3

# Install JS dependencies
pnpm install

# Build Move packages
sui move build

# Run Move tests
sui move test --path packages/predict --gas-limit 100000000000

# Run Rust tests
cargo nextest run -E 'package(deepbook-indexer)'

# Lint
pnpm run lint
```

## Project Structure

```
├── packages/
│   ├── predict/          # Core Move contracts (prediction markets)
│   ├── deepbook/         # DeepBook V3 core
│   └── ...
├── crates/
│   ├── predict-server/   # Rust API server
│   ├── predict-indexer/  # Sui event indexer
│   └── predict-schema/   # DB schema
├── scripts/
│   ├── services/         # Oracle feed, signal engine, alerting
│   ├── config/           # Constants and configuration
│   └── utils/            # Shared utilities
└── docker/               # Dockerfiles for all services
```

## Branch Workflow

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Make your changes
4. Run tests and linter (see below)
5. Submit a pull request against `main`

## Testing

### Move Tests

```bash
# Run all predict tests
sui move test --path packages/predict --gas-limit 100000000000

# Run specific test
sui move test --path packages/predict --filter test_name --gas-limit 100000000000
```

### Rust Tests

```bash
cargo nextest run -E 'package(deepbook-indexer)'
cargo nextest run -E 'package(deepbook-predict-server)'
```

### JavaScript/TypeScript

```bash
pnpm run lint        # Check formatting and linting
pnpm run lint:fix    # Auto-fix issues
```

## Code Style

### Move

- Follow existing patterns in `packages/predict/sources/`
- Use `bcs::to_bytes` for serialization
- Prefer `option` over default values
- Add invariant checks at the top of public functions

### Rust

- `cargo fmt` before committing
- `cargo clippy` with no warnings
- Use `anyhow::Result` for error handling
- Prefer `tracing` macros over `println!`

### TypeScript

- Prettier + ESLint are enforced in CI
- Use `.ts` extensions in imports
- Prefer `const` over `let`
- No `any` types in new code

## Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(predict): add stop-loss position sizing
fix(oracle): handle stale price fallback
docs(readme): add architecture diagram
test(predict): add boundary case tests for Black-Scholes
```

## Pull Request Guidelines

- Keep PRs focused: one feature or fix per PR
- Include tests for new functionality
- Update documentation if behavior changes
- CI must pass before merging
- At least one review required

## Reporting Issues

- Use GitHub Issues for bugs and feature requests
- Include reproduction steps for bugs
- Specify network (testnet/mainnet) and Sui CLI version

## License

By contributing, you agree that your contributions will be licensed under the Apache 2.0 License.
