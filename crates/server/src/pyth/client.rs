// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use super::{
    config::{CHART_HISTORY_UPSTREAM_PATH, HISTORY_UPSTREAM_PATH, LATEST_UPSTREAM_PATH},
    error::PythError,
    models::{ChartHistoryQuery, PythProJsonUpdate, PythProParsedPayload, PythProRequest},
};
use axum::{body::Bytes, http::header::RETRY_AFTER};
use secrecy::{ExposeSecret, Secret};
use std::{sync::Arc, time::Duration};
use url::Url;

#[derive(Clone)]
pub(super) struct PythProClient {
    router_url: Url,
    history_url: Url,
    api_key: Option<Arc<Secret<String>>>,
    http: reqwest::Client,
}

impl PythProClient {
    pub(super) fn new(
        router_url: Url,
        history_url: Url,
        api_key: Option<String>,
    ) -> Result<Self, anyhow::Error> {
        let api_key = api_key
            .map(|key| key.trim().to_owned())
            .filter(|key| !key.is_empty())
            .map(Secret::new)
            .map(Arc::new);
        let http = reqwest::Client::builder()
            .user_agent("deepbook-server")
            .timeout(Duration::from_secs(10))
            .build()?;

        Ok(Self {
            router_url,
            history_url,
            api_key,
            http,
        })
    }

    pub(super) fn is_configured(&self) -> bool {
        self.api_key.is_some()
    }

    fn endpoint(base_url: &Url, path: &str) -> Url {
        let mut url = base_url.clone();
        let mut full_path = url.path().trim_end_matches('/').to_owned();
        full_path.push('/');
        full_path.push_str(path.trim_start_matches('/'));
        url.set_path(&full_path);
        url
    }

    pub(super) async fn latest(
        &self,
        feed_ids: Vec<u32>,
    ) -> Result<PythProParsedPayload, PythError> {
        self.request(LATEST_UPSTREAM_PATH, PythProRequest::latest(feed_ids))
            .await
    }

    pub(super) async fn historical(
        &self,
        feed_ids: Vec<u32>,
        timestamp_us: u64,
    ) -> Result<PythProParsedPayload, PythError> {
        self.request(
            HISTORY_UPSTREAM_PATH,
            PythProRequest::historical(feed_ids, timestamp_us),
        )
        .await
    }

    async fn request(
        &self,
        path: &str,
        request: PythProRequest,
    ) -> Result<PythProParsedPayload, PythError> {
        let response = self
            .send(
                self.http
                    .post(Self::endpoint(&self.router_url, path))
                    .json(&request),
            )
            .await?;
        response
            .json::<PythProJsonUpdate>()
            .await
            .map_err(|error| PythError::InvalidResponse(error.to_string()))?
            .parsed
            .ok_or_else(|| {
                PythError::InvalidResponse("response did not include parsed prices".to_owned())
            })
    }

    pub(super) async fn chart_history(
        &self,
        query: &ChartHistoryQuery,
    ) -> Result<Bytes, PythError> {
        let response = self
            .send(
                self.http
                    .get(Self::endpoint(
                        &self.history_url,
                        CHART_HISTORY_UPSTREAM_PATH,
                    ))
                    .query(query),
            )
            .await?;
        let body = response
            .bytes()
            .await
            .map_err(|error| PythError::InvalidResponse(error.to_string()))?;
        let parsed = serde_json::from_slice::<serde_json::Value>(&body)
            .map_err(|error| PythError::InvalidResponse(error.to_string()))?;
        validate_chart_history(&parsed)?;
        Ok(body)
    }

    async fn send(&self, request: reqwest::RequestBuilder) -> Result<reqwest::Response, PythError> {
        let api_key = self.api_key.as_ref().ok_or(PythError::NotConfigured)?;
        let response = request
            .bearer_auth(api_key.expose_secret())
            .send()
            .await
            .map_err(|error| PythError::Transport(error.to_string()))?;
        let status = response.status();
        let retry_after = response
            .headers()
            .get(RETRY_AFTER)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        if !status.is_success() {
            let message = response
                .text()
                .await
                .unwrap_or_else(|_| format!("Pyth Pro returned HTTP {status}"));
            return Err(PythError::Upstream {
                status,
                message,
                retry_after,
            });
        }
        Ok(response)
    }
}

fn validate_chart_history(body: &serde_json::Value) -> Result<(), PythError> {
    let status = body
        .get("s")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| {
            PythError::InvalidResponse("chart history response has no status".to_owned())
        })?;
    if status != "ok" {
        return Err(PythError::InvalidResponse(format!(
            "chart history returned status `{status}`"
        )));
    }

    let mut expected_len = None;
    for field in ["t", "o", "h", "l", "c", "v"] {
        let values = body
            .get(field)
            .and_then(serde_json::Value::as_array)
            .ok_or_else(|| {
                PythError::InvalidResponse(format!("chart history response has no `{field}` array"))
            })?;
        match expected_len {
            Some(expected_len) if values.len() != expected_len => {
                return Err(PythError::InvalidResponse(
                    "chart history arrays have different lengths".to_owned(),
                ))
            }
            None => expected_len = Some(values.len()),
            _ => {}
        }
    }
    Ok(())
}
