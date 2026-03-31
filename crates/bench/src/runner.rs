// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::config::Config;
use anyhow::{Context, Result};
use k8s_openapi::api::batch::v1::{Job, JobSpec};
use k8s_openapi::api::core::v1::{
    Container, EmptyDirVolumeSource, EnvVar, EnvVarSource, PodSpec, PodTemplateSpec,
    SecretKeySelector, Volume, VolumeMount,
};
use k8s_openapi::apimachinery::pkg::apis::meta::v1::ObjectMeta;
use kube::api::{Api, PostParams};
use kube::Client;
use std::collections::BTreeMap;
use tracing::info;

/// Create a k8s Job to run the simulation. Fire-and-forget — the job calls
/// back to `POST /api/v1/benchmark/:run_id/results` when done.
pub async fn create_sim_job(config: &Config, run_id: &str, sha: &str) -> Result<String> {
    let client = Client::try_default()
        .await
        .context("connect to k8s cluster")?;
    let jobs: Api<Job> = Api::namespaced(client, &config.k8s_namespace);

    let job_name = format!("predict-sim-{}", run_id);
    let job = build_job_spec(&job_name, config, run_id, sha);

    info!(job = %job_name, sha, run_id, "creating k8s benchmark job");
    jobs.create(&PostParams::default(), &job)
        .await
        .context("create k8s job")?;

    Ok(job_name)
}

fn build_job_spec(job_name: &str, config: &Config, run_id: &str, sha: &str) -> Job {
    let mut labels = BTreeMap::new();
    labels.insert("app".to_string(), "predict-sim".to_string());
    labels.insert("sha".to_string(), sha[..8.min(sha.len())].to_string());
    labels.insert("run-id".to_string(), run_id.to_string());

    let callback_url = format!(
        "http://predict-bench.{}.svc.cluster.local:{}/api/v1/benchmark/{}/results",
        config.k8s_namespace, config.api_port, run_id
    );
    let github_repo_url = format!("https://github.com/{}.git", config.github_repo);

    // Init container: clone repo at specific SHA.
    let mut init_env = vec![EnvVar {
        name: "REPO_URL".to_string(),
        value: Some(github_repo_url),
        ..Default::default()
    }];

    if config.github_token.is_some() {
        init_env.push(EnvVar {
            name: "GIT_TOKEN".to_string(),
            value_from: Some(EnvVarSource {
                secret_key_ref: Some(SecretKeySelector {
                    name: "git-pat-tokens".to_string(),
                    key: "mysten".to_string(),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        });
    }

    let clone_script = format!(
        r#"if [ -n "${{GIT_TOKEN:-}}" ]; then
  REPO_URL=$(echo "$REPO_URL" | sed "s|https://|https://${{GIT_TOKEN}}@|")
fi
git clone --depth=1 "$REPO_URL" /workspace/repo
cd /workspace/repo
git fetch origin {sha} --depth=1
git checkout {sha}"#,
        sha = sha
    );

    let init_container = Container {
        name: "git-cloner".to_string(),
        image: Some(config.init_image.clone()),
        command: Some(vec!["/bin/sh".to_string(), "-ec".to_string()]),
        args: Some(vec![clone_script]),
        env: Some(init_env),
        volume_mounts: Some(vec![VolumeMount {
            name: "workspace".to_string(),
            mount_path: "/workspace".to_string(),
            ..Default::default()
        }]),
        ..Default::default()
    };

    // Main container: uses the image's entrypoint which runs the sim
    // and POSTs results to the callback URL.
    let main_container = Container {
        name: "predict-sim".to_string(),
        image: Some(config.sim_image.clone()),
        env: Some(vec![
            EnvVar {
                name: "SIM_SHA".to_string(),
                value: Some(sha.to_string()),
                ..Default::default()
            },
            EnvVar {
                name: "CALLBACK_URL".to_string(),
                value: Some(callback_url),
                ..Default::default()
            },
        ]),
        volume_mounts: Some(vec![VolumeMount {
            name: "workspace".to_string(),
            mount_path: "/workspace".to_string(),
            ..Default::default()
        }]),
        ..Default::default()
    };

    Job {
        metadata: ObjectMeta {
            name: Some(job_name.to_string()),
            namespace: Some(config.k8s_namespace.clone()),
            ..Default::default()
        },
        spec: Some(JobSpec {
            ttl_seconds_after_finished: Some(3600),
            backoff_limit: Some(0),
            template: PodTemplateSpec {
                metadata: Some(ObjectMeta {
                    labels: Some(labels),
                    ..Default::default()
                }),
                spec: Some(PodSpec {
                    init_containers: Some(vec![init_container]),
                    containers: vec![main_container],
                    volumes: Some(vec![Volume {
                        name: "workspace".to_string(),
                        empty_dir: Some(EmptyDirVolumeSource::default()),
                        ..Default::default()
                    }]),
                    restart_policy: Some("Never".to_string()),
                    ..Default::default()
                }),
            },
            ..Default::default()
        }),
        ..Default::default()
    }
}
