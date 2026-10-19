//! PostgreSQL audit, confirmation, and workspace metadata store.

use std::time::Duration;

use chrono::Utc;
use coding_bot_domain::{AuditEvent, ConfirmationScope, PreparedConfirmation, WorkspaceDescriptor};
use sha2::{Digest, Sha256};
use sqlx::{pool::PoolConnection, PgPool, Postgres};
use thiserror::Error;
use uuid::Uuid;

#[derive(Clone)]
pub struct PostgresStore {
    pool: PgPool,
}

impl PostgresStore {
    #[must_use]
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn migrate(&self) -> Result<(), StoreError> {
        sqlx::migrate!("../../migrations").run(&self.pool).await?;
        Ok(())
    }

    /// Holds a PostgreSQL advisory lock for this process lifetime so two MCP
    /// controllers cannot race over Docker workspace cleanup or confirmations.
    pub async fn acquire_controller_lock(&self) -> Result<PoolConnection<Postgres>, StoreError> {
        const LOCK_ID: i64 = 0x4845_524D_4553_4748;
        let mut connection = self.pool.acquire().await?;
        let acquired = sqlx::query_scalar::<_, bool>("SELECT pg_try_advisory_lock($1)")
            .bind(LOCK_ID)
            .fetch_one(&mut *connection)
            .await?;
        if !acquired {
            return Err(StoreError::Invalid(
                "another Hermes GitHub MCP controller already holds the singleton lock".to_owned(),
            ));
        }
        Ok(connection)
    }

    pub async fn record_audit(&self, event: &AuditEvent) -> Result<(), StoreError> {
        sqlx::query(
            "INSERT INTO audit_events \
             (actor, tool, owner, repository, target, outcome, details) \
             VALUES ($1, $2, $3, $4, $5, $6, $7)",
        )
        .bind(&event.actor)
        .bind(&event.tool)
        .bind(&event.owner)
        .bind(&event.repository)
        .bind(&event.target)
        .bind(&event.outcome)
        .bind(&event.details)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn prepare_confirmation(
        &self,
        scope: &ConfirmationScope,
        ttl: Duration,
        summary: String,
    ) -> Result<PreparedConfirmation, StoreError> {
        let ttl = chrono::Duration::from_std(ttl)
            .map_err(|_| StoreError::Invalid("confirmation TTL is out of range".to_owned()))?;
        let expires_at = Utc::now() + ttl;
        let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        let token_hash = hash_token(&token);
        sqlx::query(
            "INSERT INTO confirmation_challenges \
             (id, token_hash, actor, action, owner, repository, target_number, \
              expected_head_sha, qualifier, expires_at) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        )
        .bind(Uuid::new_v4())
        .bind(token_hash.as_slice())
        .bind(&scope.actor)
        .bind(scope.action.as_str())
        .bind(&scope.owner)
        .bind(&scope.repository)
        .bind(to_i64(scope.target_number)?)
        .bind(&scope.expected_head_sha)
        .bind(&scope.qualifier)
        .bind(expires_at)
        .execute(&self.pool)
        .await?;
        Ok(PreparedConfirmation {
            confirmation_token: token,
            expires_at,
            summary,
        })
    }

    /// Atomically consumes a challenge. A token can authorize exactly one matching action.
    pub async fn consume_confirmation(
        &self,
        token: &str,
        scope: &ConfirmationScope,
    ) -> Result<bool, StoreError> {
        if token.len() != 64 || !token.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Ok(false);
        }
        let token_hash = hash_token(token);
        let consumed = sqlx::query_scalar::<_, Uuid>(
            "UPDATE confirmation_challenges SET consumed_at = now() \
             WHERE token_hash = $1 AND consumed_at IS NULL AND expires_at > now() \
               AND actor = $2 AND action = $3 AND owner = $4 AND repository = $5 \
               AND target_number = $6 AND expected_head_sha IS NOT DISTINCT FROM $7 \
               AND qualifier IS NOT DISTINCT FROM $8 \
             RETURNING id",
        )
        .bind(token_hash.as_slice())
        .bind(&scope.actor)
        .bind(scope.action.as_str())
        .bind(&scope.owner)
        .bind(&scope.repository)
        .bind(to_i64(scope.target_number)?)
        .bind(&scope.expected_head_sha)
        .bind(&scope.qualifier)
        .fetch_optional(&self.pool)
        .await?;
        Ok(consumed.is_some())
    }

    pub async fn record_workspace(
        &self,
        workspace: &WorkspaceDescriptor,
        installation_id: u64,
    ) -> Result<(), StoreError> {
        sqlx::query(
            "INSERT INTO mcp_workspaces \
             (id, actor, owner, repository, installation_id, base_ref, base_sha, \
              branch_name, created_at, expires_at, status) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'active')",
        )
        .bind(workspace.id)
        .bind(&workspace.actor)
        .bind(&workspace.owner)
        .bind(&workspace.repository)
        .bind(to_i64(installation_id)?)
        .bind(&workspace.base_ref)
        .bind(&workspace.base_sha)
        .bind(&workspace.branch_name)
        .bind(workspace.created_at)
        .bind(workspace.expires_at)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn touch_workspace(&self, id: Uuid) -> Result<bool, StoreError> {
        let result = sqlx::query(
            "UPDATE mcp_workspaces SET last_active_at = now() \
             WHERE id = $1 AND status = 'active' AND expires_at > now()",
        )
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn finish_workspace(&self, id: Uuid, status: &str) -> Result<(), StoreError> {
        if !matches!(status, "published" | "closed" | "expired" | "failed") {
            return Err(StoreError::Invalid("invalid workspace status".to_owned()));
        }
        sqlx::query(
            "UPDATE mcp_workspaces SET status = $1, finished_at = now() \
             WHERE id = $2 AND status = 'active'",
        )
        .bind(status)
        .bind(id)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// A fresh controller has no in-memory handle for workspaces from an older
    /// process, so all formerly active rows are unrecoverable and must expire.
    pub async fn recover_abandoned_workspaces(&self) -> Result<Vec<Uuid>, StoreError> {
        Ok(sqlx::query_scalar::<_, Uuid>(
            "UPDATE mcp_workspaces SET status = 'expired', finished_at = now() \
             WHERE status = 'active' RETURNING id",
        )
        .fetch_all(&self.pool)
        .await?)
    }
}

fn hash_token(token: &str) -> [u8; 32] {
    Sha256::digest(token.as_bytes()).into()
}

fn to_i64(value: u64) -> Result<i64, StoreError> {
    i64::try_from(value)
        .map_err(|_| StoreError::Invalid("number exceeds PostgreSQL range".to_owned()))
}

#[derive(Debug, Error)]
pub enum StoreError {
    #[error(transparent)]
    Database(#[from] sqlx::Error),
    #[error(transparent)]
    Migrate(#[from] sqlx::migrate::MigrateError),
    #[error("invalid store input: {0}")]
    Invalid(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn confirmation_tokens_are_high_entropy_and_stored_as_hashes() {
        let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        assert_eq!(token.len(), 64);
        assert_ne!(hash_token(&token).as_slice(), token.as_bytes());
    }
}
