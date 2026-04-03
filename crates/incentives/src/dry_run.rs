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

use std::collections::HashMap;

use anyhow::Result;
use clap::Parser;
use tracing::info;

use deepbook_incentives::scoring::compute_scores;
use deepbook_incentives::types::*;

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

    /// Window duration in ms.
    #[arg(long, default_value = "3600000")]
    window_duration_ms: u64,

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

    println!();
    println!("╔══════════════════════════════════════════════════════════════╗");
    println!("║           MAKER INCENTIVES — DRY RUN SIMULATION            ║");
    println!("╚══════════════════════════════════════════════════════════════╝");
    println!();
    println!("  Pool:           {}", args.pool_id);
    println!("  Alpha:          {}", args.alpha);
    println!("  Window:         {}h", args.window_duration_ms / 3_600_000);
    println!("  Reward/epoch:   {} DEEP", args.reward_per_epoch);
    println!("  Epoch start:    {} ({})", epoch_start, format_ts(epoch_start));
    println!("  Epoch end:      {} ({})", epoch_end, format_ts(epoch_end));
    println!("  Ignore stakes:  {}", args.ignore_stakes);
    println!();

    // 1. Fetch data from deepbook-server.
    let url = format!(
        "{}/incentives/pool_data/{}?start_ms={}&end_ms={}",
        args.server_url, args.pool_id, epoch_start, epoch_end,
    );

    info!("fetching {}", url);
    let client = reqwest::Client::new();
    let pool_data: PoolDataResponse = client
        .get(&url)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    // Pool metadata comes from the deepbook-server's pools table.
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
        window_duration_ms: args.window_duration_ms as i64,
        alpha: args.alpha,
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

    let scores = compute_scores(
        &pool_data.order_events,
        &pool_data.fill_events,
        &config,
        stake_events,
        stake_required,
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
                "       Active Windows:       {} / {}",
                d.windows_active,
                ((epoch_end - epoch_start) / args.window_duration_ms).max(1),
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
    let num_windows = ((epoch_end - epoch_start) / args.window_duration_ms).max(1) as usize;
    let mut window_volumes: Vec<f64> = vec![0.0; num_windows];
    for f in &pool_data.fill_events {
        let w = ((f.checkpoint_timestamp_ms as u64 - epoch_start) / args.window_duration_ms) as usize;
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
        let w_start = epoch_start + (w as u64) * args.window_duration_ms;
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

use std::collections::HashSet;
