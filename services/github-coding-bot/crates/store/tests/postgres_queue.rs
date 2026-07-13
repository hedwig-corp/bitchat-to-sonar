use coding_bot_domain::NewCodingJob;
use coding_bot_store::{EnqueueResult, PostgresStore};
use sqlx::postgres::PgPoolOptions;
use uuid::Uuid;

#[tokio::test]
#[ignore = "requires a disposable PostgreSQL database in DATABASE_URL"]
async fn concurrent_enqueue_allows_only_one_active_job() {
    let database_url = match std::env::var("DATABASE_URL") {
        Ok(value) => value,
        Err(error) => panic!("DATABASE_URL is required for this ignored integration test: {error}"),
    };
    let pool = match PgPoolOptions::new()
        .max_connections(4)
        .connect(&database_url)
        .await
    {
        Ok(pool) => pool,
        Err(error) => panic!("failed to connect to PostgreSQL: {error}"),
    };
    let store = PostgresStore::new(pool);
    if let Err(error) = store.migrate().await {
        panic!("failed to run migrations: {error}");
    }
    let repository_id = (Uuid::new_v4().as_u128() % 9_000_000_000_u128) as u64 + 1;
    let first_delivery = Uuid::new_v4().to_string();
    let second_delivery = Uuid::new_v4().to_string();
    let base = NewCodingJob {
        delivery_id: first_delivery.clone(),
        repository_id,
        repository_owner: "owner".to_owned(),
        repository_name: "repository".to_owned(),
        issue_number: 42,
        installation_id: 9,
        base_branch: "main".to_owned(),
    };
    let mut second = base.clone();
    second.delivery_id = second_delivery.clone();
    let (first, second) = tokio::join!(
        store.enqueue("issues", base),
        store.enqueue("issues", second)
    );
    let results = [first, second];
    assert_eq!(
        results
            .iter()
            .filter(|result| matches!(result, Ok(EnqueueResult::Queued(_))))
            .count(),
        1
    );
    assert_eq!(
        results
            .iter()
            .filter(|result| matches!(result, Ok(EnqueueResult::DuplicateActiveJob)))
            .count(),
        1
    );

    let repository_id = i64::try_from(repository_id).unwrap_or(i64::MAX);
    if let Err(error) = sqlx::query("DELETE FROM coding_jobs WHERE repository_id = $1")
        .bind(repository_id)
        .execute(store.pool())
        .await
    {
        panic!("failed to clean test jobs: {error}");
    }
    if let Err(error) =
        sqlx::query("DELETE FROM webhook_deliveries WHERE delivery_id = $1 OR delivery_id = $2")
            .bind(first_delivery)
            .bind(second_delivery)
            .execute(store.pool())
            .await
    {
        panic!("failed to clean test deliveries: {error}");
    }
}
