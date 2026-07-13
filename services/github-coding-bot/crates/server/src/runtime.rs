use std::{sync::Arc, time::Duration};

use anyhow::{Context, Result};
use coding_bot_agent::OpenAiCompatibleModel;
use coding_bot_config::{Config, RunMode};
use coding_bot_github::{GitHubApp, GitHubAppApi};
use coding_bot_store::PostgresStore;
use coding_bot_worker::Worker;
use metrics_exporter_prometheus::PrometheusBuilder;
use sqlx::postgres::PgPoolOptions;
use tokio::{net::TcpListener, sync::watch};
use tracing::{error, info};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

use crate::{router, AppState};

pub async fn run() -> Result<()> {
    init_tracing()?;
    let config = Arc::new(Config::from_env().context("load service configuration")?);
    let pool = PgPoolOptions::new()
        .max_connections(10)
        .connect(config.database_url())
        .await
        .context("connect to PostgreSQL")?;
    let store = Arc::new(PostgresStore::new(pool));
    store.migrate().await.context("run database migrations")?;

    let github: Arc<dyn GitHubAppApi> = Arc::new(
        GitHubApp::from_pem_file(
            config.github_app_id,
            &config.github_private_key_path,
            &config.github_api_base_url,
        )
        .context("initialize GitHub App client")?,
    );
    let model = Arc::new(
        OpenAiCompatibleModel::new(
            &config.llm_base_url,
            config.llm_api_key().to_owned(),
            config.llm_model.clone(),
            config.limits.max_retries,
            Duration::from_secs(config.limits.max_command_seconds),
        )
        .context("initialize LLM provider")?,
    );
    let metrics = PrometheusBuilder::new()
        .install_recorder()
        .context("install metrics recorder")?;
    let state = AppState {
        config: config.clone(),
        store: store.clone(),
        github: github.clone(),
        metrics,
    };
    let worker = Arc::new(Worker::new(store, github, model, config.clone()));

    match config.run_mode {
        RunMode::Api => serve_api(state, shutdown_signal()).await,
        RunMode::Worker => run_worker(worker).await,
        RunMode::All => run_all(state, worker).await,
    }
}

async fn serve_api(
    state: AppState,
    shutdown: impl std::future::Future<Output = ()> + Send + 'static,
) -> Result<()> {
    let listener = TcpListener::bind(state.config.listen_addr)
        .await
        .with_context(|| format!("bind API listener at {}", state.config.listen_addr))?;
    info!(address = %state.config.listen_addr, "HTTP API listening");
    axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown)
        .await
        .context("serve HTTP API")
}

async fn run_worker(worker: Arc<Worker>) -> Result<()> {
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let task = tokio::spawn(worker.run(shutdown_rx));
    shutdown_signal().await;
    let _ = shutdown_tx.send(true);
    task.await.context("join worker task")?;
    Ok(())
}

async fn run_all(state: AppState, worker: Arc<Worker>) -> Result<()> {
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let worker_task = tokio::spawn(worker.run(shutdown_rx.clone()));
    let mut api_shutdown = shutdown_rx;
    let mut api_task = tokio::spawn(serve_api(state, async move {
        while !*api_shutdown.borrow() {
            if api_shutdown.changed().await.is_err() {
                break;
            }
        }
    }));
    let mut api_finished = false;
    tokio::select! {
        () = shutdown_signal() => {}
        result = &mut api_task => {
            api_finished = true;
            result.context("join API task")??;
        }
    }
    let _ = shutdown_tx.send(true);
    if !api_finished {
        api_task.await.context("join API task")??;
    }
    worker_task.await.context("join worker task")?;
    Ok(())
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};

        let mut terminate = match signal(SignalKind::terminate()) {
            Ok(signal) => signal,
            Err(error) => {
                error!(%error, "failed to install SIGTERM handler");
                let _ = tokio::signal::ctrl_c().await;
                return;
            }
        };
        tokio::select! {
            result = tokio::signal::ctrl_c() => {
                if let Err(error) = result {
                    error!(%error, "failed to listen for Ctrl-C");
                }
            }
            _ = terminate.recv() => {}
        }
    }
    #[cfg(not(unix))]
    if let Err(error) = tokio::signal::ctrl_c().await {
        error!(%error, "failed to listen for Ctrl-C");
    }
}

fn init_tracing() -> Result<()> {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::registry()
        .with(filter)
        .with(tracing_subscriber::fmt::layer().json())
        .try_init()
        .context("install tracing subscriber")
}
