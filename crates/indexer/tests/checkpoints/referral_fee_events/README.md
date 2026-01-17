# ReferralFeeEvent Checkpoint

This directory contains checkpoint files with `ReferralFeeEvent` events from mainnet.

## Checkpoint 233962755

- **Transaction**: `D2YQEZ6D3SfUZ2bVGpMbrzGPoZAbrLYwy5m249aHwqL1`
- **Pool**: SUI/USDC (`0xe05dafb5133bcffb8d59f4e12465dc0e9faeaa05e3e342a08fe135800e3e4407`)
- **Referral ID**: `0xf66fc08674e5592b471d965c82410af5a2b44e2b4b92f191d91c7147d378bcaa`
- **Generated**: January 2026

The event was generated using the script in `_local_scripts/generate-referral-event/`.

## Event Details

The `ReferralFeeEvent` is emitted when a spot trade executes through a balance manager
that has an associated referral ID set via `set_balance_manager_referral()`.

Event fields:
- `pool_id`: The trading pool where the order executed
- `referral_id`: The DeepBookPoolReferral object linked to the balance manager
- `base_fee`: Fee amount in base token (e.g., SUI)
- `quote_fee`: Fee amount in quote token (e.g., USDC)
- `deep_fee`: Fee amount in DEEP token

## How to Generate More Test Data

```bash
cd _local_scripts/generate-referral-event
cp .env.example .env
# Edit .env with your private key
npm install
npx tsx generate-referral-event-simple.ts
```

The script will output the checkpoint number. Download with:
```bash
curl -o <checkpoint>.chk "https://checkpoints.mainnet.sui.io/<checkpoint>.chk"
```
