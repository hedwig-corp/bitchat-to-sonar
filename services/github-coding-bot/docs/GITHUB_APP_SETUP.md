# GitHub App setup

Create an organization-owned GitHub App. Its name becomes the visible
`app-name[bot]` identity. Do not use a personal access token or machine user.

Repository permissions:

- Metadata: read
- Contents: read and write
- Issues: read and write
- Pull requests: read and write
- Checks: read

No webhook URL, webhook secret, or event subscriptions are required. Hermes
initiates every action through MCP.

1. Generate and download the App private key.
2. Install the App only on repositories intended for automation.
3. Add every exact `owner/repository` to `REPOSITORY_ALLOWLIST`; installation
   alone is not authorization.
4. Add exact authenticated Sonar sender IDs to `SONAR_AUTHORIZED_SENDERS`.
5. Store the private key outside the repository with restrictive permissions
   and mount it read-only at `GITHUB_PRIVATE_KEY_PATH`.
6. Set `GITHUB_APP_ID`; never put key contents in `.env` or Hermes prompts.

GitHub installation tokens are minted on demand, expire automatically, and are
injected only into the GitHub API client or one controller-owned Git process.
They are never returned by an MCP tool.
