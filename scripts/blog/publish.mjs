// Publish (or replace) docs/blog/<slug>/README.md as NIP-23 kind-30023 events.
//
// Signing is delegated to a NIP-46 remote signer ("bunker") so the account's
// private key never enters this process or CI. Pass the connection string via
// the BLOG_BUNKER_URI env var (a CI secret): bunker://<pubkey>?relay=...&secret=...
//
// Change detection is relay-diff: for each post we fetch the current article by
// (author, d-tag) and skip publishing when content + tags are byte-identical, so
// re-runs are idempotent and never bump events needlessly. No local state file.
//
// Usage:
//   node publish.mjs --dry-run   # parse + print events, no signing/network
//   BLOG_BUNKER_URI=bunker://... node publish.mjs

import { generateSecretKey } from 'nostr-tools/pure';
import { SimplePool, useWebSocketImplementation } from 'nostr-tools/pool';
import { BunkerSigner, parseBunkerInput } from 'nostr-tools/nip46';
import WebSocket from 'ws';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadPosts, buildArticle, articleSig } from './lib.mjs';
import { RELAYS, ARTICLE_KIND } from './config.mjs';

useWebSocketImplementation(WebSocket);

const HERE = dirname(fileURLToPath(import.meta.url));
const BLOG_DIR = join(HERE, '..', '..', 'docs', 'blog');
const DRY_RUN = process.argv.includes('--dry-run');

async function main() {
  const posts = loadPosts(BLOG_DIR);
  if (!posts.length) {
    console.log('No posts in docs/blog — nothing to publish.');
    return;
  }
  console.log(`Found ${posts.length} post(s) in docs/blog.`);

  if (DRY_RUN) {
    for (const p of posts) {
      const ev = buildArticle(p);
      console.log(`\n--- ${p.slug} ---`);
      console.log(JSON.stringify({ kind: ev.kind, tags: ev.tags }, null, 2));
      console.log(`content: ${ev.content.length} chars`);
    }
    console.log('\n[dry-run] no signing, no publish.');
    return;
  }

  const uri = process.env.BLOG_BUNKER_URI;
  if (!uri) {
    console.error('BLOG_BUNKER_URI is not set (expected a bunker://… connection string). Aborting.');
    process.exit(1);
  }
  const pointer = await parseBunkerInput(uri);
  if (!pointer) {
    console.error('BLOG_BUNKER_URI is not a valid bunker connection string. Aborting.');
    process.exit(1);
  }

  const signer = new BunkerSigner(generateSecretKey(), pointer);
  await signer.connect();
  const pubkey = await signer.getPublicKey();
  console.log(`Signer connected. Author pubkey: ${pubkey}`);

  const pool = new SimplePool();
  // Existing articles by this author, keyed by d-tag (latest wins), for diffing.
  const existing = await pool.querySync(RELAYS, { kinds: [ARTICLE_KIND], authors: [pubkey] });
  const byD = new Map();
  for (const ev of existing) {
    const d = ev.tags.find((t) => t[0] === 'd')?.[1];
    if (!d) continue;
    const cur = byD.get(d);
    if (!cur || ev.created_at > cur.created_at) byD.set(d, ev);
  }

  let published = 0;
  let skipped = 0;
  for (const p of posts) {
    const tmpl = buildArticle(p);
    const prev = byD.get(p.slug);
    if (prev && articleSig(prev) === articleSig(tmpl)) {
      console.log(`= ${p.slug} (unchanged)`);
      skipped++;
      continue;
    }
    const signed = await signer.signEvent({
      kind: tmpl.kind,
      tags: tmpl.tags,
      content: tmpl.content,
      created_at: Math.floor(Date.now() / 1000)
    });
    await Promise.any(pool.publish(RELAYS, signed));
    console.log(`${prev ? '~ replaced' : '+ published'} ${p.slug} (${signed.id.slice(0, 8)}…)`);
    published++;
  }

  console.log(`\nDone: ${published} published/replaced, ${skipped} unchanged.`);
  try {
    pool.close(RELAYS);
    await signer.close();
  } catch {
    /* best-effort cleanup */
  }
  process.exit(0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
