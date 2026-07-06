# Mint-Batch Findings - 2026-07-01

This finding resolves the question: why does a 100-mint PTB cost billions of
MIST in computation when 100 standalone mints are much cheaper?

Status: measured finding. It corrects the earlier hypothesis that the mechanism
was liquidation-book page dirtying. The current evidence points to
per-transaction metering / command-position accumulation.

## Result

Replicated across two localnet runs:

| Measurement | Computation | Relative |
| --- | --- | --- |
| standalone leveraged mint | about 2.0M MIST | 1x |
| leveraged mint after 20 1x mints in one PTB | about 40.4M MIST | about 20.2x |
| average leveraged mint inside a 20-leveraged-mint PTB | about 28.1M MIST | about 14.0x |

Sweep of identical leveraged mints in one PTB:

- N=1: about 1.9M MIST per mint
- N=100: about 34.2M MIST per mint
- N=100 total: about 3.42B MIST computation, about 68% of the 5e9 cap

The atomic batch ceiling is roughly 110-150 leveraged mints per PTB,
data-dependent on book shape.

## Mechanism

The discriminator was decisive:

```text
20 1x mints + 1 leveraged mint
```

1x mints do not write the liquidation book, but the following leveraged mint was
still amplified about as much as a leveraged mint inside a leveraged batch. If
the cause were prior liquidation-book writes dirtying pages, the 1x prefix would
not have created the same effect.

Conclusion:

- cost scales with command position and accumulated transaction state;
- the amplification is transaction-level, not liquidation-book-specific;
- scan-once caching would help less than expected because the amplification is
  not only in the scan's logical work.

## Implications

- Normal one-op user flows are unaffected.
- Routers and keepers should not build unbounded large atomic leveraged
  mint/redeem PTBs.
- A PTB's nth command can be much more expensive than the same command
  standalone.
- The ceiling applies to large multi-command PTBs generally, not only
  liquidation-scan-heavy operations.

## Caveats

- Localnet gives direction and mechanism, not a permanent production multiplier.
- Magnitude depends on book shape and transaction shape.
- A pure no-op prefix experiment would further isolate raw command-count effects,
  but is not required for the current cap decision.
