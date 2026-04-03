// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use clap::Parser;

#[derive(Parser, Clone)]
#[clap(rename_all = "kebab-case", author, version)]
pub struct Config {
    /// Comma-separated list of valid bearer tokens for API auth.
    #[clap(env = "BENCH_API_TOKENS", long)]
    pub api_tokens: String,

    /// Port for the API server.
    #[clap(env = "BENCH_API_PORT", long, default_value_t = 8080)]
    pub api_port: u16,

    /// Docker image for the simulation container.
    #[clap(env = "BENCH_SIM_IMAGE", long, default_value = "predict-sim:latest")]
    pub sim_image: String,

    /// Docker image for the init container that clones the repo.
    #[clap(env = "BENCH_INIT_IMAGE", long, default_value = "alpine/git:2.47.2")]
    pub init_image: String,

    /// Kubernetes namespace to create benchmark jobs in.
    #[clap(env = "BENCH_K8S_NAMESPACE", long, default_value = "predict-bench")]
    pub k8s_namespace: String,

    /// GitHub repo in owner/repo format (e.g. "MystenLabs/deepbookv3").
    #[clap(env = "GITHUB_REPO", long, default_value = "MystenLabs/deepbookv3")]
    pub github_repo: String,

    /// GitHub token for API calls (needs read access to the repo).
    #[clap(env = "GITHUB_TOKEN", long)]
    pub github_token: Option<String>,

    /// Redis URL for persistent run state.
    #[clap(env = "REDIS_URL", long, default_value = "redis://redis:6379")]
    pub redis_url: String,
}

impl Config {
    pub fn tokens(&self) -> Vec<&str> {
        self.api_tokens.split(',').map(|s| s.trim()).collect()
    }

    pub fn validate_token(&self, token: &str) -> bool {
        self.tokens().iter().any(|t| {
            use subtle::ConstantTimeEq;
            t.as_bytes().ct_eq(token.as_bytes()).into()
        })
    }
}
