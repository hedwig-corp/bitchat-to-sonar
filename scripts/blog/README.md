# Blog pipeline — publish to Nostr, read back on the site

Turns `docs/blog/<slug>/README.md` into [NIP-23](https://nips.nostr.com/23)
long-form articles (kind `30023`) on Nostr, and generates the marketing site's
blog data by reading those articles back from relays. Authoring is documented in
[`docs/blog/README.md`](../../docs/blog/README.md).

```
docs/blog/<slug>/README.md   ──publish.mjs──▶   kind-30023 events on relays
                                                        │
web/src/lib/blog-content.js  ◀──fetch.mjs────────────────┘   (site prerenders)
```

## Scripts

```sh
cd scripts/blog && npm ci

# Parse posts and print the events that would be published — no network, no key:
npm run publish-posts:dry

# Publish / replace changed posts (needs the bunker secret, see below):
BLOG_BUNKER_URI='bunker://…' npm run publish-posts

# Regenerate web/src/lib/blog-content.js from relays (falls back to docs/blog):
BLOG_NPUB='npub1…' npm run fetch
```

- **`publish.mjs`** builds a kind-`30023` event per post and publishes it.
  Change detection is **relay-diff**: it fetches the current article by
  `(author, d-tag)` and skips posts whose content + tags are byte-identical, so
  re-runs are idempotent and never bump events needlessly. No local state file.
- **`fetch.mjs`** queries the author's articles and writes
  `web/src/lib/blog-content.js`. If `BLOG_NPUB` is unset, the fetch errors, or it
  returns nothing, it **falls back to the local `docs/blog` sources**, so a relay
  hiccup can never ship an empty blog when posts exist in the repo.

## Signing — NIP-46 bunker (the key never touches CI)

Publishing signs each event with the account's key. To keep the raw `nsec` out
of CI, signing is delegated to a **NIP-46 remote signer ("bunker")**. CI only
holds a `bunker://…` connection string, which authorizes *this* connection to
request signatures and can be revoked on its own without rotating the identity.

Setup:

1. In your signer (Amber, nsecbunker, nsec.app, …) create a bunker connection
   and copy its `bunker://<pubkey>?relay=wss://…&secret=…` URI.
2. Add it as a GitHub Actions secret named **`BLOG_BUNKER_URI`** (never commit
   it — see the repo Local Secrets Rule).
3. Put the matching **public** npub in [`config.mjs`](./config.mjs) as
   `BLOG_NPUB` (an npub is public and safe to commit) so the site knows whose
   articles to load.

`config.mjs` also holds the relay list (`BLOG_RELAYS` to override). CI wiring is
in [`.github/workflows/blog-publish.yml`](../../.github/workflows/blog-publish.yml)
(publish on `docs/blog/**` changes) and the Pages build
([`pages.yml`](../../.github/workflows/pages.yml)), which runs `fetch` before the
site build.
