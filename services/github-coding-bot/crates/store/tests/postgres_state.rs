use std::time::Duration;

use coding_bot_domain::{ConfirmationAction, ConfirmationScope};
use coding_bot_store::PostgresStore;
use sqlx::postgres::PgPoolOptions;

#[tokio::test]
#[ignore = "requires a disposable PostgreSQL DATABASE_URL"]
async fn confirmation_is_bound_single_use_and_actor_scoped() {
    let database_url = std::env::var("DATABASE_URL").expect("DATABASE_URL is required");
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&database_url)
        .await
        .expect("connect PostgreSQL");
    let store = PostgresStore::new(pool);
    store.migrate().await.expect("run migrations");

    let scope = ConfirmationScope {
        actor: "npub1alice".to_owned(),
        action: ConfirmationAction::MergePullRequest,
        owner: "acme".to_owned(),
        repository: "widgets".to_owned(),
        target_number: 42,
        expected_head_sha: Some("0123456789012345678901234567890123456789".to_owned()),
        qualifier: Some("squash".to_owned()),
    };
    let prepared = store
        .prepare_confirmation(&scope, Duration::from_secs(60), "test merge".to_owned())
        .await
        .expect("prepare confirmation");

    let mut wrong_actor = scope.clone();
    wrong_actor.actor = "npub1mallory".to_owned();
    assert!(!store
        .consume_confirmation(&prepared.confirmation_token, &wrong_actor)
        .await
        .expect("reject wrong actor"));
    assert!(store
        .consume_confirmation(&prepared.confirmation_token, &scope)
        .await
        .expect("consume exact scope"));
    assert!(!store
        .consume_confirmation(&prepared.confirmation_token, &scope)
        .await
        .expect("reject replay"));
}
