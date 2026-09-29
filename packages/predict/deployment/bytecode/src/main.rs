use anyhow::{bail, ensure, Context, Result};
use move_binary_format::file_format::CompiledModule;
use std::{collections::BTreeMap, io};

/// Match historical serialization without erasing instructions, constants, metadata,
/// declarations, or identities. Both directions must be byte-for-byte equal.
fn verify(compiled: &[u8], published: &[u8]) -> Result<()> {
    let current = CompiledModule::deserialize_with_defaults(compiled)?;
    let historical = CompiledModule::deserialize_with_defaults(published)?;
    let mut encoded = Vec::new();
    current.serialize_with_version(historical.version, &mut encoded)?;
    ensure!(encoded == published, "published bytecode differs");
    let mut roundtrip = Vec::new();
    CompiledModule::deserialize_with_defaults(&encoded)?
        .serialize_with_version(current.version, &mut roundtrip)?;
    ensure!(
        roundtrip == compiled,
        "historical encoding discarded compiled data"
    );
    Ok(())
}

fn main() -> Result<()> {
    let mut input: BTreeMap<String, BTreeMap<String, Vec<u8>>> =
        serde_json::from_reader(io::stdin().lock())?;
    let compiled = input
        .remove("compiled")
        .context("missing compiled modules")?;
    let published = input
        .remove("published")
        .context("missing published modules")?;
    ensure!(input.is_empty(), "unexpected input fields");
    ensure!(!compiled.is_empty(), "empty module map");
    if compiled.keys().ne(published.keys()) {
        bail!("compiled and published module inventories differ");
    }
    for (name, bytes) in compiled {
        verify(&bytes, &published[&name]).with_context(|| format!("module {name}"))?;
    }
    println!(
        "verified {} modules with lossless historical serialization",
        published.len()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use move_binary_format::file_format::{empty_module, Constant, SignatureToken};

    fn bytes(module: &CompiledModule, version: u32) -> Vec<u8> {
        let mut result = Vec::new();
        module.serialize_with_version(version, &mut result).unwrap();
        result
    }

    #[test]
    fn historical_encoding_is_exact_and_lossless() {
        let module = empty_module();
        let old = bytes(&module, 6);
        let new = bytes(&module, 7);
        assert_ne!(old, new);
        verify(&new, &old).unwrap();
        verify(&new, &new).unwrap();
    }

    #[test]
    fn source_differences_and_malformed_bytes_are_rejected() {
        let original = empty_module();
        let mut changed = original.clone();
        changed.constant_pool.push(Constant {
            type_: SignatureToken::U64,
            data: 42_u64.to_le_bytes().to_vec(),
        });
        assert!(verify(&bytes(&changed, 7), &bytes(&original, 6)).is_err());
        assert!(verify(&[], &bytes(&original, 6)).is_err());
        assert!(verify(&bytes(&original, 7), &[0, 1, 2]).is_err());
    }

    #[test]
    fn changed_module_identity_is_rejected() {
        let original = empty_module();
        let mut changed = original.clone();
        changed.identifiers[0] = "different_module".parse().unwrap();
        assert!(verify(&bytes(&changed, 7), &bytes(&original, 6)).is_err());
    }

    #[test]
    fn trailing_bytes_cannot_be_discarded() {
        let original = empty_module();
        let old = bytes(&original, 6);
        let mut new = bytes(&original, 7);
        new.push(0);
        assert!(verify(&new, &old).is_err());
        let mut old_with_trailer = old;
        old_with_trailer.push(0);
        assert!(verify(&bytes(&original, 7), &old_with_trailer).is_err());
    }
}
