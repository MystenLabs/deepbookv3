use crate::error::PredictError;
use deepbook_predict_schema::models::*;
use deepbook_predict_schema::schema;
use diesel::{ExpressionMethods, QueryDsl, RunQueryDsl};
use diesel_async::RunQueryDsl as AsyncRunQueryDsl;
use sui_pg_db::Db;

pub struct Reader {
    db: Db,
}

impl Reader {
    pub fn new(db: Db) -> Self {
        Self { db }
    }

    pub async fn get_vaults(&self) -> Result<Vec<PredictVault>, PredictError> {
        let mut conn = self.db.connect().await.map_err(|e| PredictError::Internal(e.to_string()))?;
        schema::predict_vaults::table
            .load::<PredictVault>(&mut conn)
            .await
            .map_err(|e| PredictError::Internal(e.to_string()))
    }

    pub async fn get_oracles(&self) -> Result<Vec<PredictOracle>, PredictError> {
        let mut conn = self.db.connect().await.map_err(|e| PredictError::Internal(e.to_string()))?;
        schema::predict_oracles::table
            .load::<PredictOracle>(&mut conn)
            .await
            .map_err(|e| PredictError::Internal(e.to_string()))
    }

    pub async fn get_user_positions(&self, manager_id: String) -> Result<Vec<PredictUserPosition>, PredictError> {
        let mut conn = self.db.connect().await.map_err(|e| PredictError::Internal(e.to_string()))?;
        schema::predict_user_positions::table
            .filter(schema::predict_user_positions::manager_id.eq(manager_id))
            .load::<PredictUserPosition>(&mut conn)
            .await
            .map_err(|e| PredictError::Internal(e.to_string()))
    }

    pub async fn get_mint_events(&self, trader: Option<String>) -> Result<Vec<PredictEventMinted>, PredictError> {
        let mut conn = self.db.connect().await.map_err(|e| PredictError::Internal(e.to_string()))?;
        let mut query = schema::predict_events_minted::table.into_boxed();
        if let Some(trader) = trader {
            query = query.filter(schema::predict_events_minted::trader.eq(trader));
        }
        query
            .load::<PredictEventMinted>(&mut conn)
            .await
            .map_err(|e| PredictError::Internal(e.to_string()))
    }

    pub async fn get_redeem_events(&self, owner: Option<String>) -> Result<Vec<PredictEventRedeemed>, PredictError> {
        let mut conn = self.db.connect().await.map_err(|e| PredictError::Internal(e.to_string()))?;
        let mut query = schema::predict_events_redeemed::table.into_boxed();
        if let Some(owner) = owner {
            query = query.filter(schema::predict_events_redeemed::owner.eq(owner));
        }
        query
            .load::<PredictEventRedeemed>(&mut conn)
            .await
            .map_err(|e| PredictError::Internal(e.to_string()))
    }
}
