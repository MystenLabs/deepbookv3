// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault module - holds LP funds and acts as counterparty to all trades.
///
/// Core structs:
/// - `Vault` shared object containing:
///   - USDC balance (LP deposits)
///   - Markets table (PositionCoin ID -> Market)
///   - Total shares outstanding
///   - Pause flags
///
/// - `VaultShare` owned object representing LP position:
///   - Number of shares owned
///   - Deposit timestamp (for 24h lockup enforcement)
///
/// Share value calculation:
///   share_value = vault_usdc_balance / total_shares
///   As vault profits from spreads, share_value increases automatically.
///
/// The Vault is created once during package initialization.
module deepbook_predict::vault;
