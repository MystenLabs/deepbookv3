//! Sandbox mode support for the DeepBook indexer.
//!
//! Provides a write-once global override for package addresses, allowing the indexer
//! to use CLI-provided package IDs instead of the hardcoded mainnet/testnet constants.
//! Call [`init_package_override`] once at startup before any handler processes checkpoints.

use std::sync::OnceLock;

#[derive(Debug)]
struct PackageOverride {
    core: &'static [&'static str],   // DeepBook package id
    margin: &'static [&'static str], // lending / liquidation
}

static PACKAGE_OVERRIDE: OnceLock<PackageOverride> = OnceLock::new();

/// Initialize custom package addresses for sandbox mode.
/// Must be called exactly once at startup, before any handler processes checkpoints.
///
/// Uses `Box::leak` to promote dynamic strings to `'static` lifetime —
/// acceptable because the indexer process needs them for its entire lifetime.
pub fn init_package_override(core: Vec<String>, margin: Vec<String>) {
    let core: Vec<&'static str> = core
        .into_iter()
        .map(|s| &*Box::leak(s.into_boxed_str()))
        .collect();
    let margin: Vec<&'static str> = margin
        .into_iter()
        .map(|s| &*Box::leak(s.into_boxed_str()))
        .collect();
    PACKAGE_OVERRIDE
        .set(PackageOverride {
            core: Box::leak(core.into_boxed_slice()),
            margin: Box::leak(margin.into_boxed_slice()),
        })
        .expect("init_package_override must only be called once");
}

/// Returns sandbox core package addresses if override is active.
pub(crate) fn core_packages() -> Option<&'static [&'static str]> {
    PACKAGE_OVERRIDE.get().map(|o| o.core)
}

/// Returns sandbox margin package addresses if override is active.
pub(crate) fn margin_packages() -> Option<&'static [&'static str]> {
    PACKAGE_OVERRIDE.get().map(|o| o.margin)
}
