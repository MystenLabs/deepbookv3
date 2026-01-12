# ReferralFeeEvent Checkpoint

This directory should contain a checkpoint file (`.chk`) with a `ReferralFeeEvent` from mainnet or testnet.

The event is emitted when a spot trade occurs through a balance manager with an associated referral ID.

To obtain a checkpoint:
1. Find a transaction with ReferralFeeEvent on-chain (has been emitting since Sept 2025)
2. Use the indexer's checkpoint extraction tool to create the `.chk` file
3. Add it here with the checkpoint sequence number as the filename (e.g., `123456789.chk`)

Expected snapshot output in `snapshots/snapshot_tests__referral_fee_events__referral_fee_events.snap`:
```json
{
  "event_digest": "<tx_digest><event_index>",
  "digest": "<tx_digest>",
  "sender": "<sender_address>",
  "checkpoint": <checkpoint_number>,
  "checkpoint_timestamp_ms": <timestamp>,
  "package": "<deepbook_package_id>",
  "pool_id": "<pool_object_id>",
  "referral_id": "<referral_object_id>",
  "base_fee": <base_token_fee_amount>,
  "quote_fee": <quote_token_fee_amount>,
  "deep_fee": <deep_token_fee_amount>
}
```
