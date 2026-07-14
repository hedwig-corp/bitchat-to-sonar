// Shared helpers for the blog pipeline: read docs/blog posts, build NIP-23
// article events, and map events back to the site's SONAR_BLOG.posts shape.

import { readdirSync, statSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import matter from 'gray-matter';
import { ARTICLE_KIND } from './config.mjs';

/**
 * Load every post from docs/blog/<slug>/README.md.
 * Each README has YAML frontmatter (title, cat, date, summary, author, read,
 * feature) and a Markdown body. The directory name is the slug / `d` tag.
 * @param {string} blogDir absolute path to docs/blog
 * @returns {Array<object>} posts, newest first
 */
export function loadPosts(blogDir) {
  let entries;
  try {
    entries = readdirSync(blogDir);
  } catch {
    return [];
  }
  const posts = [];
  for (const slug of entries) {
    if (slug.startsWith('.')) continue;
    const dir = join(blogDir, slug);
    try {
      if (!statSync(dir).isDirectory()) continue;
    } catch {
      continue;
    }
    let raw;
    try {
      raw = readFileSync(join(dir, 'README.md'), 'utf8');
    } catch {
      continue; // a directory without a README.md is not a post
    }
    const { data, content } = matter(raw);
    if (!data.title) {
      console.warn(`skip ${slug}: frontmatter is missing a title`);
      continue;
    }
    posts.push({
      slug,
      title: String(data.title),
      cat: String(data.cat || 'Engineering'),
      date: data.date ? String(data.date) : '',
      summary: data.summary ? String(data.summary) : '',
      author: data.author ? String(data.author) : 'The Sonar team',
      read: data.read ? String(data.read) : '',
      feature: Boolean(data.feature),
      md: content.trim()
    });
  }
  posts.sort((a, b) => (Date.parse(b.date) || 0) - (Date.parse(a.date) || 0));
  return posts;
}

/** published_at unix seconds from a YYYY-MM-DD (or any Date-parseable) date. */
export function publishedAt(dateStr) {
  const t = Date.parse(dateStr);
  return Number.isFinite(t) ? Math.floor(t / 1000) : 0;
}

/**
 * Build the unsigned kind-30023 event template for a post. `created_at` is set
 * by the publisher at signing time (so an edit is always "newer" on relays);
 * the stable original date lives in the `published_at` tag.
 * @param {object} post from loadPosts
 * @returns {{ kind: number, tags: string[][], content: string }}
 */
export function buildArticle(post) {
  const tags = [
    ['d', post.slug],
    ['title', post.title]
  ];
  if (post.summary) tags.push(['summary', post.summary]);
  const pa = publishedAt(post.date);
  if (pa) tags.push(['published_at', String(pa)]);
  if (post.cat) tags.push(['t', post.cat.toLowerCase()]);
  // Site-only metadata carried as custom tags so the site can round-trip it.
  if (post.read) tags.push(['read', post.read]);
  if (post.author) tags.push(['author', post.author]);
  if (post.feature) tags.push(['featured', 'true']);
  return { kind: ARTICLE_KIND, tags, content: post.md };
}

/**
 * Canonical signature of an article's meaningful fields (content + tags),
 * ignoring `created_at`/`id`/`sig`, so the publisher can skip unchanged posts.
 * @param {{ content: string, tags: string[][] }} ev
 */
export function articleSig(ev) {
  const tags = ev.tags.map((t) => t.join('')).sort();
  return JSON.stringify([ev.content, tags]);
}

/**
 * Map a kind-30023 event to the site's SONAR_BLOG post shape.
 * @param {{ tags: string[][], content: string, created_at: number }} ev
 * @returns {object | null}
 */
export function eventToPost(ev) {
  const tag = (k) => ev.tags.find((t) => t[0] === k)?.[1];
  const d = tag('d');
  if (!d) return null;
  const pa = Number(tag('published_at')) || ev.created_at;
  const t = ev.tags.find((x) => x[0] === 't')?.[1] || '';
  const cat = t ? t[0].toUpperCase() + t.slice(1) : 'Engineering';
  const date = new Date(pa * 1000).toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    timeZone: 'UTC'
  });
  return {
    id: d,
    title: tag('title') || d,
    cat,
    date,
    read: tag('read') || '',
    author: tag('author') || 'The Sonar team',
    feature: tag('featured') === 'true',
    excerpt: tag('summary') || '',
    md: ev.content,
    _publishedAt: pa
  };
}
