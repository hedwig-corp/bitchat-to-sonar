// Shared configuration for the blog pipeline.
//
// Nothing secret lives here. The signing credential is a NIP-46 bunker URI
// passed only via the BLOG_BUNKER_URI environment variable (a CI secret) and is
// never read from or written to this file. An npub is public, so BLOG_NPUB is
// safe to commit.

export const ARTICLE_KIND = 30023; // NIP-23 long-form article.

// Relays the posts are published to and read back from. Override with a
// comma-separated BLOG_RELAYS env var.
export const RELAYS = (
  process.env.BLOG_RELAYS ||
  ['wss://relay.damus.io', 'wss://nos.lol', 'wss://relay.nostr.band', 'wss://relay.primal.net'].join(',')
)
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

// The public identity the blog is published under (the author whose kind-30023
// events the site loads). Fill this in with the team/personal npub once the
// bunker identity is chosen — an npub is public and safe to commit. Until it is
// set (or overridden via BLOG_NPUB), the fetch step falls back to the local
// docs/blog sources, so the site still builds.
export const BLOG_NPUB = process.env.BLOG_NPUB || '';
