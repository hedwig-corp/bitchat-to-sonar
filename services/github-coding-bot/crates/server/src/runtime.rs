use std::{sync::Arc, time::Duration};

use anyhow::{Context, Result};
use coding_bot_config::Config;
use coding_bot_github::GitHubApp;
use coding_bot_store::PostgresStore;
use coding_bot_worker::{
    DockerSandbox, DockerSandboxConfig, WorkspaceManager, WorkspaceManagerConfig,
};
use rmcp::{transport::stdio, ServiceExt};
use sqlx::postgres::PgPoolOptions;
use tokio::sync::watch;
use tracing::{error, info};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

use crate::HermesGitHubServer;

pub async fn run() -> Result<()> {
    init_tracing()?;
    let config = Arc::new(Config::from_env().context("load MCP service configuration")?);
    let pool = PgPoolOptions::new()
        .max_connections(10)
        .connect(config.database_url())
        .await
        .context("connect to PostgreSQL")?;
    let store = Arc::new(PostgresStore::new(pool));
    store.migrate().await.context("run database migrations")?;
    let _controller_lock = store
        .acquire_controller_lock()
        .await
        .context("acquire singleton controller lock")?;
    let stale = store
        .recover_abandoned_workspaces()
        .await
        .context("recover abandoned workspace metadata")?;
    if !stale.is_empty() {
        info!(count = stale.len(), "expired stale workspace metadata");
    }

    let github = Arc::new(
        GitHubApp::from_pem_file(
            config.github_app_id,
            &config.github_private_key_path,
            &config.github_api_base_url,
        )
        .context("initialize GitHub App client")?,
    );
    let sandbox_config = DockerSandboxConfig {
        docker_binary: config.docker_binary.clone(),
        image: config.worker_image.clone(),
        network: config.worker_network.clone(),
        memory: config.worker_memory.clone(),
        cpus: config.worker_cpus.clone(),
        pids_limit: config.worker_pids_limit,
        workspace_size: config.worker_workspace_size.clone(),
        max_output_bytes: config.limits.max_tool_output_bytes,
    };
    let removed = DockerSandbox::cleanup_orphans(&sandbox_config)
        .await
        .context("remove orphaned coding sandboxes")?;
    if removed > 0 {
        info!(count = removed, "removed orphaned coding sandboxes");
    }
    let workspaces = Arc::new(WorkspaceManager::new(WorkspaceManagerConfig {
        sandbox: sandbox_config,
        limits: config.limits.clone(),
        blocked_paths: config.blocked_paths.clone(),
        git_author_name: config.git_author_name.clone(),
        git_author_email: config.git_author_email.clone(),
        web_base_url: config.github_web_base_url.to_string(),
    }));
    let server = HermesGitHubServer::new(config, github, store.clone(), workspaces.clone());
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let cleanup = tokio::spawn(cleanup_loop(store.clone(), workspaces.clone(), shutdown_rx));

    info!("Hermes GitHub MCP server starting on stdio");
    let result = async {
        let service = server
            .serve(stdio())
            .await
            .context("initialize MCP stdio transport")?;
        service
            .waiting()
            .await
            .context("serve MCP stdio transport")?;
        Ok::<(), anyhow::Error>(())
    }
    .await;

    let _ = shutdown_tx.send(true);
    if let Err(error) = cleanup.await {
        error!(%error, "workspace cleanup task failed");
    }
    workspaces.shutdown_all().await;
    result
}

async fn cleanup_loop(
    store: Arc<PostgresStore>,
    workspaces: Arc<WorkspaceManager>,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut interval = tokio::time::interval(Duration::from_secs(30));
    loop {
        tokio::select! {
            _ = interval.tick() => {
                let expired = workspaces.expire().await;
                for id in expired {
                    if let Err(error) = store.finish_workspace(id, "expired").await {
                        error!(%id, %error, "failed to persist workspace expiry");
                    }
                }
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
        }
    }
}

fn init_tracing() -> Result<()> {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::registry()
        .with(filter)
        .with(
            tracing_subscriber::fmt::layer()
                .json()
                .with_writer(std::io::stderr),
        )
        .try_init()
        .context("install stderr tracing subscriber")
}
