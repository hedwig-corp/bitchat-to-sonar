// Tiny markdown renderer — ported 1:1 from the inline script in the Claude
// Design handoff: design/handoff/project/Sonar Docs.html.
//
// Reproduces the same block/inline grammar (headings, code fences, tables,
// blockquotes, lists, hr, paragraphs) so the rendered docs match the design's
// output. renderMarkdown() returns { html, toc } instead of stashing the TOC on
// a function property; the block logic is otherwise unchanged.

/** @param {string} s */
function esc(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/**
 * @param {string} s
 * @param {(href: string) => string} resolve maps a relative markdown link to a real href
 */
function inline(s, resolve) {
  return esc(s)
    .replace(/`([^`]+)`/g, (/** @type {string} */ m, /** @type {string} */ c) => '<code>' + c + '</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>')
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, (/** @type {string} */ m, /** @type {string} */ t, /** @type {string} */ h) => {
      let href = h;
      let cls = '';
      if (/^https?:/.test(h)) cls = ' target="_blank" rel="noopener"';
      else if (/\.md$/i.test(h)) {
        const id = h.replace(/^.*\//, '').replace(/\.md$/i, '');
        href = '#' + id;
      } else href = resolve(h);
      return '<a href="' + href + '"' + cls + '>' + t + '</a>';
    });
}

/** @param {string} s */
function slug(s) {
  return s
    .toLowerCase()
    .replace(/[^\w\s-]/g, '')
    .trim()
    .replace(/\s+/g, '-');
}

/**
 * @param {string} md
 * @param {{lvl: number, txt: string, id: string}[]} toc
 * @param {(href: string) => string} resolve
 */
function renderMd(md, toc, resolve) {
  const lines = md.replace(/\r/g, '').split('\n');
  let html = '';
  let i = 0;
  while (i < lines.length) {
    const ln = lines[i];
    // code fence
    if (/^```/.test(ln)) {
      const buf = [];
      i++;
      while (i < lines.length && !/^```/.test(lines[i])) {
        buf.push(lines[i]);
        i++;
      }
      i++;
      html += '<pre><code>' + esc(buf.join('\n')) + '</code></pre>';
      continue;
    }
    // table
    if (/^\|/.test(ln) && i + 1 < lines.length && /^\|[\s:|-]+\|?\s*$/.test(lines[i + 1])) {
      const head = ln.split('|').slice(1, -1).map((c) => c.trim());
      i += 2;
      const rows = [];
      while (i < lines.length && /^\|/.test(lines[i])) {
        rows.push(lines[i].split('|').slice(1, -1).map((c) => c.trim()));
        i++;
      }
      let t =
        '<table><thead><tr>' +
        head.map((h) => '<th>' + inline(h, resolve) + '</th>').join('') +
        '</tr></thead><tbody>';
      t += rows
        .map((r) => '<tr>' + r.map((c) => '<td>' + inline(c, resolve) + '</td>').join('') + '</tr>')
        .join('');
      html += t + '</tbody></table>';
      continue;
    }
    // headings
    const h = /^(#{1,4})\s+(.*)$/.exec(ln);
    if (h) {
      const lvl = h[1].length;
      const txt = h[2];
      const id = slug(txt);
      if (lvl === 2 || lvl === 3) toc.push({ lvl, txt, id });
      const anc = lvl === 2 || lvl === 3 ? ' id="' + id + '"' : '';
      const link = lvl === 2 || lvl === 3 ? '<a class="anchor" href="#' + id + '">#</a>' : '';
      html += '<h' + lvl + anc + '>' + inline(txt, resolve) + link + '</h' + lvl + '>';
      i++;
      continue;
    }
    // hr
    if (/^(-{3,}|\*{3,}|_{3,})\s*$/.test(ln)) {
      html += '<hr>';
      i++;
      continue;
    }
    // blockquote
    if (/^>\s?/.test(ln)) {
      const qb = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) {
        qb.push(lines[i].replace(/^>\s?/, ''));
        i++;
      }
      html += '<blockquote>' + renderMd(qb.join('\n'), [], resolve) + '</blockquote>';
      continue;
    }
    // lists
    if (/^\s*[-*+]\s+/.test(ln) || /^\s*\d+\.\s+/.test(ln)) {
      const ordered = /^\s*\d+\.\s+/.test(ln);
      const items = [];
      while (i < lines.length && (/^\s*[-*+]\s+/.test(lines[i]) || /^\s*\d+\.\s+/.test(lines[i]))) {
        items.push(lines[i].replace(/^\s*(?:[-*+]|\d+\.)\s+/, ''));
        i++;
      }
      html +=
        (ordered ? '<ol>' : '<ul>') +
        items.map((it) => '<li>' + inline(it, resolve) + '</li>').join('') +
        (ordered ? '</ol>' : '</ul>');
      continue;
    }
    // blank
    if (/^\s*$/.test(ln)) {
      i++;
      continue;
    }
    // paragraph
    const pb = [];
    while (
      i < lines.length &&
      !/^\s*$/.test(lines[i]) &&
      !/^(#{1,4}\s|```|>\s?|\||\s*[-*+]\s|\s*\d+\.\s)/.test(lines[i]) &&
      !/^(-{3,})\s*$/.test(lines[i])
    ) {
      pb.push(lines[i]);
      i++;
    }
    if (pb.length) html += '<p>' + inline(pb.join(' '), resolve) + '</p>';
  }
  return html;
}

/**
 * Render markdown to HTML plus a heading table-of-contents.
 * @param {string} md
 * @param {{ resolveLink?: (href: string) => string }} [opts]
 * @returns {{ html: string, toc: {lvl: number, txt: string, id: string}[] }}
 */
export function renderMarkdown(md, opts = {}) {
  const resolve = opts.resolveLink || ((/** @type {string} */ h) => h);
  /** @type {{lvl: number, txt: string, id: string}[]} */
  const toc = [];
  const html = renderMd(md, toc, resolve);
  return { html, toc };
}
