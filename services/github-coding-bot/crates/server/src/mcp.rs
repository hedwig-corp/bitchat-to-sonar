use std::{sync::Arc, time::Duration};

use coding_bot_config::Config;
use coding_bot_domain::{AuditEvent, ConfirmationAction, ConfirmationScope};
use coding_bot_github::{bounded_json, GitHubApp, RepositoryClient};
use coding_bot_store::PostgresStore;
use coding_bot_worker::{validate_git_ref, Workspace, WorkspaceManager};
use rmcp::{
    handler::server::wrapper::Parameters, schemars, schemars::JsonSchema, tool, tool_router,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use uuid::Uuid;

#[derive(Clone)]
pub struct HermesGitHubServer {
    config: Arc<Config>,
    github: Arc<GitHubApp>,
    store: Arc<PostgresStore>,
    workspaces: Arc<WorkspaceManager>,
}

impl HermesGitHubServer {
    #[must_use]
    pub fn new(
        config: Arc<Config>,
        github: Arc<GitHubApp>,
        store: Arc<PostgresStore>,
        workspaces: Arc<WorkspaceManager>,
    ) -> Self {
        Self {
            config,
            github,
            store,
            workspaces,
        }
    }

    async fn repository(
        &self,
        tool: &str,
        scope: &RepoScope,
    ) -> Result<(String, RepositoryClient), String> {
        let actor = normalize_actor(&scope.actor)?;
        if !self.config.actor_allowed(&actor) {
            self.audit(AuditEvent {
                actor: actor.clone(),
                tool: tool.to_owned(),
                owner: Some(scope.owner.clone()),
                repository: Some(scope.repository.clone()),
                target: None,
                outcome: "denied_actor".to_owned(),
                details: json!({}),
            })
            .await?;
            return Err("Sonar sender is not authorized for GitHub tools".to_owned());
        }
        if !self
            .config
            .repository_allowed(&scope.owner, &scope.repository)
        {
            self.audit(AuditEvent {
                actor: actor.clone(),
                tool: tool.to_owned(),
                owner: Some(scope.owner.clone()),
                repository: Some(scope.repository.clone()),
                target: None,
                outcome: "denied_repository".to_owned(),
                details: json!({}),
            })
            .await?;
            return Err("repository is outside the configured allowlist".to_owned());
        }
        let client = match self
            .github
            .repository(&scope.owner, &scope.repository)
            .await
        {
            Ok(client) => client,
            Err(error) => {
                self.audit_repo(&actor, tool, scope, None, "github_access_error", json!({}))
                    .await?;
                return Err(format!("GitHub App installation access failed: {error}"));
            }
        };
        Ok((actor, client))
    }

    async fn workspace(
        &self,
        actor: &str,
        workspace_id: &str,
    ) -> Result<(String, Arc<Workspace>), String> {
        let actor = normalize_actor(actor)?;
        if !self.config.actor_allowed(&actor) {
            return Err("Sonar sender is not authorized for GitHub tools".to_owned());
        }
        let id = Uuid::parse_str(workspace_id)
            .map_err(|_| "workspace_id must be a UUID returned by workspace_create".to_owned())?;
        let workspace = self
            .workspaces
            .get(id, &actor)
            .await
            .map_err(|error| error.to_string())?;
        let descriptor = workspace.descriptor();
        if !self
            .config
            .repository_allowed(&descriptor.owner, &descriptor.repository)
            || !self
                .store
                .touch_workspace(id)
                .await
                .map_err(|error| format!("workspace metadata failed: {error}"))?
        {
            return Err("workspace is unavailable or expired".to_owned());
        }
        Ok((actor, workspace))
    }

    async fn audit(&self, event: AuditEvent) -> Result<(), String> {
        self.store
            .record_audit(&event)
            .await
            .map_err(|error| format!("durable audit write failed: {error}"))
    }

    async fn audit_repo(
        &self,
        actor: &str,
        tool: &str,
        scope: &RepoScope,
        target: Option<String>,
        outcome: &str,
        details: Value,
    ) -> Result<(), String> {
        self.audit(AuditEvent {
            actor: actor.to_owned(),
            tool: tool.to_owned(),
            owner: Some(scope.owner.clone()),
            repository: Some(scope.repository.clone()),
            target,
            outcome: outcome.to_owned(),
            details,
        })
        .await
    }

    async fn audit_workspace(
        &self,
        actor: &str,
        tool: &str,
        workspace: &Workspace,
        outcome: &str,
        details: Value,
    ) -> Result<(), String> {
        let descriptor = workspace.descriptor();
        self.audit(AuditEvent {
            actor: actor.to_owned(),
            tool: tool.to_owned(),
            owner: Some(descriptor.owner.clone()),
            repository: Some(descriptor.repository.clone()),
            target: Some(descriptor.id.to_string()),
            outcome: outcome.to_owned(),
            details,
        })
        .await
    }

    fn render(&self, value: &Value) -> Result<String, String> {
        bounded_json(value, self.config.limits.max_tool_output_bytes)
            .map_err(|error| format!("response serialization failed: {error}"))
    }

    fn render_serializable(&self, value: &impl Serialize) -> Result<String, String> {
        let value = serde_json::to_value(value)
            .map_err(|error| format!("response serialization failed: {error}"))?;
        self.render(&value)
    }

    fn render_text(&self, value: String) -> String {
        let maximum = self.config.limits.max_tool_output_bytes;
        if value.len() <= maximum {
            return value;
        }
        let mut boundary = maximum.saturating_sub(48);
        while boundary > 0 && !value.is_char_boundary(boundary) {
            boundary -= 1;
        }
        format!("{}\n[tool output truncated]", &value[..boundary])
    }

    async fn complete_api_call(
        &self,
        actor: &str,
        tool: &str,
        scope: &RepoScope,
        target: Option<String>,
        result: Result<Value, coding_bot_github::GitHubError>,
        details: Value,
    ) -> Result<String, String> {
        let outcome = if result.is_ok() { "success" } else { "error" };
        self.audit_repo(actor, tool, scope, target, outcome, details)
            .await?;
        let value = result.map_err(|error| format!("GitHub API operation failed: {error}"))?;
        self.render(&value)
    }
}

#[tool_router(server_handler)]
impl HermesGitHubServer {
    #[tool(
        description = "Read repository metadata as the installed GitHub App. actor must be the exact Sonar sender identifier from the current DM."
    )]
    async fn github_repository_get(
        &self,
        Parameters(scope): Parameters<RepoScope>,
    ) -> Result<String, String> {
        let (actor, repository) = self.repository("github_repository_get", &scope).await?;
        let result = repository.get("", None::<&()>).await;
        self.complete_api_call(
            &actor,
            "github_repository_get",
            &scope,
            None,
            result,
            json!({"operation": "read"}),
        )
        .await
    }

    #[tool(
        description = "List GitHub issues with bounded pagination. Pull requests may appear in GitHub's issues endpoint."
    )]
    async fn github_issue_list(
        &self,
        Parameters(input): Parameters<ListInput>,
    ) -> Result<String, String> {
        validate_page(input.page, input.per_page)?;
        let state = validate_list_state(input.state.as_deref())?;
        let (actor, repository) = self.repository("github_issue_list", &input.repo).await?;
        let query = PageQuery {
            state,
            page: input.page.unwrap_or(1),
            per_page: input.per_page.unwrap_or(30),
        };
        let result = repository.get("/issues", Some(&query)).await;
        self.complete_api_call(
            &actor,
            "github_issue_list",
            &input.repo,
            None,
            result,
            json!({"page": query.page, "per_page": query.per_page}),
        )
        .await
    }

    #[tool(description = "Read one GitHub issue or pull request conversation by number.")]
    async fn github_issue_get(
        &self,
        Parameters(input): Parameters<NumberInput>,
    ) -> Result<String, String> {
        validate_number(input.number)?;
        let (actor, repository) = self.repository("github_issue_get", &input.repo).await?;
        let result = repository
            .get(&format!("/issues/{}", input.number), None::<&()>)
            .await;
        self.complete_api_call(
            &actor,
            "github_issue_get",
            &input.repo,
            Some(format!("issue#{}", input.number)),
            result,
            json!({"operation": "read"}),
        )
        .await
    }

    #[tool(description = "Create a GitHub issue as the dedicated GitHub App identity.")]
    async fn github_issue_create(
        &self,
        Parameters(input): Parameters<CreateIssueInput>,
    ) -> Result<String, String> {
        validate_text("title", &input.title, 1, 256)?;
        validate_optional_text("body", input.body.as_deref(), 65_536)?;
        validate_labels(&input.labels)?;
        validate_assignees(&input.assignees)?;
        let (actor, repository) = self.repository("github_issue_create", &input.repo).await?;
        let body = json!({
            "title": input.title,
            "body": input.body,
            "labels": input.labels,
            "assignees": input.assignees,
        });
        self.audit_repo(
            &actor,
            "github_issue_create",
            &input.repo,
            None,
            "attempt",
            json!({"title_length": body["title"].as_str().map(str::len)}),
        )
        .await?;
        let result = repository.post("/issues", &body).await;
        self.complete_api_call(
            &actor,
            "github_issue_create",
            &input.repo,
            None,
            result,
            json!({"title_length": body["title"].as_str().map(str::len)}),
        )
        .await
    }

    #[tool(
        description = "Update an issue title, body, labels, assignees, or reopen it. Closing requires the prepare/confirm tools."
    )]
    async fn github_issue_update(
        &self,
        Parameters(input): Parameters<UpdateIssueInput>,
    ) -> Result<String, String> {
        validate_number(input.number)?;
        validate_optional_text("title", input.title.as_deref(), 256)?;
        validate_optional_text("body", input.body.as_deref(), 65_536)?;
        if let Some(state) = &input.state {
            if state != "open" {
                return Err("state may only be `open`; use github_issue_close_prepare and github_issue_close_confirm to close".to_owned());
            }
        }
        if let Some(labels) = &input.labels {
            validate_labels(labels)?;
        }
        if let Some(assignees) = &input.assignees {
            validate_assignees(assignees)?;
        }
        let mut body = Map::new();
        insert_optional(&mut body, "title", input.title);
        insert_optional(&mut body, "body", input.body);
        insert_optional(&mut body, "state", input.state);
        insert_optional(&mut body, "labels", input.labels);
        insert_optional(&mut body, "assignees", input.assignees);
        if body.is_empty() {
            return Err("at least one issue field must be supplied".to_owned());
        }
        let changed_fields = body.keys().cloned().collect::<Vec<_>>();
        let (actor, repository) = self.repository("github_issue_update", &input.repo).await?;
        self.audit_repo(
            &actor,
            "github_issue_update",
            &input.repo,
            Some(format!("issue#{}", input.number)),
            "attempt",
            json!({"changed_fields": changed_fields}),
        )
        .await?;
        let result = repository
            .patch(&format!("/issues/{}", input.number), &body)
            .await;
        self.complete_api_call(
            &actor,
            "github_issue_update",
            &input.repo,
            Some(format!("issue#{}", input.number)),
            result,
            json!({"changed_fields": changed_fields}),
        )
        .await
    }

    #[tool(
        description = "Comment on an issue or pull request as the dedicated GitHub App identity."
    )]
    async fn github_comment_create(
        &self,
        Parameters(input): Parameters<CommentInput>,
    ) -> Result<String, String> {
        validate_number(input.number)?;
        validate_text("body", &input.body, 1, 65_536)?;
        let (actor, repository) = self
            .repository("github_comment_create", &input.repo)
            .await?;
        self.audit_repo(
            &actor,
            "github_comment_create",
            &input.repo,
            Some(format!("conversation#{}", input.number)),
            "attempt",
            json!({"body_length": input.body.len()}),
        )
        .await?;
        let result = repository
            .post(
                &format!("/issues/{}/comments", input.number),
                &json!({"body": input.body}),
            )
            .await;
        self.complete_api_call(
            &actor,
            "github_comment_create",
            &input.repo,
            Some(format!("conversation#{}", input.number)),
            result,
            json!({"body_length": input.body.len()}),
        )
        .await
    }

    #[tool(description = "List pull requests with bounded pagination.")]
    async fn github_pull_request_list(
        &self,
        Parameters(input): Parameters<ListInput>,
    ) -> Result<String, String> {
        validate_page(input.page, input.per_page)?;
        let state = validate_list_state(input.state.as_deref())?;
        let (actor, repository) = self
            .repository("github_pull_request_list", &input.repo)
            .await?;
        let query = PageQuery {
            state,
            page: input.page.unwrap_or(1),
            per_page: input.per_page.unwrap_or(30),
        };
        let result = repository.get("/pulls", Some(&query)).await;
        self.complete_api_call(
            &actor,
            "github_pull_request_list",
            &input.repo,
            None,
            result,
            json!({"page": query.page, "per_page": query.per_page}),
        )
        .await
    }

    #[tool(description = "Read pull request metadata, including current head SHA and merge state.")]
    async fn github_pull_request_get(
        &self,
        Parameters(input): Parameters<NumberInput>,
    ) -> Result<String, String> {
        validate_number(input.number)?;
        let (actor, repository) = self
            .repository("github_pull_request_get", &input.repo)
            .await?;
        let result = repository
            .get(&format!("/pulls/{}", input.number), None::<&()>)
            .await;
        self.complete_api_call(
            &actor,
            "github_pull_request_get",
            &input.repo,
            Some(format!("pull#{}", input.number)),
            result,
            json!({"operation": "read"}),
        )
        .await
    }

    #[tool(description = "Read the changed files and bounded patch fragments for a pull request.")]
    async fn github_pull_request_files(
        &self,
        Parameters(input): Parameters<NumberPageInput>,
    ) -> Result<String, String> {
        validate_number(input.number)?;
        validate_page(input.page, input.per_page)?;
        let (actor, repository) = self
            .repository("github_pull_request_files", &input.repo)
            .await?;
        let query = SimplePageQuery {
            page: input.page.unwrap_or(1),
            per_page: input.per_page.unwrap_or(30),
        };
        let result = repository
            .get(&format!("/pulls/{}/files", input.number), Some(&query))
            .await;
        self.complete_api_call(
            &actor,
            "github_pull_request_files",
            &input.repo,
            Some(format!("pull#{}", input.number)),
            result,
            json!({"page": query.page, "per_page": query.per_page}),
        )
        .await
    }

    #[tool(
        description = "Read general comments, submitted reviews, and inline review comments for a pull request with bounded pagination."
    )]
    async fn github_pull_request_feedback(
        &self,
        Parameters(input): Parameters<NumberPageInput>,
    ) -> Result<String, String> {
        validate_number(input.number)?;
        validate_page(input.page, input.per_page)?;
        let (actor, repository) = self
            .repository("github_pull_request_feedback", &input.repo)
            .await?;
        let query = SimplePageQuery {
            page: input.page.unwrap_or(1),
            per_page: input.per_page.unwrap_or(30),
        };
        let result = async {
            let comments = repository
                .get(&format!("/issues/{}/comments", input.number), Some(&query))
                .await?;
            let reviews = repository
                .get(&format!("/pulls/{}/reviews", input.number), Some(&query))
                .await?;
            let inline_comments = repository
                .get(&format!("/pulls/{}/comments", input.number), Some(&query))
                .await?;
            Ok(json!({
                "conversation_comments": comments,
                "reviews": reviews,
                "inline_review_comments": inline_comments,
            }))
        }
        .await;
        self.complete_api_call(
            &actor,
            "github_pull_request_feedback",
            &input.repo,
            Some(format!("pull#{}", input.number)),
            result,
            json!({"page": query.page, "per_page": query.per_page}),
        )
        .await
    }

    #[tool(description = "Read check runs for an exact 40-character commit SHA.")]
    async fn github_commit_checks(
        &self,
        Parameters(input): Parameters<ChecksInput>,
    ) -> Result<String, String> {
        validate_sha(&input.commit_sha)?;
        validate_page(input.page, input.per_page)?;
        let (actor, repository) = self.repository("github_commit_checks", &input.repo).await?;
        let query = SimplePageQuery {
            page: input.page.unwrap_or(1),
            per_page: input.per_page.unwrap_or(30),
        };
        let result = repository
            .get(
                &format!("/commits/{}/check-runs", input.commit_sha),
                Some(&query),
            )
            .await;
        self.complete_api_call(
            &actor,
            "github_commit_checks",
            &input.repo,
            Some(input.commit_sha.clone()),
            result,
            json!({"page": query.page, "per_page": query.per_page}),
        )
        .await
    }

    #[tool(
        description = "Submit a COMMENT, APPROVE, or REQUEST_CHANGES pull request review as the GitHub App."
    )]
    async fn github_pull_request_review(
        &self,
        Parameters(input): Parameters<ReviewInput>,
    ) -> Result<String, String> {
        validate_number(input.number)?;
        validate_text("body", &input.body, 1, 65_536)?;
        let event = input.event.to_ascii_uppercase();
        if !matches!(event.as_str(), "COMMENT" | "APPROVE" | "REQUEST_CHANGES") {
            return Err("event must be COMMENT, APPROVE, or REQUEST_CHANGES".to_owned());
        }
        let (actor, repository) = self
            .repository("github_pull_request_review", &input.repo)
            .await?;
        self.audit_repo(
            &actor,
            "github_pull_request_review",
            &input.repo,
            Some(format!("pull#{}", input.number)),
            "attempt",
            json!({"event": event, "body_length": input.body.len()}),
        )
        .await?;
        let result = repository
            .post(
                &format!("/pulls/{}/reviews", input.number),
                &json!({"body": input.body, "event": event}),
            )
            .await;
        self.complete_api_call(
            &actor,
            "github_pull_request_review",
            &input.repo,
            Some(format!("pull#{}", input.number)),
            result,
            json!({"event": event, "body_length": input.body.len()}),
        )
        .await
    }

    #[tool(
        description = "Open a pull request for an already-pushed branch. Use workspace_publish_branch first for Hermes code changes."
    )]
    async fn github_pull_request_create(
        &self,
        Parameters(input): Parameters<CreatePullInput>,
    ) -> Result<String, String> {
        validate_text("title", &input.title, 1, 256)?;
        validate_optional_text("body", input.body.as_deref(), 65_536)?;
        validate_git_ref(&input.head).map_err(|error| error.to_string())?;
        validate_git_ref(&input.base).map_err(|error| error.to_string())?;
        let (actor, repository) = self
            .repository("github_pull_request_create", &input.repo)
            .await?;
        self.audit_repo(
            &actor,
            "github_pull_request_create",
            &input.repo,
            Some(input.head.clone()),
            "attempt",
            json!({"base": input.base, "draft": input.draft.unwrap_or(true)}),
        )
        .await?;
        let result = repository
            .post(
                "/pulls",
                &json!({
                    "title": input.title,
                    "body": input.body,
                    "head": input.head,
                    "base": input.base,
                    "draft": input.draft.unwrap_or(true),
                }),
            )
            .await;
        self.complete_api_call(
            &actor,
            "github_pull_request_create",
            &input.repo,
            Some(input.head.clone()),
            result,
            json!({"base": input.base, "draft": input.draft.unwrap_or(true)}),
        )
        .await
    }

    #[tool(
        description = "Prepare an issue close. Returns a single-use token and exact summary that Hermes must show before asking the user to confirm."
    )]
    async fn github_issue_close_prepare(
        &self,
        Parameters(input): Parameters<NumberInput>,
    ) -> Result<String, String> {
        validate_number(input.number)?;
        let (actor, repository) = self
            .repository("github_issue_close_prepare", &input.repo)
            .await?;
        let issue = repository
            .get(&format!("/issues/{}", input.number), None::<&()>)
            .await
            .map_err(|error| format!("could not inspect issue: {error}"))?;
        if issue.get("pull_request").is_some() {
            return Err("target is a pull request; use the pull request merge tools".to_owned());
        }
        if issue["state"] != "open" {
            return Err("issue is not open".to_owned());
        }
        let title = confirmation_title(&required_string(&issue, "/title")?);
        let scope = ConfirmationScope {
            actor: actor.clone(),
            action: ConfirmationAction::CloseIssue,
            owner: input.repo.owner.clone(),
            repository: input.repo.repository.clone(),
            target_number: input.number,
            expected_head_sha: None,
            qualifier: None,
        };
        let prepared = self
            .store
            .prepare_confirmation(
                &scope,
                Duration::from_secs(self.config.confirmation_ttl_seconds),
                format!(
                    "Close issue #{number} titled {title:?} in {owner}/{repository}",
                    number = input.number,
                    owner = input.repo.owner,
                    repository = input.repo.repository,
                ),
            )
            .await
            .map_err(|error| format!("could not prepare confirmation: {error}"))?;
        self.audit_repo(
            &actor,
            "github_issue_close_prepare",
            &input.repo,
            Some(format!("issue#{}", input.number)),
            "prepared",
            json!({"expires_at": prepared.expires_at}),
        )
        .await?;
        self.render_serializable(&prepared)
    }

    #[tool(
        description = "Close an issue using the unexpired token returned by github_issue_close_prepare after the user explicitly confirms."
    )]
    async fn github_issue_close_confirm(
        &self,
        Parameters(input): Parameters<ConfirmNumberInput>,
    ) -> Result<String, String> {
        validate_number(input.number)?;
        let (actor, repository) = self
            .repository("github_issue_close_confirm", &input.repo)
            .await?;
        let issue = repository
            .get(&format!("/issues/{}", input.number), None::<&()>)
            .await
            .map_err(|error| format!("could not re-check issue: {error}"))?;
        if issue["state"] != "open" || issue.get("pull_request").is_some() {
            return Err("issue is no longer an open issue".to_owned());
        }
        let scope = ConfirmationScope {
            actor: actor.clone(),
            action: ConfirmationAction::CloseIssue,
            owner: input.repo.owner.clone(),
            repository: input.repo.repository.clone(),
            target_number: input.number,
            expected_head_sha: None,
            qualifier: None,
        };
        self.audit_repo(
            &actor,
            "github_issue_close_confirm",
            &input.repo,
            Some(format!("issue#{}", input.number)),
            "attempt",
            json!({}),
        )
        .await?;
        if !self
            .store
            .consume_confirmation(&input.confirmation_token, &scope)
            .await
            .map_err(|error| format!("could not consume confirmation: {error}"))?
        {
            self.audit_repo(
                &actor,
                "github_issue_close_confirm",
                &input.repo,
                Some(format!("issue#{}", input.number)),
                "denied_confirmation",
                json!({}),
            )
            .await?;
            return Err("confirmation token is invalid, expired, already used, or belongs to another action".to_owned());
        }
        let result = repository
            .patch(
                &format!("/issues/{}", input.number),
                &json!({"state": "closed"}),
            )
            .await;
        self.complete_api_call(
            &actor,
            "github_issue_close_confirm",
            &input.repo,
            Some(format!("issue#{}", input.number)),
            result,
            json!({"confirmation_consumed": true}),
        )
        .await
    }

    #[tool(
        description = "Prepare a pull request merge. Binds a single-use token to the current head SHA and merge method; Hermes must show the exact summary before confirmation."
    )]
    async fn github_pull_request_merge_prepare(
        &self,
        Parameters(input): Parameters<PrepareMergeInput>,
    ) -> Result<String, String> {
        validate_number(input.number)?;
        let merge_method = validate_merge_method(input.merge_method.as_deref())?;
        let (actor, repository) = self
            .repository("github_pull_request_merge_prepare", &input.repo)
            .await?;
        let pull = repository
            .get(&format!("/pulls/{}", input.number), None::<&()>)
            .await
            .map_err(|error| format!("could not inspect pull request: {error}"))?;
        if pull["state"] != "open" || pull["draft"] == true {
            return Err("pull request must be open and ready for review".to_owned());
        }
        let title = confirmation_title(&required_string(&pull, "/title")?);
        let head_sha = required_string(&pull, "/head/sha")?;
        validate_sha(&head_sha)?;
        let scope = ConfirmationScope {
            actor: actor.clone(),
            action: ConfirmationAction::MergePullRequest,
            owner: input.repo.owner.clone(),
            repository: input.repo.repository.clone(),
            target_number: input.number,
            expected_head_sha: Some(head_sha.clone()),
            qualifier: Some(merge_method.clone()),
        };
        let prepared = self
            .store
            .prepare_confirmation(
                &scope,
                Duration::from_secs(self.config.confirmation_ttl_seconds),
                format!(
                    "Merge PR #{number} titled {title:?} at {head_sha} into {owner}/{repository} using {merge_method}",
                    number = input.number,
                    owner = input.repo.owner,
                    repository = input.repo.repository,
                ),
            )
            .await
            .map_err(|error| format!("could not prepare confirmation: {error}"))?;
        self.audit_repo(
            &actor,
            "github_pull_request_merge_prepare",
            &input.repo,
            Some(format!("pull#{}", input.number)),
            "prepared",
            json!({"head_sha": head_sha, "merge_method": merge_method, "expires_at": prepared.expires_at}),
        )
        .await?;
        self.render_serializable(&prepared)
    }

    #[tool(
        description = "Merge a pull request using the unexpired token returned by github_pull_request_merge_prepare after explicit user confirmation."
    )]
    async fn github_pull_request_merge_confirm(
        &self,
        Parameters(input): Parameters<ConfirmMergeInput>,
    ) -> Result<String, String> {
        validate_number(input.number)?;
        let merge_method = validate_merge_method(input.merge_method.as_deref())?;
        let (actor, repository) = self
            .repository("github_pull_request_merge_confirm", &input.repo)
            .await?;
        let pull = repository
            .get(&format!("/pulls/{}", input.number), None::<&()>)
            .await
            .map_err(|error| format!("could not re-check pull request: {error}"))?;
        if pull["state"] != "open" || pull["draft"] == true {
            return Err("pull request is no longer open and ready".to_owned());
        }
        let head_sha = required_string(&pull, "/head/sha")?;
        validate_sha(&head_sha)?;
        let scope = ConfirmationScope {
            actor: actor.clone(),
            action: ConfirmationAction::MergePullRequest,
            owner: input.repo.owner.clone(),
            repository: input.repo.repository.clone(),
            target_number: input.number,
            expected_head_sha: Some(head_sha.clone()),
            qualifier: Some(merge_method.clone()),
        };
        self.audit_repo(
            &actor,
            "github_pull_request_merge_confirm",
            &input.repo,
            Some(format!("pull#{}", input.number)),
            "attempt",
            json!({"current_head_sha": head_sha, "merge_method": merge_method}),
        )
        .await?;
        if !self
            .store
            .consume_confirmation(&input.confirmation_token, &scope)
            .await
            .map_err(|error| format!("could not consume confirmation: {error}"))?
        {
            self.audit_repo(
                &actor,
                "github_pull_request_merge_confirm",
                &input.repo,
                Some(format!("pull#{}", input.number)),
                "denied_confirmation",
                json!({"current_head_sha": head_sha, "merge_method": merge_method}),
            )
            .await?;
            return Err("confirmation token is invalid, expired, already used, or stale because the PR head/method changed".to_owned());
        }
        let result = repository
            .put(
                &format!("/pulls/{}/merge", input.number),
                &json!({"sha": head_sha, "merge_method": merge_method}),
            )
            .await;
        self.complete_api_call(
            &actor,
            "github_pull_request_merge_confirm",
            &input.repo,
            Some(format!("pull#{}", input.number)),
            result,
            json!({"head_sha": head_sha, "merge_method": merge_method, "confirmation_consumed": true}),
        )
        .await
    }

    #[tool(
        description = "Create an isolated, network-off coding workspace from a repository branch. Hermes—not this server—decides what code changes to make."
    )]
    async fn workspace_create(
        &self,
        Parameters(input): Parameters<CreateWorkspaceInput>,
    ) -> Result<String, String> {
        validate_text("task", &input.task, 1, 2048)?;
        let (actor, repository) = self.repository("workspace_create", &input.repo).await?;
        let repository_info = repository
            .get("", None::<&()>)
            .await
            .map_err(|error| format!("could not read repository metadata: {error}"))?;
        let base_ref = input
            .base_ref
            .unwrap_or(required_string(&repository_info, "/default_branch")?);
        validate_git_ref(&base_ref).map_err(|error| error.to_string())?;
        let reference = repository
            .get(&format!("/git/ref/heads/{base_ref}"), None::<&()>)
            .await
            .map_err(|error| format!("could not resolve base branch: {error}"))?;
        let base_sha = required_string(&reference, "/object/sha")?;
        validate_sha(&base_sha)?;
        let installation_id = repository.installation_id();
        let workspace = self
            .workspaces
            .create(
                &actor,
                &input.repo.owner,
                &input.repo.repository,
                &base_ref,
                &base_sha,
                &input.task,
                repository.token(),
            )
            .await
            .map_err(|error| format!("workspace creation failed: {error}"))?;
        if let Err(error) = self
            .store
            .record_workspace(workspace.descriptor(), installation_id)
            .await
        {
            let _ = self
                .workspaces
                .remove(workspace.descriptor().id, &actor)
                .await;
            return Err(format!("workspace metadata write failed: {error}"));
        }
        self.audit_workspace(
            &actor,
            "workspace_create",
            &workspace,
            "success",
            json!({"base_ref": base_ref, "base_sha": base_sha}),
        )
        .await?;
        self.render_serializable(workspace.descriptor())
    }

    #[tool(
        description = "Read bounded repository guidance files (AGENTS.md, CLAUDE.md, CONTRIBUTING.md, README.md) from an isolated workspace."
    )]
    async fn workspace_instructions(
        &self,
        Parameters(input): Parameters<WorkspaceInput>,
    ) -> Result<String, String> {
        let (actor, workspace) = self.workspace(&input.actor, &input.workspace_id).await?;
        let result = workspace
            .instructions()
            .await
            .map_err(|error| error.to_string())?;
        self.audit_workspace(
            &actor,
            "workspace_instructions",
            &workspace,
            "success",
            json!({"bytes": result.len()}),
        )
        .await?;
        Ok(self.render_text(result))
    }

    #[tool(description = "List files in an isolated workspace. Depth is clamped to 1-8.")]
    async fn workspace_list_files(
        &self,
        Parameters(input): Parameters<WorkspaceListInput>,
    ) -> Result<String, String> {
        let (actor, workspace) = self.workspace(&input.actor, &input.workspace_id).await?;
        let result = workspace
            .list_files(input.path.as_deref(), input.max_depth)
            .await
            .map_err(|error| error.to_string())?;
        self.audit_workspace(
            &actor,
            "workspace_list_files",
            &workspace,
            "success",
            json!({"path": input.path, "max_depth": input.max_depth}),
        )
        .await?;
        Ok(self.render_text(result))
    }

    #[tool(
        description = "Search workspace text with a literal, bounded query. The workspace has no network access."
    )]
    async fn workspace_search(
        &self,
        Parameters(input): Parameters<WorkspaceSearchInput>,
    ) -> Result<String, String> {
        let (actor, workspace) = self.workspace(&input.actor, &input.workspace_id).await?;
        let result = workspace
            .search_files(&input.query, input.path.as_deref())
            .await
            .map_err(|error| error.to_string())?;
        self.audit_workspace(
            &actor,
            "workspace_search",
            &workspace,
            "success",
            json!({"path": input.path, "query_length": input.query.len()}),
        )
        .await?;
        Ok(self.render_text(result))
    }

    #[tool(
        description = "Read at most 400 lines from one safe repository-relative workspace file."
    )]
    async fn workspace_read_file(
        &self,
        Parameters(input): Parameters<WorkspaceReadInput>,
    ) -> Result<String, String> {
        let (actor, workspace) = self.workspace(&input.actor, &input.workspace_id).await?;
        let result = workspace
            .read_file(&input.path, input.start_line, input.end_line)
            .await
            .map_err(|error| error.to_string())?;
        self.audit_workspace(
            &actor,
            "workspace_read_file",
            &workspace,
            "success",
            json!({"path": input.path, "start_line": input.start_line, "end_line": input.end_line}),
        )
        .await?;
        Ok(self.render_text(result))
    }

    #[tool(
        description = "Apply a unified text patch inside an isolated workspace. Protected paths, binary patches, symlinks, and path traversal are rejected."
    )]
    async fn workspace_apply_patch(
        &self,
        Parameters(input): Parameters<WorkspacePatchInput>,
    ) -> Result<String, String> {
        let (actor, workspace) = self.workspace(&input.actor, &input.workspace_id).await?;
        let result = workspace.apply_patch(&input.patch).await;
        let outcome = if result.is_ok() { "success" } else { "error" };
        self.audit_workspace(
            &actor,
            "workspace_apply_patch",
            &workspace,
            outcome,
            json!({"patch_bytes": input.patch.len()}),
        )
        .await?;
        result
            .map(|value| self.render_text(value))
            .map_err(|error| error.to_string())
    }

    #[tool(description = "Read concise Git status from an isolated workspace.")]
    async fn workspace_git_status(
        &self,
        Parameters(input): Parameters<WorkspaceInput>,
    ) -> Result<String, String> {
        let (actor, workspace) = self.workspace(&input.actor, &input.workspace_id).await?;
        let result = workspace
            .status()
            .await
            .map_err(|error| error.to_string())?;
        self.audit_workspace(
            &actor,
            "workspace_git_status",
            &workspace,
            "success",
            json!({}),
        )
        .await?;
        Ok(self.render_text(result))
    }

    #[tool(description = "Read the bounded full diff from an isolated workspace.")]
    async fn workspace_git_diff(
        &self,
        Parameters(input): Parameters<WorkspaceInput>,
    ) -> Result<String, String> {
        let (actor, workspace) = self.workspace(&input.actor, &input.workspace_id).await?;
        let result = workspace.diff().await.map_err(|error| error.to_string())?;
        self.audit_workspace(
            &actor,
            "workspace_git_diff",
            &workspace,
            "success",
            json!({"bytes": result.len()}),
        )
        .await?;
        Ok(self.render_text(result))
    }

    #[tool(
        description = "Show the controller-selected, exact allowlisted validation commands for this workspace."
    )]
    async fn workspace_validation_plan(
        &self,
        Parameters(input): Parameters<WorkspaceInput>,
    ) -> Result<String, String> {
        let (actor, workspace) = self.workspace(&input.actor, &input.workspace_id).await?;
        let result = workspace
            .validation_plan()
            .await
            .map_err(|error| error.to_string())?;
        self.audit_workspace(
            &actor,
            "workspace_validation_plan",
            &workspace,
            "success",
            json!({"commands": result.len()}),
        )
        .await?;
        self.render_serializable(&result)
    }

    #[tool(
        description = "Run the complete controller-selected validation plan in the network-off workspace."
    )]
    async fn workspace_validate(
        &self,
        Parameters(input): Parameters<WorkspaceInput>,
    ) -> Result<String, String> {
        let (actor, workspace) = self.workspace(&input.actor, &input.workspace_id).await?;
        let result = workspace.validate().await;
        let outcome = match &result {
            Ok(results) if results.iter().all(|result| result.passed) => "success",
            _ => "error",
        };
        let count = result.as_ref().map_or(0, Vec::len);
        self.audit_workspace(
            &actor,
            "workspace_validate",
            &workspace,
            outcome,
            json!({"commands": count}),
        )
        .await?;
        self.render_serializable(&result.map_err(|error| error.to_string())?)
    }

    #[tool(
        description = "Re-run all validations, security-audit the diff, commit, and normal-push the workspace branch. Never force-pushes. Open the PR separately with github_pull_request_create."
    )]
    async fn workspace_publish_branch(
        &self,
        Parameters(input): Parameters<PublishWorkspaceInput>,
    ) -> Result<String, String> {
        validate_text("commit_message", &input.commit_message, 1, 240)?;
        let (actor, workspace) = self.workspace(&input.actor, &input.workspace_id).await?;
        let validations = workspace
            .validate()
            .await
            .map_err(|error| format!("validation execution failed: {error}"))?;
        if validations.iter().any(|result| !result.passed) {
            self.audit_workspace(
                &actor,
                "workspace_publish_branch",
                &workspace,
                "denied_validation",
                json!({"commands": validations.len()}),
            )
            .await?;
            return Err(format!(
                "publication refused because validation failed: {}",
                self.render_serializable(&validations)?
            ));
        }
        let descriptor = workspace.descriptor().clone();
        let repository = match self
            .github
            .repository(&descriptor.owner, &descriptor.repository)
            .await
        {
            Ok(repository) => repository,
            Err(error) => {
                self.audit_workspace(
                    &actor,
                    "workspace_publish_branch",
                    &workspace,
                    "github_access_error",
                    json!({}),
                )
                .await?;
                return Err(format!("GitHub App installation access failed: {error}"));
            }
        };
        self.audit_workspace(
            &actor,
            "workspace_publish_branch",
            &workspace,
            "attempt",
            json!({"branch": descriptor.branch_name, "validation_commands": validations.len()}),
        )
        .await?;
        let publication = workspace
            .commit_and_push(&input.commit_message, repository.token())
            .await;
        let outcome = if publication.is_ok() {
            "success"
        } else {
            "error"
        };
        self.audit_workspace(
            &actor,
            "workspace_publish_branch",
            &workspace,
            outcome,
            json!({"branch": descriptor.branch_name, "validation_commands": validations.len()}),
        )
        .await?;
        let (revision, audit) = publication.map_err(|error| error.to_string())?;
        self.store
            .finish_workspace(descriptor.id, "published")
            .await
            .map_err(|error| format!("workspace metadata write failed after push: {error}"))?;
        let _ = self.workspaces.remove(descriptor.id, &actor).await;
        self.render(&json!({
            "owner": descriptor.owner,
            "repository": descriptor.repository,
            "base": descriptor.base_ref,
            "branch": descriptor.branch_name,
            "revision": revision,
            "audit": audit,
            "validations": validations,
            "next_tool": "github_pull_request_create",
        }))
    }

    #[tool(
        description = "Destroy an unpublished isolated workspace. This never deletes a GitHub branch."
    )]
    async fn workspace_destroy(
        &self,
        Parameters(input): Parameters<WorkspaceInput>,
    ) -> Result<String, String> {
        let (actor, workspace) = self.workspace(&input.actor, &input.workspace_id).await?;
        let id = workspace.descriptor().id;
        self.audit_workspace(
            &actor,
            "workspace_destroy",
            &workspace,
            "attempt",
            json!({}),
        )
        .await?;
        self.store
            .finish_workspace(id, "closed")
            .await
            .map_err(|error| format!("workspace metadata write failed: {error}"))?;
        self.workspaces
            .remove(id, &actor)
            .await
            .map_err(|error| error.to_string())?;
        self.audit_workspace(
            &actor,
            "workspace_destroy",
            &workspace,
            "success",
            json!({}),
        )
        .await?;
        Ok(json!({"workspace_id": id, "status": "closed"}).to_string())
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct RepoScope {
    /// Exact sender identifier supplied by the authenticated Sonar gateway (for example an npub).
    actor: String,
    owner: String,
    repository: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct ListInput {
    #[serde(flatten)]
    repo: RepoScope,
    state: Option<String>,
    page: Option<u32>,
    per_page: Option<u8>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct NumberInput {
    #[serde(flatten)]
    repo: RepoScope,
    number: u64,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct NumberPageInput {
    #[serde(flatten)]
    repo: RepoScope,
    number: u64,
    page: Option<u32>,
    per_page: Option<u8>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct CreateIssueInput {
    #[serde(flatten)]
    repo: RepoScope,
    title: String,
    body: Option<String>,
    #[serde(default)]
    labels: Vec<String>,
    #[serde(default)]
    assignees: Vec<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct UpdateIssueInput {
    #[serde(flatten)]
    repo: RepoScope,
    number: u64,
    title: Option<String>,
    body: Option<String>,
    state: Option<String>,
    labels: Option<Vec<String>>,
    assignees: Option<Vec<String>>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct CommentInput {
    #[serde(flatten)]
    repo: RepoScope,
    number: u64,
    body: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct ChecksInput {
    #[serde(flatten)]
    repo: RepoScope,
    commit_sha: String,
    page: Option<u32>,
    per_page: Option<u8>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct ReviewInput {
    #[serde(flatten)]
    repo: RepoScope,
    number: u64,
    body: String,
    event: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct CreatePullInput {
    #[serde(flatten)]
    repo: RepoScope,
    title: String,
    body: Option<String>,
    head: String,
    base: String,
    draft: Option<bool>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct ConfirmNumberInput {
    #[serde(flatten)]
    repo: RepoScope,
    number: u64,
    confirmation_token: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct PrepareMergeInput {
    #[serde(flatten)]
    repo: RepoScope,
    number: u64,
    merge_method: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct ConfirmMergeInput {
    #[serde(flatten)]
    repo: RepoScope,
    number: u64,
    merge_method: Option<String>,
    confirmation_token: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct CreateWorkspaceInput {
    #[serde(flatten)]
    repo: RepoScope,
    task: String,
    base_ref: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct WorkspaceInput {
    actor: String,
    workspace_id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct WorkspaceListInput {
    actor: String,
    workspace_id: String,
    path: Option<String>,
    max_depth: Option<u8>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct WorkspaceSearchInput {
    actor: String,
    workspace_id: String,
    query: String,
    path: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct WorkspaceReadInput {
    actor: String,
    workspace_id: String,
    path: String,
    start_line: Option<u32>,
    end_line: Option<u32>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct WorkspacePatchInput {
    actor: String,
    workspace_id: String,
    patch: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
struct PublishWorkspaceInput {
    actor: String,
    workspace_id: String,
    commit_message: String,
}

#[derive(Debug, Serialize)]
struct PageQuery {
    state: String,
    page: u32,
    per_page: u8,
}

#[derive(Debug, Serialize)]
struct SimplePageQuery {
    page: u32,
    per_page: u8,
}

fn normalize_actor(actor: &str) -> Result<String, String> {
    let actor = actor.trim().to_ascii_lowercase();
    if actor.is_empty()
        || actor.len() > 256
        || actor.contains(char::is_whitespace)
        || actor.contains(['\0', '/', '\\'])
    {
        return Err("actor must be the exact authenticated Sonar sender identifier".to_owned());
    }
    Ok(actor)
}

fn validate_number(number: u64) -> Result<(), String> {
    if number == 0 {
        Err("GitHub issue and pull request numbers start at 1".to_owned())
    } else {
        Ok(())
    }
}

fn validate_page(page: Option<u32>, per_page: Option<u8>) -> Result<(), String> {
    if page.is_some_and(|page| page == 0 || page > 10_000)
        || per_page.is_some_and(|per_page| per_page == 0 || per_page > 100)
    {
        return Err("page must be 1-10000 and per_page must be 1-100".to_owned());
    }
    Ok(())
}

fn validate_list_state(state: Option<&str>) -> Result<String, String> {
    let state = state.unwrap_or("open").to_ascii_lowercase();
    if matches!(state.as_str(), "open" | "closed" | "all") {
        Ok(state)
    } else {
        Err("state must be open, closed, or all".to_owned())
    }
}

fn validate_merge_method(method: Option<&str>) -> Result<String, String> {
    let method = method.unwrap_or("squash").to_ascii_lowercase();
    if matches!(method.as_str(), "merge" | "squash" | "rebase") {
        Ok(method)
    } else {
        Err("merge_method must be merge, squash, or rebase".to_owned())
    }
}

fn validate_sha(value: &str) -> Result<(), String> {
    if value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err("commit SHA must contain exactly 40 hexadecimal characters".to_owned())
    }
}

fn validate_text(
    name: &'static str,
    value: &str,
    minimum: usize,
    maximum: usize,
) -> Result<(), String> {
    if value.trim().len() < minimum || value.len() > maximum || value.contains('\0') {
        Err(format!(
            "{name} must contain {minimum}-{maximum} bytes and no NUL"
        ))
    } else {
        Ok(())
    }
}

fn validate_optional_text(
    name: &'static str,
    value: Option<&str>,
    maximum: usize,
) -> Result<(), String> {
    if let Some(value) = value {
        if value.len() > maximum || value.contains('\0') {
            return Err(format!(
                "{name} must not exceed {maximum} bytes or contain NUL"
            ));
        }
    }
    Ok(())
}

fn validate_labels(values: &[String]) -> Result<(), String> {
    if values.len() > 50
        || values.iter().any(|value| {
            value.is_empty() || value.len() > 100 || value.contains(['\0', '\n', '\r'])
        })
    {
        return Err("labels contains too many or invalid values".to_owned());
    }
    Ok(())
}

fn validate_assignees(values: &[String]) -> Result<(), String> {
    if values.len() > 20
        || values.iter().any(|value| {
            value.is_empty()
                || value.len() > 100
                || !value
                    .chars()
                    .all(|character| character.is_ascii_alphanumeric() || "-_".contains(character))
        })
    {
        return Err("assignees contains too many or invalid logins".to_owned());
    }
    Ok(())
}

fn required_string(value: &Value, pointer: &str) -> Result<String, String> {
    value
        .pointer(pointer)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| format!("GitHub response omitted {pointer}"))
}

fn confirmation_title(value: &str) -> String {
    let compact = value.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut title = compact.chars().take(120).collect::<String>();
    if compact.chars().count() > 120 {
        title.push('…');
    }
    title
}

fn insert_optional<T: Serialize>(body: &mut Map<String, Value>, key: &str, value: Option<T>) {
    if let Some(value) = value {
        if let Ok(value) = serde_json::to_value(value) {
            body.insert(key.to_owned(), value);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn actors_and_pagination_are_bounded() {
        assert_eq!(normalize_actor("NPUB1ALICE"), Ok("npub1alice".to_owned()));
        assert!(normalize_actor("npub1alice/npub1bob").is_err());
        assert!(validate_page(Some(1), Some(100)).is_ok());
        assert!(validate_page(Some(0), Some(101)).is_err());
    }

    #[test]
    fn confirmation_merge_method_is_canonical() {
        assert_eq!(
            validate_merge_method(Some("SQUASH")),
            Ok("squash".to_owned())
        );
        assert!(validate_merge_method(Some("octopus")).is_err());
    }

    #[test]
    fn mcp_registry_exposes_the_complete_github_user_surface() {
        let tools = HermesGitHubServer::tool_router().list_all();
        let names = tools
            .iter()
            .map(|tool| tool.name.as_ref())
            .collect::<Vec<_>>();
        assert_eq!(tools.len(), 29);
        for required in [
            "github_pull_request_feedback",
            "github_pull_request_review",
            "github_pull_request_merge_prepare",
            "github_pull_request_merge_confirm",
            "workspace_apply_patch",
            "workspace_publish_branch",
        ] {
            assert!(names.contains(&required), "missing MCP tool {required}");
        }
    }
}
