# GitHub App setup

Create an organization-owned GitHub App. Do not use a personal access token.

## Permissions

Repository permissions:

- Contents: read and write
- Pull requests: read and write
- Issues: read and write
- Metadata: read
- Checks: read

Subscribe to:

- `issues`
- `issue_comment`
- `installation`
- `installation_repositories`

Only the `issues` `labeled` action with exact label `ai-fix` triggers an MVP job;
the other subscriptions keep the installation contract forward-compatible and
are acknowledged without queueing.

## Configure

1. Generate and download the App private key.
2. Generate a long random webhook secret.
3. Set the webhook URL to `https://HOST/webhooks/github` and content type JSON.
4. Install the App only on repositories intended for automation.
5. Add each exact `owner/repository` to `REPOSITORY_ALLOWLIST`.
6. Put the key in a root-readable/operator-managed secret location with mode
   `0600`; mount it read-only into API and controller containers.
7. Set `GITHUB_APP_ID`, `GITHUB_BOT_LOGIN`, key path, and webhook secret in the
   uncommitted `.env` or equivalent secret manager.

The labeler is checked through GitHub's collaborator-permission endpoint. An
untrusted issue author is acceptable only when a trusted maintainer applies the
label. Events sent by the bot itself are ignored.

## Verify

Use GitHub's webhook delivery page to redeliver a signed test event. A valid
delivery returns HTTP 202. Redelivery returns 202 with `duplicate_delivery` and
does not create another job. Inspect `/jobs/{id}` using the admin bearer token.
