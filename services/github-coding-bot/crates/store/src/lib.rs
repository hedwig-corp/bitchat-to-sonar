//! PostgreSQL-backed durable job queue.

use std::{str::FromStr, time::Duration};

use chrono::{DateTime, Utc};
use coding_bot_domain::{CodingJob, JobStatus, NewCodingJob};
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use thiserror::Error;
use uuid::Uuid;

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("../../migrations");

#[derive(Clone)]
pub struct PostgresStore {
    pool: PgPool,
}

impl PostgresStore {
    #[must_use]
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub async fn migrate(&self) -> Result<(), StoreError> {
        MIGRATOR.run(&self.pool).await?;
        Ok(())
    }

    pub async fn ping(&self) -> Result<(), StoreError> {
        sqlx::query("SELECT 1").execute(&self.pool).await?;
        Ok(())
    }

    pub async fn enqueue(
        &self,
        event_name: &str,
        new_job: NewCodingJob,
    ) -> Result<EnqueueResult, StoreError> {
        let mut transaction = self.pool.begin().await?;
        let delivery_insert = sqlx::query(
            "INSERT INTO webhook_deliveries (delivery_id, event_name) VALUES ($1, $2) \
             ON CONFLICT (delivery_id) DO NOTHING",
        )
        .bind(&new_job.delivery_id)
        .bind(event_name)
        .execute(&mut *transaction)
        .await?;

        if delivery_insert.rows_affected() == 0 {
            transaction.rollback().await?;
            return Ok(EnqueueResult::DuplicateDelivery);
        }

        let id = Uuid::new_v4();
        let row = sqlx::query_as::<_, JobRow>(
            "INSERT INTO coding_jobs (\
                 id, repository_id, repository_owner, repository_name, issue_number, \
                 installation_id, base_branch, status\
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, 'pending') \
             ON CONFLICT DO NOTHING \
             RETURNING *",
        )
        .bind(id)
        .bind(to_i64("repository_id", new_job.repository_id)?)
        .bind(&new_job.repository_owner)
        .bind(&new_job.repository_name)
        .bind(to_i64("issue_number", new_job.issue_number)?)
        .bind(to_i64("installation_id", new_job.installation_id)?)
        .bind(&new_job.base_branch)
        .fetch_optional(&mut *transaction)
        .await?;

        transaction.commit().await?;
        row.map(TryInto::try_into).transpose().map(|job| {
            job.map_or(EnqueueResult::DuplicateActiveJob, |job| {
                EnqueueResult::Queued(Box::new(job))
            })
        })
    }

    pub async fn claim(
        &self,
        worker_id: &str,
        lease_duration: Duration,
    ) -> Result<Option<CodingJob>, StoreError> {
        let lease_seconds = duration_seconds(lease_duration)?;
        let mut transaction = self.pool.begin().await?;

        sqlx::query(
            "UPDATE coding_jobs SET status = 'cancelled', finished_at = now(), \
                 lease_expires_at = NULL \
             WHERE status = 'running' AND cancel_requested AND lease_expires_at < now()",
        )
        .execute(&mut *transaction)
        .await?;

        let row = sqlx::query_as::<_, JobRow>(
            "WITH candidate AS (\
                 SELECT id FROM coding_jobs \
                 WHERE status = 'pending' \
                    OR (status = 'running' AND lease_expires_at < now() AND NOT cancel_requested) \
                 ORDER BY created_at, id \
                 FOR UPDATE SKIP LOCKED \
                 LIMIT 1\
             ) \
             UPDATE coding_jobs AS jobs SET \
                 status = 'running', \
                 attempt = jobs.attempt + 1, \
                 started_at = COALESCE(jobs.started_at, now()), \
                 lease_expires_at = now() + ($1 * interval '1 second'), \
                 error_message = NULL \
             FROM candidate \
             WHERE jobs.id = candidate.id \
             RETURNING jobs.*",
        )
        .bind(lease_seconds)
        .fetch_optional(&mut *transaction)
        .await?;

        let Some(row) = row else {
            self.heartbeat_in(&mut transaction, worker_id, None).await?;
            transaction.commit().await?;
            return Ok(None);
        };

        self.heartbeat_in(&mut transaction, worker_id, Some(row.id))
            .await?;
        transaction.commit().await?;
        Ok(Some(row.try_into()?))
    }

    pub async fn renew_lease(
        &self,
        worker_id: &str,
        job_id: Uuid,
        attempt: u32,
        lease_duration: Duration,
    ) -> Result<bool, StoreError> {
        let mut transaction = self.pool.begin().await?;
        let result = sqlx::query(
            "UPDATE coding_jobs SET lease_expires_at = now() + ($1 * interval '1 second') \
             WHERE id = $2 AND attempt = $3 AND status = 'running' AND NOT cancel_requested",
        )
        .bind(duration_seconds(lease_duration)?)
        .bind(job_id)
        .bind(to_i32("attempt", attempt)?)
        .execute(&mut *transaction)
        .await?;
        self.heartbeat_in(&mut transaction, worker_id, Some(job_id))
            .await?;
        transaction.commit().await?;
        Ok(result.rows_affected() == 1)
    }

    pub async fn heartbeat(
        &self,
        worker_id: &str,
        current_job_id: Option<Uuid>,
    ) -> Result<(), StoreError> {
        let mut transaction = self.pool.begin().await?;
        self.heartbeat_in(&mut transaction, worker_id, current_job_id)
            .await?;
        transaction.commit().await?;
        Ok(())
    }

    async fn heartbeat_in(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
        worker_id: &str,
        current_job_id: Option<Uuid>,
    ) -> Result<(), StoreError> {
        sqlx::query(
            "INSERT INTO worker_heartbeats (worker_id, last_seen_at, current_job_id) \
             VALUES ($1, now(), $2) \
             ON CONFLICT (worker_id) DO UPDATE SET \
                 last_seen_at = EXCLUDED.last_seen_at, \
                 current_job_id = EXCLUDED.current_job_id",
        )
        .bind(worker_id)
        .bind(current_job_id)
        .execute(&mut **transaction)
        .await?;
        Ok(())
    }

    pub async fn worker_available(&self, maximum_age: Duration) -> Result<bool, StoreError> {
        let available = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS (\
                 SELECT 1 FROM worker_heartbeats \
                 WHERE last_seen_at >= now() - ($1 * interval '1 second')\
             )",
        )
        .bind(duration_seconds(maximum_age)?)
        .fetch_one(&self.pool)
        .await?;
        Ok(available)
    }

    pub async fn remove_worker(&self, worker_id: &str) -> Result<(), StoreError> {
        sqlx::query("DELETE FROM worker_heartbeats WHERE worker_id = $1")
            .bind(worker_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn get(&self, id: Uuid) -> Result<Option<CodingJob>, StoreError> {
        sqlx::query_as::<_, JobRow>("SELECT * FROM coding_jobs WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await?
            .map(TryInto::try_into)
            .transpose()
    }

    pub async fn cancel(&self, id: Uuid) -> Result<Option<CodingJob>, StoreError> {
        sqlx::query_as::<_, JobRow>(
            "UPDATE coding_jobs SET \
                 cancel_requested = TRUE, \
                 status = CASE WHEN status = 'pending' THEN 'cancelled' ELSE status END, \
                 finished_at = CASE WHEN status = 'pending' THEN now() ELSE finished_at END, \
                 lease_expires_at = CASE WHEN status = 'pending' THEN NULL ELSE lease_expires_at END \
             WHERE id = $1 AND status IN ('pending', 'running') \
             RETURNING *",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?
        .map(TryInto::try_into)
        .transpose()
    }

    pub async fn cancellation_requested(&self, id: Uuid) -> Result<bool, StoreError> {
        let requested = sqlx::query_scalar::<_, bool>(
            "SELECT cancel_requested OR status = 'cancelled' FROM coding_jobs WHERE id = $1",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await?
        .ok_or(StoreError::NotFound(id))?;
        Ok(requested)
    }

    pub async fn record_branch(&self, id: Uuid, branch: &str) -> Result<(), StoreError> {
        update_text(&self.pool, id, "branch_name", branch).await
    }

    pub async fn record_pull_request(&self, id: Uuid, number: u64) -> Result<(), StoreError> {
        let result = sqlx::query(
            "UPDATE coding_jobs SET pull_request_number = $1 WHERE id = $2 AND status = 'running'",
        )
        .bind(to_i64("pull_request_number", number)?)
        .bind(id)
        .execute(&self.pool)
        .await?;
        ensure_updated(result.rows_affected(), id)
    }

    pub async fn succeed(&self, id: Uuid, attempt: u32) -> Result<(), StoreError> {
        self.finish(id, attempt, JobStatus::Succeeded, None).await
    }

    pub async fn fail(&self, id: Uuid, attempt: u32, public_error: &str) -> Result<(), StoreError> {
        self.finish(id, attempt, JobStatus::Failed, Some(public_error))
            .await
    }

    pub async fn finish_cancelled(&self, id: Uuid, attempt: u32) -> Result<(), StoreError> {
        self.finish(id, attempt, JobStatus::Cancelled, None).await
    }

    async fn finish(
        &self,
        id: Uuid,
        attempt: u32,
        status: JobStatus,
        error_message: Option<&str>,
    ) -> Result<(), StoreError> {
        let result = sqlx::query(
            "UPDATE coding_jobs SET status = $1, finished_at = now(), lease_expires_at = NULL, \
                 error_message = $2 \
             WHERE id = $3 AND attempt = $4 AND status = 'running'",
        )
        .bind(status.as_str())
        .bind(error_message)
        .bind(id)
        .bind(to_i32("attempt", attempt)?)
        .execute(&self.pool)
        .await?;
        ensure_updated(result.rows_affected(), id)
    }
}

async fn update_text(
    pool: &PgPool,
    id: Uuid,
    column: &'static str,
    value: &str,
) -> Result<(), StoreError> {
    let sql = match column {
        "branch_name" => {
            "UPDATE coding_jobs SET branch_name = $1 WHERE id = $2 AND status = 'running'"
        }
        _ => {
            return Err(StoreError::InvalidData(format!(
                "unsupported update column {column}"
            )))
        }
    };
    let result = sqlx::query(sql).bind(value).bind(id).execute(pool).await?;
    ensure_updated(result.rows_affected(), id)
}

fn ensure_updated(rows: u64, id: Uuid) -> Result<(), StoreError> {
    if rows == 1 {
        Ok(())
    } else {
        Err(StoreError::StaleJob(id))
    }
}

fn duration_seconds(duration: Duration) -> Result<i64, StoreError> {
    i64::try_from(duration.as_secs())
        .map_err(|_| StoreError::InvalidData("duration exceeds PostgreSQL range".to_owned()))
}

fn to_i64(field: &'static str, value: u64) -> Result<i64, StoreError> {
    i64::try_from(value).map_err(|_| StoreError::NumericOverflow { field, value })
}

fn to_i32(field: &'static str, value: u32) -> Result<i32, StoreError> {
    i32::try_from(value).map_err(|_| StoreError::NumericOverflow {
        field,
        value: u64::from(value),
    })
}

fn from_i64(field: &'static str, value: i64) -> Result<u64, StoreError> {
    u64::try_from(value)
        .map_err(|_| StoreError::InvalidData(format!("negative {field} in database")))
}

fn from_i32(field: &'static str, value: i32) -> Result<u32, StoreError> {
    u32::try_from(value)
        .map_err(|_| StoreError::InvalidData(format!("negative {field} in database")))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnqueueResult {
    Queued(Box<CodingJob>),
    DuplicateDelivery,
    DuplicateActiveJob,
}

#[derive(Debug, FromRow)]
struct JobRow {
    id: Uuid,
    repository_id: i64,
    repository_owner: String,
    repository_name: String,
    issue_number: i64,
    installation_id: i64,
    base_branch: String,
    status: String,
    attempt: i32,
    created_at: DateTime<Utc>,
    started_at: Option<DateTime<Utc>>,
    finished_at: Option<DateTime<Utc>>,
    lease_expires_at: Option<DateTime<Utc>>,
    cancel_requested: bool,
    error_message: Option<String>,
    branch_name: Option<String>,
    pull_request_number: Option<i64>,
}

impl TryFrom<JobRow> for CodingJob {
    type Error = StoreError;

    fn try_from(row: JobRow) -> Result<Self, Self::Error> {
        Ok(Self {
            id: row.id,
            repository_id: from_i64("repository_id", row.repository_id)?,
            repository_owner: row.repository_owner,
            repository_name: row.repository_name,
            issue_number: from_i64("issue_number", row.issue_number)?,
            installation_id: from_i64("installation_id", row.installation_id)?,
            base_branch: row.base_branch,
            status: JobStatus::from_str(&row.status)
                .map_err(|error| StoreError::InvalidData(error.to_string()))?,
            attempt: from_i32("attempt", row.attempt)?,
            created_at: row.created_at,
            started_at: row.started_at,
            finished_at: row.finished_at,
            lease_expires_at: row.lease_expires_at,
            cancel_requested: row.cancel_requested,
            error_message: row.error_message,
            branch_name: row.branch_name,
            pull_request_number: row
                .pull_request_number
                .map(|value| from_i64("pull_request_number", value))
                .transpose()?,
        })
    }
}

#[derive(Debug, Error)]
pub enum StoreError {
    #[error(transparent)]
    Sqlx(#[from] sqlx::Error),
    #[error(transparent)]
    Migration(#[from] sqlx::migrate::MigrateError),
    #[error("{field} value {value} exceeds the PostgreSQL BIGINT range")]
    NumericOverflow { field: &'static str, value: u64 },
    #[error("invalid database data: {0}")]
    InvalidData(String),
    #[error("job {0} was not found")]
    NotFound(Uuid),
    #[error("job {0} is no longer owned by this worker attempt")]
    StaleJob(Uuid),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_github_ids_outside_postgres_range() {
        assert!(matches!(
            to_i64("repository_id", u64::MAX),
            Err(StoreError::NumericOverflow { .. })
        ));
    }
}
