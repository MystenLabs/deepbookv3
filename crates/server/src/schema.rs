diesel::table! {
  balances_summary (asset) {
      asset -> Text,
      amount -> Int8,
      deposit -> Bool,
  }
}

diesel::table! {
  pools (pool_id) {
      pool_id -> Text,
      pool_name -> Text,
      base_asset_id -> Text,
      base_asset_decimals -> Int2,
      base_asset_symbol -> Text,
      base_asset_name -> Text,
      quote_asset_id -> Text,
      quote_asset_decimals -> Int2,
      quote_asset_symbol -> Text,
      quote_asset_name -> Text,
      min_size -> Int4,
      lot_size -> Int4,
      tick_size -> Int4,
  }
}

diesel::table! {
  order_fills (event_digest) {
      event_digest -> Text,
      digest -> Text,
      sender -> Text,
      checkpoint -> Int8,
      timestamp -> Timestamp,
      checkpoint_timestamp_ms -> Int8,
      package -> Text,
      pool_id -> Text,
      maker_order_id -> Text,
      taker_order_id -> Text,
      maker_client_order_id -> Int8,
      taker_client_order_id -> Int8,
      price -> Int8,
      taker_fee -> Int8,
      taker_fee_is_deep -> Bool,
      maker_fee -> Int8,
      maker_fee_is_deep -> Bool,
      taker_is_bid -> Bool,
      base_quantity -> Int8,
      quote_quantity -> Int8,
      maker_balance_manager_id -> Text,
      taker_balance_manager_id -> Text,
      onchain_timestamp -> Int8,
  }
}

diesel::table! {
  order_updates (event_digest) {
      event_digest -> Text,
      digest -> Text,
      sender -> Text,
      checkpoint -> Int8,
      timestamp -> Timestamp,
      checkpoint_timestamp_ms -> Int8,
      package -> Text,
      status -> Text,
      pool_id -> Text,
      order_id -> Text,
      client_order_id -> Int8,
      price -> Int8,
      is_bid -> Bool,
      original_quantity -> Int8,
      quantity -> Int8,
      filled_quantity -> Int8,
      onchain_timestamp -> Int8,
      balance_manager_id -> Text,
      trader -> Text,
  }
}

diesel::table! {
  assets (asset_type) {
      asset_type -> Text,
      name -> Text,
      symbol -> Text,
      decimals -> Int2,
      ucid -> Nullable<Int4>,
      package_id -> Nullable<Text>,
      package_address_url -> Nullable<Text>,
  }
}
