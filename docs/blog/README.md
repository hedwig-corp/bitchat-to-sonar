# Sonar blog posts

Write blog posts here as Markdown. On merge to `main`, CI publishes each post to
Nostr as a [NIP-23](https://nips.nostr.com/23) long-form article (kind `30023`),
and the marketing site loads the posts back from relays. This directory is the
source of truth; Nostr is the delivery layer.

## Writing a post

One directory per post; the **directory name is the slug** — it becomes the
NIP-23 `d` tag and the URL hash on the site (`/blog#<slug>`). Put the body in
`README.md` with YAML frontmatter:

```
docs/blog/why-no-accounts/README.md
```

```markdown
---
title: Why Sonar has no accounts — and why that's the point
cat: Design            # Policy | Design | Engineering  (→ NIP-23 `t` tag; Policy renders gold)
date: 2026-06-30       # → NIP-23 `published_at`
summary: One-paragraph teaser shown on the cards.   # → `summary` tag
author: The Sonar team # optional
read: 4 min read       # optional, shown on the card
feature: false         # optional; pin one post as the featured card
---

# Why Sonar has no accounts — and why that's the point

Body in Markdown — same renderer as the docs. Links to other pages resolve on
the site: [the docs](Sonar%20Docs.html), [the app](Sonar%20Prototype.html).
```

Editing a post and keeping the **same directory name** *replaces* the existing
Nostr article (same `d` tag) instead of creating a duplicate. Renaming the
directory publishes a new post and orphans the old one.

## Frontmatter → NIP-23 tag mapping

| Frontmatter | NIP-23 tag | Notes |
|-------------|-----------|-------|
| dir name | `d` | slug / identifier / URL hash — keep stable to edit in place |
| `title` | `title` | required |
| `summary` | `summary` | teaser |
| `date` | `published_at` | unix seconds derived from the date |
| `cat` | `t` | topic; lowercased. `Policy` → gold accent on the site |
| `read` | `read` (custom) | site-only card metadata |
| `author` | `author` (custom) | site-only |
| `feature` | `featured` (custom) | pins the featured card |
| body | `.content` | Markdown |

The pipeline and its secrets are documented in
[`scripts/blog/README.md`](../../scripts/blog/README.md). The blog launches with
no posts; add a directory here to publish the first one.
