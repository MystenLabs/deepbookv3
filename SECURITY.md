# Security Policy

## Overview

This document describes the security measures implemented in the DeepBook V3 Predict system.

## Key Management

### Private Keys

- **Never** hardcode private keys in source code
- Use environment variables via `.env` files (excluded from git via `.gitignore`)
- Use the Sui Keystore for local development (`~/.sui/sui.keystore`)
- In production, use a secrets manager (AWS Secrets Manager, HashiCorp Vault, etc.)

### Key Rotation

Rotate keys immediately if:
- A `.env` file is accidentally committed
- A developer leaves the team
- Suspicious activity is detected

**Rotation steps:**

```bash
# 1. Generate new keypair
sui client new-address ed25519

# 2. Fund the new address on testnet
sui client faucet

# 3. Update .env with the new private key
# PRIVATE_KEY=<new_key>

# 4. Transfer any remaining assets from old address
sui client transfer-sui --amount <balance> --to <new_address> --gas-budget 10000000

# 5. Update on-chain capabilities if needed (oracle cap, admin cap)
# This requires calling the appropriate Move functions with the new address
```

### Environment Variables

Required secrets (NEVER commit these):

```env
PRIVATE_KEY=           # Sui private key (hex)
PACKAGE_ID=            # Deployed predict package ID
PREDICT_ID=            # Predict shared object ID
MANAGER_ID=            # Balance manager ID
REGISTRY_ID=           # Oracle registry ID
ORACLE_CAP_ID=         # Oracle capability object ID
BTC_ORACLE_ID=         # BTC oracle object ID
ETH_ORACLE_ID=         # ETH oracle object ID (optional)
DEEP_ORACLE_ID=        # DEEP oracle object ID (optional)
```

## Smart Contract Security

### Invariants Checked

1. **Oracle freshness**: Trades only execute when `spot_timestamp_ms` is within `spot_staleness_threshold_ms`
2. **Settlement accuracy**: Settlement price is compared against strike with exact integer math
3. **Position limits**: Kelly Criterion sizing caps maximum position at 50% of available balance
4. **Expiry enforcement**: Oracle rotation occurs 15 minutes before expiry to prevent stale trades

### Audit Status

- Internal review completed
- Formal verification of Black-Scholes edge cases in Move tests
- Boundary condition tests for all arithmetic operations

### Known Limitations

- Oracle updates rely on off-chain price feeds (Binance, Bybit)
- SVI parameters are simplified (not full market-calibrated)
- No flashloan protection in current version

## Operational Security

### Network Isolation

- Oracle feed runs on a dedicated machine/container
- Database is not exposed to public internet
- API server uses CORS restrictions

### Monitoring

- Telegram alerts for critical errors
- Console + file logging for all trade actions
- Protocol journal (`protocol_journal.jsonl`) for audit trail

### Rate Limiting

- Oracle updates limited to once per 60-second cycle
- Trade execution requires oracle freshness check
- Maximum 3 claim retry attempts before position is marked FAILED

## Reporting Vulnerabilities

If you discover a security vulnerability, please report it responsibly:

1. **DO NOT** open a public GitHub issue
2. Email security concerns to the maintainers
3. Include reproduction steps and impact assessment
4. Allow reasonable time for a fix before public disclosure

## Bug Bounty

Critical vulnerabilities that could lead to loss of funds may be eligible for a bounty. Contact the maintainers for details.
