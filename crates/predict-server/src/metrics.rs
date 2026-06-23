use prometheus::{
    Encoder, IntCounter, IntGauge, Registry, TextEncoder,
};
use std::sync::LazyLock;

pub static REGISTRY: LazyLock<Registry> = LazyLock::new(Registry::new);

pub static ORACLE_UPDATES_TOTAL: LazyLock<IntCounter> = LazyLock::new(|| {
    let counter = IntCounter::new("predict_oracle_updates_total", "Total oracle price updates").unwrap();
    REGISTRY.register(Box::new(counter.clone())).unwrap();
    counter
});

pub static TRADES_EXECUTED_TOTAL: LazyLock<IntCounter> = LazyLock::new(|| {
    let counter = IntCounter::new("predict_trades_executed_total", "Total trades executed").unwrap();
    REGISTRY.register(Box::new(counter.clone())).unwrap();
    counter
});

pub static TRADES_FAILED_TOTAL: LazyLock<IntCounter> = LazyLock::new(|| {
    let counter = IntCounter::new("predict_trades_failed_total", "Total failed trades").unwrap();
    REGISTRY.register(Box::new(counter.clone())).unwrap();
    counter
});

pub static POSITIONS_OPEN: LazyLock<IntGauge> = LazyLock::new(|| {
    let gauge = IntGauge::new("predict_positions_open", "Currently open positions").unwrap();
    REGISTRY.register(Box::new(gauge.clone())).unwrap();
    gauge
});

pub static POSITIONS_SETTLED_TOTAL: LazyLock<IntCounter> = LazyLock::new(|| {
    let counter = IntCounter::new("predict_positions_settled_total", "Total settled positions").unwrap();
    REGISTRY.register(Box::new(counter.clone())).unwrap();
    counter
});

pub static POSITIONS_CLAIMED_TOTAL: LazyLock<IntCounter> = LazyLock::new(|| {
    let counter = IntCounter::new("predict_positions_claimed_total", "Total claimed positions").unwrap();
    REGISTRY.register(Box::new(counter.clone())).unwrap();
    counter
});

pub static SETTLEMENTS_FAILED_TOTAL: LazyLock<IntCounter> = LazyLock::new(|| {
    let counter = IntCounter::new("predict_settlements_failed_total", "Total failed settlements").unwrap();
    REGISTRY.register(Box::new(counter.clone())).unwrap();
    counter
});

pub static CLAIMS_FAILED_TOTAL: LazyLock<IntCounter> = LazyLock::new(|| {
    let counter = IntCounter::new("predict_claims_failed_total", "Total failed claims").unwrap();
    REGISTRY.register(Box::new(counter.clone())).unwrap();
    counter
});

pub static RPC_REQUESTS_TOTAL: LazyLock<IntCounter> = LazyLock::new(|| {
    let counter = IntCounter::new("predict_rpc_requests_total", "Total RPC requests to Sui").unwrap();
    REGISTRY.register(Box::new(counter.clone())).unwrap();
    counter
});

pub static RPC_ERRORS_TOTAL: LazyLock<IntCounter> = LazyLock::new(|| {
    let counter = IntCounter::new("predict_rpc_errors_total", "Total RPC errors").unwrap();
    REGISTRY.register(Box::new(counter.clone())).unwrap();
    counter
});

pub fn encode_metrics() -> String {
    let encoder = TextEncoder::new();
    let metric_families = REGISTRY.gather();
    let mut buffer = Vec::new();
    encoder.encode(&metric_families, &mut buffer).unwrap();
    String::from_utf8(buffer).unwrap()
}
