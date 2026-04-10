// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! Dry-run simulation of maker incentive scoring against real pool data.
//!
//! Connects directly to the deepbook-server (no enclave needed), fetches
//! real order/fill/stake data for a pool and time range, runs the scoring
//! algorithm, and prints a detailed breakdown of results.
//!
//! Usage:
//!   cargo run --bin incentives-dry-run -- \
//!     --server-url http://localhost:8080 \
//!     --pool-id 0x... \
//!     --alpha 0.5 \
//!     --reward-per-epoch 1000

use std::collections::{HashMap, HashSet};

use anyhow::Result;
use clap::Parser;
use tracing::info;

use deepbook_incentives::data_validation::{
    indexer_validation_for_epoch, validate_indexer_readiness, validate_pool_data,
};
use deepbook_incentives::pool_info::fetch_pool_metadata_from_node;
use deepbook_incentives::scoring::compute_scores;
use deepbook_incentives::types::{
    PoolDataResponse, ScoringConfig, INCENTIVE_EPOCH_DURATION_MS, INCENTIVE_WINDOW_DURATION_MS,
};
use deepbook_incentives::{compute_fund_loyalty_streak, fund_streak_to_loyalty_map};
use deepbook_incentives::ServerDataValidationConfig;

const DEEP_DECIMALS: f64 = 1_000_000.0;

#[derive(Parser, Debug)]
#[command(name = "incentives-dry-run")]
struct Args {
    /// URL of the deepbook-server.
    #[arg(long, env = "DEEPBOOK_SERVER_URL")]
    server_url: String,

    /// DeepBook pool address.
    #[arg(long)]
    pool_id: String,

    /// Spread-factor exponent.
    #[arg(long, default_value = "0.5")]
    alpha: f64,

    /// Quality compression root `p` in score = depth × loyalty × (quality)^(1/p).
    #[arg(long, default_value = "3")]
    quality_p: u64,

    /// Epoch start (ms since epoch). Default: yesterday midnight UTC.
    #[arg(long)]
    epoch_start_ms: Option<u64>,

    /// Epoch end (ms since epoch). Default: today midnight UTC.
    #[arg(long)]
    epoch_end_ms: Option<u64>,

    /// Simulated DEEP reward per epoch (human-readable units, e.g. 1000 = 1000 DEEP).
    #[arg(long, default_value = "1000")]
    reward_per_epoch: f64,

    /// Skip stake filtering entirely (useful to see all makers regardless of stake).
    #[arg(long, default_value = "false")]
    ignore_stakes: bool,

    #[arg(long, env = "DEEPBOOK_STATUS_MAX_CHECKPOINT_LAG", default_value = "100")]
    max_checkpoint_lag: i64,

    #[arg(long, env = "DEEPBOOK_STATUS_MAX_TIME_LAG_SECONDS", default_value = "60")]
    max_time_lag_seconds: i64,

    #[arg(long, env = "DEEPBOOK_INCENTIVE_REQUIRED_PIPELINES", value_delimiter = ',', default_value = "")]
    required_pipelines: Vec<String>,

    #[arg(long, env = "DEEPBOOK_INCENTIVE_MIN_INDEXED_TIMESTAMP_MS")]
    min_indexed_timestamp_ms: Option<i64>,

    #[arg(long, default_value = "false")]
    skip_indexer_check: bool,

    /// SUI full-node RPC URL for fetching pool metadata directly (bypasses
    /// indexer `pools` table). Example: `https://fullnode.mainnet.sui.io:443`.
    #[arg(long, env = "SUI_RPC_URL")]
    sui_rpc_url: Option<String>,

    /// Fund ID (for loyalty streak computation from on-chain events).
    /// If not provided, loyalty streaks are not computed.
    #[arg(long)]
    fund_id: Option<String>,
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

fn today_midnight_utc() -> u64 {
    let now = now_ms();
    now - (now % 86_400_000)
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    let args = Args::parse();
    let epoch_end = args.epoch_end_ms.unwrap_or_else(today_midnight_utc);
    let epoch_start = args.epoch_start_ms.unwrap_or(epoch_end - 86_400_000);

    let span = epoch_end.saturating_sub(epoch_start);
    if span != INCENTIVE_EPOCH_DURATION_MS {
        anyhow::bail!(
            "epoch span must be exactly {} ms (24h); got {} ms",
            INCENTIVE_EPOCH_DURATION_MS,
            span
        );
    }

    println!();
    println!("╔══════════════════════════════════════════════════════════════╗");
    println!("║           MAKER INCENTIVES — DRY RUN SIMULATION            ║");
    println!("╚══════════════════════════════════════════════════════════════╝");
    println!();
    println!("  Pool:           {}", args.pool_id);
    println!("  Alpha:          {}", args.alpha);
    println!("  Quality p:      {}", args.quality_p);
    println!(
        "  Window:         {}h (fixed)",
        INCENTIVE_WINDOW_DURATION_MS / 3_600_000
    );
    println!("  Reward/epoch:   {} DEEP", args.reward_per_epoch);
    println!("  Epoch start:    {} ({})", epoch_start, format_ts(epoch_start));
    println!("  Epoch end:      {} ({})", epoch_end, format_ts(epoch_end));
    println!("  Ignore stakes:  {}", args.ignore_stakes);
    println!();

    let required_pipelines: Vec<String> = args
        .required_pipelines
        .iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let base_validation = ServerDataValidationConfig {
        max_checkpoint_lag: args.max_checkpoint_lag,
        max_time_lag_seconds: args.max_time_lag_seconds,
        required_pipelines,
        min_indexed_timestamp_ms: args.min_indexed_timestamp_ms,
    };

    let client = reqwest::Client::new();

    if !args.skip_indexer_check {
        let val_cfg = indexer_validation_for_epoch(&base_validation, epoch_end);
        info!("validating indexer /status {:?}", val_cfg);
        validate_indexer_readiness(&client, &args.server_url, &val_cfg)
            .await
            .map_err(|e| anyhow::anyhow!(e))?;
    }

    // 1. Fetch data from deepbook-server.
    let url = format!(
        "{}/incentives/pool_data/{}?start_ms={}&end_ms={}",
        args.server_url, args.pool_id, epoch_start, epoch_end,
    );

    info!("fetching {}", url);
    let mut pool_data: PoolDataResponse = client
        .get(&url)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    validate_pool_data(
        &pool_data,
        &args.pool_id,
        epoch_start as i64,
        epoch_end as i64,
    )
    .map_err(|e| anyhow::anyhow!(e))?;

    // Pool metadata comes from the deepbook-server's pools table, or from the
    // SUI full node if --sui-rpc-url is provided and the indexer hasn't backfilled.
    if pool_data.pool_metadata.is_none() {
        if let Some(ref rpc_url) = args.sui_rpc_url {
            match fetch_pool_metadata_from_node(&client, rpc_url, &args.pool_id).await {
                Ok(meta) => {
                    println!("  (pool metadata fetched from SUI full node)");
                    pool_data.pool_metadata = Some(meta);
                }
                Err(e) => {
                    eprintln!("WARNING: could not fetch pool metadata from full node: {e}");
                }
            }
        }
    }

    let (base_decimals, base_symbol, quote_decimals, quote_symbol) =
        if let Some(ref meta) = pool_data.pool_metadata {
            (meta.base_decimals, meta.base_symbol.clone(), meta.quote_decimals, meta.quote_symbol.clone())
        } else {
            eprintln!("WARNING: deepbook-server did not return pool_metadata — using defaults");
            (9u8, "BASE".to_string(), 6u8, "QUOTE".to_string())
        };
    let base_scalar = 10f64.powi(base_decimals as i32);

    println!("── Data Summary ───────────────────────────────────────────────");
    println!("  Pool pair:      {}/{}", base_symbol, quote_symbol);
    println!("  Base decimals:  {}", base_decimals);
    println!("  Quote decimals: {}", quote_decimals);
    println!("  Order events:   {}", pool_data.order_events.len());
    println!("  Fill events:    {}", pool_data.fill_events.len());
    println!("  Stake events:   {}", pool_data.stake_events.len());
    println!("  Stake required: {} DEEP", pool_data.stake_required as f64 / DEEP_DECIMALS);
    println!();

    // Show stake summary.
    if !pool_data.stake_events.is_empty() {
        let mut net_stakes: HashMap<String, i64> = HashMap::new();
        for s in &pool_data.stake_events {
            let entry = net_stakes.entry(s.balance_manager_id.clone()).or_default();
            if s.stake {
                *entry += s.amount;
            } else {
                *entry -= s.amount;
            }
        }
        let mut sorted_stakes: Vec<_> = net_stakes.iter().collect();
        sorted_stakes.sort_by(|a, b| b.1.cmp(a.1));

        println!("── Stake Summary (top 20) ─────────────────────────────────────");
        println!("  {:>8}  {:>12}  {}", "Rank", "Net Stake", "Balance Manager");
        let eligible_threshold = if pool_data.stake_required > 0 {
            pool_data.stake_required
        } else {
            1
        };
        for (i, (bm, net)) in sorted_stakes.iter().take(20).enumerate() {
            let eligible = if **net >= eligible_threshold { "✓" } else { "✗" };
            println!(
                "  {:>6}.  {:>10.0} DEEP  {} {}",
                i + 1,
                **net as f64 / DEEP_DECIMALS,
                eligible,
                abbreviate(bm),
            );
        }
        let total_eligible = sorted_stakes.iter().filter(|(_, n)| **n >= eligible_threshold).count();
        let total_stakers = sorted_stakes.len();
        println!("  {} eligible / {} total stakers", total_eligible, total_stakers);
        println!();
    }

    // 2. Run scoring.
    let config = ScoringConfig {
        pool_id: args.pool_id.clone(),
        epoch_start_ms: epoch_start as i64,
        epoch_end_ms: epoch_end as i64,
        window_duration_ms: INCENTIVE_WINDOW_DURATION_MS as i64,
        alpha: args.alpha,
        quality_p: args.quality_p.max(1),
    };

    let stake_events = if args.ignore_stakes {
        &[][..]
    } else {
        &pool_data.stake_events[..]
    };
    let stake_required = if args.ignore_stakes {
        0
    } else {
        pool_data.stake_required
    };

    // Loyalty streaks from on-chain events (only when --fund-id is provided).
    let loyalty_map = if let Some(ref fund_id) = args.fund_id {
        let fund_streak = compute_fund_loyalty_streak(
            &client,
            &args.server_url,
            fund_id,
            epoch_start,
            INCENTIVE_EPOCH_DURATION_MS,
        )
        .await
        .unwrap_or_else(|e| {
            eprintln!("WARNING: loyalty streak query failed: {e}");
            0
        });

        println!("── Loyalty (from on-chain events) ─────────────────────────────");
        println!("  Fund:             {}", fund_id);
        println!("  Fund-level streak: {} consecutive prior epochs", fund_streak);
        println!("  Loyalty mult:      {:.1}x (cap 3)", ((fund_streak as f64) + 1.0).min(3.0));
        println!();

        let candidates: Vec<String> = pool_data
            .order_events
            .iter()
            .map(|o| o.balance_manager_id.clone())
            .collect::<std::collections::HashSet<_>>()
            .into_iter()
            .collect();
        fund_streak_to_loyalty_map(&candidates, fund_streak)
    } else {
        std::collections::HashMap::new()
    };

    let scores = compute_scores(
        &pool_data.order_events,
        &pool_data.fill_events,
        &config,
        stake_events,
        stake_required,
        &loyalty_map,
    );

    // 3. Print results.
    let total_score: f64 = scores.iter().map(|s| s.score).sum();

    println!("── Scoring Results ────────────────────────────────────────────");
    println!("  Eligible makers scored: {}", scores.len());
    println!();

    if scores.is_empty() {
        println!("  No eligible makers found. Try --ignore-stakes to see all.");
        println!();
        return Ok(());
    }

    for (i, s) in scores.iter().enumerate() {
        let share = s.score / total_score;
        let payout = share * args.reward_per_epoch;
        println!(
            "  #{:<3} {}",
            i + 1,
            &s.balance_manager_id,
        );
        println!(
            "       Payout: {:.2} DEEP ({:.2}% share)",
            payout,
            share * 100.0,
        );
        if let Some(d) = &s.detail {
            let size_base = d.avg_effective_size / base_scalar;
            let spread_bps = if d.avg_mid_price > 0.0 {
                (d.avg_spread / d.avg_mid_price) * 10_000.0
            } else {
                0.0
            };
            println!(
                "       Avg Depth (base):     {} {}",
                format_with_commas(size_base),
                base_symbol,
            );
            println!(
                "       Avg Spread:           {:.1} bps",
                spread_bps,
            );
            println!(
                "       Spread Multiplier:    {:.2}x  (tighter than median → higher; capped at 10x)",
                d.avg_spread_factor,
            );
            println!(
                "       Time Quoting:         {:.0}%  (fraction of window with active two-sided quotes)",
                d.avg_time_frac * 100.0,
            );
            println!(
                "       Loyalty mult:         {:.1}x  (from consecutive prior scored epochs, cap 3)",
                d.loyalty_mult,
            );
            println!(
                "       Active Windows:       {} / {}",
                d.windows_active,
                ((epoch_end - epoch_start) / INCENTIVE_WINDOW_DURATION_MS).max(1),
            );
            println!(
                "       Unique Orders:        {}",
                format_with_commas(d.unique_orders as f64),
            );
        }
        println!();
    }

    println!("  {}", "─".repeat(60));
    println!(
        "  Total: {:.2} DEEP across {} makers",
        args.reward_per_epoch,
        scores.len(),
    );
    println!();

    // 4. Window-level detail.
    let num_windows = ((epoch_end - epoch_start) / INCENTIVE_WINDOW_DURATION_MS).max(1) as usize;
    let mut window_volumes: Vec<f64> = vec![0.0; num_windows];
    for f in &pool_data.fill_events {
        let w = ((f.checkpoint_timestamp_ms as u64 - epoch_start) / INCENTIVE_WINDOW_DURATION_MS)
            as usize;
        if w < num_windows {
            window_volumes[w] += f.base_quantity as f64;
        }
    }
    let total_volume: f64 = window_volumes.iter().sum();
    let floor = 1.0 / (2.0 * num_windows as f64);

    println!("── Window Weights ─────────────────────────────────────────────");
    println!(
        "  {:>8}  {:>14}  {:>8}  {:>10}",
        "Window", "Volume", "Weight", "Start Time"
    );
    for w in 0..num_windows {
        let weight = if total_volume > 0.0 {
            (window_volumes[w] / total_volume).max(floor)
        } else {
            floor
        };
        let w_start = epoch_start + (w as u64) * INCENTIVE_WINDOW_DURATION_MS;
        println!(
            "  {:>6}    {:>12.0}  {:>7.4}  {}",
            w + 1,
            window_volumes[w],
            weight,
            format_ts(w_start),
        );
    }
    println!("  Total volume: {:.0}", total_volume);
    println!("  Floor weight: {:.4}", floor);
    println!();

    // 5. Unique makers in order data (before stake filter).
    let all_makers: HashSet<String> = pool_data
        .order_events
        .iter()
        .map(|o| o.balance_manager_id.clone())
        .collect();
    println!("── Summary ────────────────────────────────────────────────────");
    println!("  Unique makers in order data:  {}", all_makers.len());
    println!("  Eligible (post-stake filter): {}", scores.len());
    println!("  Filtered out:                 {}", all_makers.len() - scores.len());
    println!();

    Ok(())
}

fn format_ts(ms: u64) -> String {
    let secs = (ms / 1000) as i64;
    let nanos = ((ms % 1000) * 1_000_000) as u32;
    let dt = chrono::DateTime::from_timestamp(secs, nanos);
    match dt {
        Some(d) => d.format("%Y-%m-%d %H:%M UTC").to_string(),
        None => format!("{}ms", ms),
    }
}

fn format_with_commas(n: f64) -> String {
    let integer = n.abs() as u64;
    let s = integer.to_string();
    let mut result = String::new();
    for (i, c) in s.chars().rev().enumerate() {
        if i > 0 && i % 3 == 0 {
            result.push(',');
        }
        result.push(c);
    }
    let formatted: String = result.chars().rev().collect();
    if n < 0.0 {
        format!("-{}", formatted)
    } else {
        formatted
    }
}

fn abbreviate(addr: &str) -> String {
    if addr.len() > 16 {
        format!("{}…{}", &addr[..10], &addr[addr.len() - 6..])
    } else {
        addr.to_string()
    }
}

