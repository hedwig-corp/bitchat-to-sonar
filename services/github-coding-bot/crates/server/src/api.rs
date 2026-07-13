use std::{sync::Arc, time::Duration};

use axum::{
    body::Bytes,
    extract::{DefaultBodyLimit, Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use coding_bot_config::Config;
use coding_bot_github::{
    filter_issue_event, verify_signature, FilterDecision, GitHubAppApi, IssuesWebhook,
};
use coding_bot_store::{EnqueueResult, PostgresStore};
use metrics_exporter_prometheus::PrometheusHandle;
use serde::Serialize;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use tower_http::trace::TraceLayer;
use tracing::{error, info};
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<Config>,
    pub store: Arc<PostgresStore>,
    pub github: Arc<dyn GitHubAppApi>,
    pub metrics: PrometheusHandle,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/webhooks/github", post(github_webhook))
        .route("/health", get(health))
        .route("/ready", get(readiness))
        .route("/metrics", get(metrics))
        .route("/jobs/{id}", get(get_job))
        .route("/jobs/{id}/cancel", post(cancel_job))
        .layer(DefaultBodyLimit::max(1024 * 1024))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn github_webhook(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<(StatusCode, Json<WebhookResponse>), ApiError> {
    let signature = required_header(&headers, "x-hub-signature-256")?;
    verify_signature(
        state.config.github_webhook_secret().as_bytes(),
        &body,
        signature,
    )
    .map_err(|_| {
        ApiError::new(
            StatusCode::UNAUTHORIZED,
            "invalid_signature",
            "invalid signature",
        )
    })?;
    let delivery_id = required_header(&headers, "x-github-delivery")?;
    if delivery_id.is_empty()
        || delivery_id.len() > 128
        || !delivery_id.bytes().all(|byte| byte.is_ascii_graphic())
    {
        return Err(ApiError::bad_request(
            "invalid_delivery_id",
            "invalid GitHub delivery identifier",
        ));
    }
    let event_name = required_header(&headers, "x-github-event")?;
    if event_name != "issues" {
        return Ok((
            StatusCode::ACCEPTED,
            Json(WebhookResponse::ignored("event_not_actionable")),
        ));
    }

    let payload: IssuesWebhook = serde_json::from_slice(&body)
        .map_err(|_| ApiError::bad_request("invalid_payload", "invalid issues webhook payload"))?;
    let candidate = match filter_issue_event(
        delivery_id,
        payload,
        &state.config.github_bot_login,
        &state.config.repository_allowlist,
    ) {
        FilterDecision::Ignored(reason) => {
            info!(?reason, delivery_id, "webhook ignored");
            return Ok((
                StatusCode::ACCEPTED,
                Json(WebhookResponse::ignored("event_filtered")),
            ));
        }
        FilterDecision::Candidate(candidate) => candidate,
    };

    let access = state
        .github
        .installation(candidate.job.installation_id)
        .await
        .map_err(|error| {
            error!(%error, delivery_id, "GitHub App installation authentication failed");
            ApiError::internal()
        })?;
    let trusted = access
        .api
        .trusted_actor(
            &candidate.job.repository_owner,
            &candidate.job.repository_name,
            &candidate.sender_login,
        )
        .await
        .map_err(|error| {
            error!(%error, delivery_id, "maintainer permission lookup failed");
            ApiError::internal()
        })?;
    if !trusted {
        info!(
            delivery_id,
            sender = %candidate.sender_login,
            "webhook ignored because labeler is untrusted"
        );
        return Ok((
            StatusCode::ACCEPTED,
            Json(WebhookResponse::ignored("untrusted_labeler")),
        ));
    }

    let response = match state.store.enqueue(event_name, candidate.job).await {
        Ok(EnqueueResult::Queued(job)) => WebhookResponse {
            status: "queued",
            job_id: Some(job.id),
        },
        Ok(EnqueueResult::DuplicateDelivery) => WebhookResponse::ignored("duplicate_delivery"),
        Ok(EnqueueResult::DuplicateActiveJob) => WebhookResponse::ignored("active_job_exists"),
        Err(error) => {
            error!(%error, delivery_id, "failed to enqueue webhook job");
            return Err(ApiError::internal());
        }
    };
    Ok((StatusCode::ACCEPTED, Json(response)))
}

async fn health() -> Json<StatusResponse> {
    Json(StatusResponse { status: "ok" })
}

async fn readiness(State(state): State<AppState>) -> impl IntoResponse {
    if let Err(error) = state.store.ping().await {
        error!(%error, "readiness database check failed");
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(StatusResponse {
                status: "database_unavailable",
            }),
        );
    }
    match state
        .store
        .worker_available(Duration::from_secs(
            state.config.worker_lease_seconds.saturating_mul(2),
        ))
        .await
    {
        Ok(true) => (StatusCode::OK, Json(StatusResponse { status: "ready" })),
        Ok(false) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(StatusResponse {
                status: "worker_unavailable",
            }),
        ),
        Err(error) => {
            error!(%error, "readiness worker check failed");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(StatusResponse {
                    status: "database_unavailable",
                }),
            )
        }
    }
}

async fn metrics(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, ApiError> {
    authorize_admin(&state.config, &headers)?;
    Ok((
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/plain; version=0.0.4")],
        state.metrics.render(),
    ))
}

async fn get_job(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, ApiError> {
    authorize_admin(&state.config, &headers)?;
    let job = state.store.get(id).await.map_err(|error| {
        error!(%error, %id, "failed to read job");
        ApiError::internal()
    })?;
    match job {
        Some(job) => Ok((StatusCode::OK, Json(job))),
        None => Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "job_not_found",
            "job not found",
        )),
    }
}

async fn cancel_job(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, ApiError> {
    authorize_admin(&state.config, &headers)?;
    if let Some(job) = state.store.cancel(id).await.map_err(|error| {
        error!(%error, %id, "failed to cancel job");
        ApiError::internal()
    })? {
        return Ok((StatusCode::ACCEPTED, Json(job)));
    }
    if state
        .store
        .get(id)
        .await
        .map_err(|error| {
            error!(%error, %id, "failed to inspect job after cancellation conflict");
            ApiError::internal()
        })?
        .is_some()
    {
        Err(ApiError::new(
            StatusCode::CONFLICT,
            "job_not_active",
            "job is no longer active",
        ))
    } else {
        Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "job_not_found",
            "job not found",
        ))
    }
}

fn required_header<'a>(headers: &'a HeaderMap, name: &'static str) -> Result<&'a str, ApiError> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| ApiError::bad_request("missing_header", "required GitHub header missing"))
}

fn authorize_admin(config: &Config, headers: &HeaderMap) -> Result<(), ApiError> {
    let provided = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .unwrap_or_default();
    let expected_digest = Sha256::digest(config.admin_api_token().as_bytes());
    let provided_digest = Sha256::digest(provided.as_bytes());
    if bool::from(expected_digest.ct_eq(&provided_digest)) {
        Ok(())
    } else {
        Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "invalid administrative token",
        ))
    }
}

#[derive(Debug, Serialize)]
struct WebhookResponse {
    status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    job_id: Option<Uuid>,
}

impl WebhookResponse {
    fn ignored(status: &'static str) -> Self {
        Self {
            status,
            job_id: None,
        }
    }
}

#[derive(Debug, Serialize)]
struct StatusResponse {
    status: &'static str,
}

pub struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: &'static str,
}

impl ApiError {
    fn new(status: StatusCode, code: &'static str, message: &'static str) -> Self {
        Self {
            status,
            code,
            message,
        }
    }

    fn bad_request(code: &'static str, message: &'static str) -> Self {
        Self::new(StatusCode::BAD_REQUEST, code, message)
    }

    fn internal() -> Self {
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal_error",
            "internal service error",
        )
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(ErrorResponse {
                error: self.code,
                message: self.message,
            }),
        )
            .into_response()
    }
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    error: &'static str,
    message: &'static str,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn admin_hash_comparison_rejects_wrong_values() {
        let expected = Sha256::digest(b"expected-token");
        let same = Sha256::digest(b"expected-token");
        let wrong = Sha256::digest(b"wrong-token");
        assert!(bool::from(expected.ct_eq(&same)));
        assert!(!bool::from(expected.ct_eq(&wrong)));
    }
}
