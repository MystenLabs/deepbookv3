// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::admin::handlers::{CreateAssetRequest, CreatePoolRequest, UpdatePoolRequest};
use crate::error::DeepBookError;
use deepbook_schema::schema;
use diesel::{AsChangeset, ExpressionMethods, QueryDsl};
use diesel_async::RunQueryDsl;
use sui_pg_db::{Db, DbArgs};
use url::Url;

#[derive(AsChangeset)]
#[diesel(table_name = schema::pools)]
struct PoolChangeset {
    pool_name: Option<String>,
    min_size: Option<i64>,
    lot_size: Option<i64>,
    tick_size: Option<i64>,
}

#[derive(Clone)]
pub struct Writer {
    db: Db,
}

impl Writer {
    pub async fn new(database_url: Url, db_args: DbArgs) -> Result<Self, anyhow::Error> {
        let db = Db::for_write(database_url, db_args).await?;
        Ok(Self { db })
    }

    pub async fn create_pool(&self, req: CreatePoolRequest) -> Result<(), DeepBookError> {
        let mut conn = self
            .db
            .connect()
            .await
            .map_err(|e| DeepBookError::database(e.to_string()))?;

        diesel::insert_into(schema::pools::table)
            .values((
                schema::pools::pool_id.eq(&req.pool_id),
                schema::pools::pool_name.eq(&req.pool_name),
                schema::pools::base_asset_id.eq(&req.base_asset_id),
                schema::pools::base_asset_decimals.eq(req.base_asset_decimals),
                schema::pools::base_asset_symbol.eq(&req.base_asset_symbol),
                schema::pools::base_asset_name.eq(&req.base_asset_name),
                schema::pools::quote_asset_id.eq(&req.quote_asset_id),
                schema::pools::quote_asset_decimals.eq(req.quote_asset_decimals),
                schema::pools::quote_asset_symbol.eq(&req.quote_asset_symbol),
                schema::pools::quote_asset_name.eq(&req.quote_asset_name),
                schema::pools::min_size.eq(req.min_size),
                schema::pools::lot_size.eq(req.lot_size),
                schema::pools::tick_size.eq(req.tick_size),
            ))
            .execute(&mut conn)
            .await?;

        Ok(())
    }

    pub async fn update_pool(&self, id: &str, req: UpdatePoolRequest) -> Result<(), DeepBookError> {
        let mut conn = self
            .db
            .connect()
            .await
            .map_err(|e| DeepBookError::database(e.to_string()))?;

        let changeset = PoolChangeset {
            pool_name: req.pool_name,
            min_size: req.min_size,
            lot_size: req.lot_size,
            tick_size: req.tick_size,
        };

        let rows_affected =
            diesel::update(schema::pools::table.filter(schema::pools::pool_id.eq(id)))
                .set(changeset)
                .execute(&mut conn)
                .await?;

        if rows_affected == 0 {
            return Err(DeepBookError::not_found(format!("pool {id}")));
        }
        Ok(())
    }

    pub async fn delete_pool(&self, id: &str) -> Result<(), DeepBookError> {
        let mut conn = self
            .db
            .connect()
            .await
            .map_err(|e| DeepBookError::database(e.to_string()))?;

        let rows_affected =
            diesel::delete(schema::pools::table.filter(schema::pools::pool_id.eq(id)))
                .execute(&mut conn)
                .await?;

        if rows_affected == 0 {
            return Err(DeepBookError::not_found(format!("pool {id}")));
        }
        Ok(())
    }

    pub async fn create_asset(&self, req: CreateAssetRequest) -> Result<(), DeepBookError> {
        let mut conn = self
            .db
            .connect()
            .await
            .map_err(|e| DeepBookError::database(e.to_string()))?;

        diesel::insert_into(schema::assets::table)
            .values((
                schema::assets::asset_type.eq(&req.asset_type),
                schema::assets::name.eq(&req.name),
                schema::assets::symbol.eq(&req.symbol),
                schema::assets::decimals.eq(req.decimals),
                schema::assets::ucid.eq(req.ucid),
                schema::assets::package_id.eq(&req.package_id),
                schema::assets::package_address_url.eq(&req.package_address_url),
            ))
            .execute(&mut conn)
            .await?;

        Ok(())
    }

    pub async fn delete_asset(&self, id: &str) -> Result<(), DeepBookError> {
        let mut conn = self
            .db
            .connect()
            .await
            .map_err(|e| DeepBookError::database(e.to_string()))?;

        let rows_affected =
            diesel::delete(schema::assets::table.filter(schema::assets::asset_type.eq(id)))
                .execute(&mut conn)
                .await?;

        if rows_affected == 0 {
            return Err(DeepBookError::not_found(format!("asset {id}")));
        }
        Ok(())
    }
}
