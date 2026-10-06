/**
 * Markdown proposal -> print-quality HTML.
 *
 * Hand-rolled because this machine has Edge but no pandoc / wkhtmltopdf /
 * LibreOffice and no markdown lib in node_modules, and a network install is not
 * worth the dependency. Covers the subset the proposal uses: ATX headings,
 * pipe tables with alignment, fenced code, blockquotes, ordered/unordered lists
 * with two-space nesting, thematic breaks, inline emphasis/code/links.
 *
 * Usage: node scripts/md-to-html.mjs <input.md> <output.html>
 */

import { readFileSync, writeFileSync } from 'node:fs';

const [, , srcArg, outArg] = process.argv;
if (!srcArg || !outArg) {
  console.error('usage: node scripts/md-to-html.mjs <input.md> <output.html>');
  process.exit(1);
}

const md = readFileSync(srcArg, 'utf8')
  .replace(/^\uFEFF/, '')
  .replace(/\r\n/g, '\n');

// ── inline ──────────────────────────────────────────────────────────────────

const CODE_TOKEN = '\u0000C';

function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/**
 * Inline pass. Code spans are lifted out FIRST so that emphasis markers inside
 * backticks are never interpreted as formatting.
 */
function inline(src) {
  const codes = [];
  let t = src.replace(/`([^`]+)`/g, (_m, code) => {
    codes.push(code);
    return `${CODE_TOKEN}${codes.length - 1}\u0000`;
  });

  t = escapeHtml(t);

  t = t.replace(
    /\[([^\]]+)\]\(([^)\s]+)\)/g,
    (_m, text, href) => `<a href="${href}">${text}</a>`,
  );
  t = t.replace(/\*\*([^*]+)\*\*/g, (_m, b) => `<strong>${b}</strong>`);
  t = t.replace(/(^|[^*\w])\*([^*\n]+)\*(?![*\w])/g, (_m, pre, b) => `${pre}<em>${b}</em>`);

  return t.replace(
    new RegExp(`${CODE_TOKEN}(\\d+)\u0000`, 'g'),
    (_m, i) => `<code>${escapeHtml(codes[Number(i)])}</code>`,
  );
}

const slug = (s) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');

// ── tables ──────────────────────────────────────────────────────────────────

/** Split a pipe row, honouring an escaped `\|` as literal content. */
function splitRow(line) {
  let s = line.trim();
  if (s.startsWith('|')) s = s.slice(1);
  if (s.endsWith('|')) s = s.slice(0, -1);

  const cells = [];
  let cur = '';
  for (let i = 0; i < s.length; i += 1) {
    if (s[i] === '\\' && s[i + 1] === '|') {
      cur += '|';
      i += 1;
      continue;
    }
    if (s[i] === '|') {
      cells.push(cur);
      cur = '';
      continue;
    }
    cur += s[i];
  }
  cells.push(cur);
  return cells;
}

const isDelimiter = (line) =>
  line.includes('-') && /^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$/.test(line);

function parseTable(lines, start) {
  const header = splitRow(lines[start]);
  const aligns = splitRow(lines[start + 1]).map((d) => {
    const s = d.trim();
    if (/^:.*:$/.test(s)) return 'center';
    if (/:$/.test(s)) return 'right';
    if (/^:/.test(s)) return 'left';
    return '';
  });

  let i = start + 2;
  const rows = [];
  while (i < lines.length && lines[i].includes('|') && lines[i].trim() !== '') {
    rows.push(splitRow(lines[i]));
    i += 1;
  }

  const align = (k) => (aligns[k] ? ` style="text-align:${aligns[k]}"` : '');

  let html = '<table><thead><tr>';
  header.forEach((c, k) => {
    html += `<th${align(k)}>${inline(c.trim())}</th>`;
  });
  html += '</tr></thead><tbody>';
  for (const row of rows) {
    html += '<tr>';
    for (let k = 0; k < header.length; k += 1) {
      html += `<td${align(k)}>${inline((row[k] ?? '').trim())}</td>`;
    }
    html += '</tr>';
  }
  html += '</tbody></table>';

  return { html, next: i };
}

// ── lists ───────────────────────────────────────────────────────────────────

/**
 * Lists are recursive. An item's continuation lines are dedented by the parent
 * indent plus two, then handed back to the block parser — so a bullet that
 * contains a nested list, a paragraph, or a fenced block all render correctly
 * without special-casing each one.
 */
function parseList(lines, start) {
  const first = lines[start].match(/^(\s*)([-*+]|\d+\.)\s+/);
  const baseIndent = first[1].length;
  const ordered = /^\d/.test(first[2].trim());

  const items = [];
  let cur = null;
  let i = start;

  while (i < lines.length) {
    const l = lines[i];

    if (/^\s*$/.test(l)) {
      let j = i;
      while (j < lines.length && /^\s*$/.test(lines[j])) j += 1;
      if (j >= lines.length) {
        i = j;
        break;
      }
      const nm = lines[j].match(/^(\s*)([-*+]|\d+\.)\s+/);
      if (nm && nm[1].length >= baseIndent) {
        if (cur) cur.lines.push('');
        i = j;
        continue;
      }
      break;
    }

    const m = l.match(/^(\s*)([-*+]|\d+\.)\s+(.*)$/);
    if (m) {
      const ind = m[1].length;
      if (ind < baseIndent) break;
      if (ind > baseIndent) {
        if (!cur) break;
        cur.lines.push(l);
        i += 1;
        continue;
      }
      if (/^\d/.test(m[2].trim()) !== ordered) break;
      cur = { lines: [m[3]] };
      items.push(cur);
      i += 1;
      continue;
    }

    if (cur) {
      cur.lines.push(l);
      i += 1;
      continue;
    }
    break;
  }

  const tag = ordered ? 'ol' : 'ul';
  let html = `<${tag}>`;

  for (const item of items) {
    const rest = item.lines.slice(1);
    while (rest.length && rest[0].trim() === '') rest.shift();

    /*
     * Head and continuation are parsed TOGETHER, not separately.
     *
     * A markdown emphasis span may straddle the wrapped line break of a list
     * item — `**authenticated officer and` / `their open shift**` — so running
     * inline() on the head alone leaves an unmatched `**` behind and emits a
     * stray paragraph. Handing the whole item to the block parser joins the
     * lines first, so the span closes correctly, and a nested list, table or
     * fence inside the item still parses as a block.
     */
    const blocks = parseBlocks([item.lines[0], ...rest]);
    let content;
    if (blocks.length === 1 && /^<p>[\s\S]*<\/p>$/.test(blocks[0])) {
      // Unwrap a lone paragraph so simple items don't nest <p> inside <li>.
      content = blocks[0].replace(/^<p>/, '').replace(/<\/p>$/, '');
    } else if (blocks.length > 0 && /^<p>[\s\S]*<\/p>$/.test(blocks[0])) {
      content = `${blocks[0].replace(/^<p>/, '').replace(/<\/p>$/, '')}\n${blocks.slice(1).join('\n')}`;
    } else {
      content = blocks.join('\n');
    }

    html += `<li>${content}</li>`;
  }

  html += `</${tag}>`;
  return { html, next: i };
}

// ── block dispatcher ────────────────────────────────────────────────────────

/**
 * Block order matters: fences and tables are tested before paragraphs, and the
 * paragraph loop terminates on anything that would start another block. A table
 * is only recognised when the CURRENT line has a pipe AND the NEXT line is a
 * delimiter row — otherwise a lone `|` in prose would be swallowed as a table.
 */
function parseBlocks(lines) {
  const out = [];
  let i = 0;

  const startsBlock = (l, hasBuf) => {
    if (/^\s*$/.test(l)) return true;
    if (/^\s*```/.test(l)) return true;
    if (/^\s*#{1,6}\s/.test(l)) return true;
    if (/^\s*>/.test(l)) return true;
    if (/^\s*([-*+]|\d+\.)\s+/.test(l)) return true;
    if (/^\s*(-{3,}|\*{3,})\s*$/.test(l)) return true;
    if (hasBuf && l.includes('|') && lines[i + 1] !== undefined && isDelimiter(lines[i + 1])) {
      return true;
    }
    return false;
  };

  while (i < lines.length) {
    const line = lines[i];

    if (/^\s*$/.test(line)) {
      i += 1;
      continue;
    }

    if (/^\s*(-{3,}|\*{3,}|_{3,})\s*$/.test(line)) {
      out.push('<hr />');
      i += 1;
      continue;
    }

    if (/^\s*```/.test(line)) {
      const buf = [];
      i += 1;
      while (i < lines.length && !/^\s*```/.test(lines[i])) {
        buf.push(lines[i]);
        i += 1;
      }
      i += 1;
      out.push(`<pre class="code"><code>${escapeHtml(buf.join('\n'))}</code></pre>`);
      continue;
    }

    const h = line.match(/^(#{1,6})\s+(.*)$/);
    if (h) {
      const lvl = h[1].length;
      out.push(`<h${lvl} id="${slug(h[2].trim())}">${inline(h[2].trim())}</h${lvl}>`);
      i += 1;
      continue;
    }

    if (line.includes('|') && i + 1 < lines.length && isDelimiter(lines[i + 1])) {
      const res = parseTable(lines, i);
      out.push(res.html);
      i = res.next;
      continue;
    }

    if (/^\s*>/.test(line)) {
      const buf = [];
      while (i < lines.length && /^\s*>/.test(lines[i])) {
        buf.push(lines[i].replace(/^\s*>\s?/, ''));
        i += 1;
      }
      out.push(`<blockquote>${parseBlocks(buf).join('\n')}</blockquote>`);
      continue;
    }

    if (/^\s*([-*+]|\d+\.)\s+/.test(line)) {
      const res = parseList(lines, i);
      out.push(res.html);
      i = res.next;
      continue;
    }

    const buf = [];
    while (i < lines.length && !startsBlock(lines[i], buf.length > 0)) {
      buf.push(lines[i]);
      i += 1;
    }
    if (buf.length) {
      out.push(`<p>${inline(buf.join(' ').trim())}</p>`);
    } else {
      i += 1;
    }
  }

  return out;
}

// ── contents ────────────────────────────────────────────────────────────────

const allLines = md.split('\n');

/*
 * Contents scope: only the numbered Parts and their subsections.
 *
 * Collecting every h1/h2 would list the cover title and the "How to read this
 * document" note, which sit directly above the contents page and would read as
 * if the list referred back to itself. Tracking whether a Part has been seen
 * drops anything appearing before the first one.
 */
const headings = [];
let inPart = false;
for (const l of allLines) {
  const m = l.match(/^(#{1,2})\s+(.*)$/);
  if (!m) continue;
  const text = m[2].trim();
  if (m[1].length === 1) inPart = /^Part /.test(text);
  if (inPart) headings.push({ level: m[1].length, text });
}

/*
 * The contents list is built as finished HTML and spliced into the ALREADY
 * PARSED block array.
 *
 * It cannot be pushed into the markdown line array instead: parseBlocks would
 * see a line that is not a heading, fence, table, quote or list, and emit it as
 * a paragraph — which renders the entire contents list as literal visible HTML
 * source. Splicing after parsing sidesteps the markdown grammar completely.
 */
const tocBlocks = [
  '<h1 class="toc-title">Contents</h1>',
  '<nav class="toc">',
  ...headings.map((h) =>
    h.level === 1
      ? `<div class="toc-1"><a href="#${slug(h.text)}">${inline(h.text)}</a></div>`
      : `<div class="toc-2"><a href="#${slug(h.text)}">${inline(h.text)}</a></div>`,
  ),
  '</nav>',
];

const blocks = parseBlocks(allLines);

// Place the contents page immediately before the first Part, so the cover
// metadata and the reading note stay ahead of it.
const partAt = blocks.findIndex((b) => /^<h1 id="part-/.test(b));

const body = (partAt === -1 ? blocks : [
  ...blocks.slice(0, partAt),
  ...tocBlocks,
  ...blocks.slice(partAt),
]).join('\n');

// ── stylesheet ──────────────────────────────────────────────────────────────

const CSS = `
:root{
  --ink:#14201C; --muted:#5B6B65; --accent:#1D6FE0; --rule:#D8DEDB;
  --band:#F4F7F6;
}
@page{ size:A4; margin:16mm 14mm 15mm; }
*{ box-sizing:border-box; }
html{ -webkit-print-color-adjust:exact; print-color-adjust:exact; }

body{
  margin:0; color:var(--ink);
  font-family:Cambria, Georgia, "Times New Roman", "Nyala", serif;
  font-size:10.3pt; line-height:1.5;
}

h1,h2,h3,h4,h5,h6{
  font-family:"Segoe UI","Segoe UI Ethiopic","Nyala",system-ui,sans-serif;
  color:var(--ink); line-height:1.25;
  page-break-after:avoid; break-after:avoid-page;
}
h1{ font-size:16.5pt; font-weight:600; margin:0 0 13pt; padding-bottom:6pt;
    border-bottom:2.5pt solid var(--accent);
    page-break-before:always; break-before:page; }
/* The very first heading is the document title: no break before it, or the
   cover would open on an empty page. */
body > h1:first-of-type{ page-break-before:auto; break-before:auto; margin-top:0; }

h2{ font-size:12.4pt; font-weight:600; margin:19pt 0 7pt; color:#0E2A4A; }
h3{ font-size:11pt;   font-weight:600; margin:13pt 0 5pt; color:#1C3D2E; }
h4{ font-size:10.3pt; font-weight:700; margin:11pt 0 4pt; }
h5,h6{ font-size:10pt; font-weight:700; margin:9pt 0 3pt; }

p{ margin:0 0 8pt; text-align:justify; }

table{
  width:100%; border-collapse:collapse; margin:10pt 0 13pt;
  font-size:8.8pt; line-height:1.36;
  table-layout:auto; page-break-inside:auto;
}
thead{ display:table-header-group; }
tr{ page-break-inside:avoid; break-inside:avoid; }
th,td{ border:0.5pt solid var(--rule); padding:4pt 6pt; text-align:left; vertical-align:top; }
th{ background:var(--band); font-family:"Segoe UI",system-ui,sans-serif;
    font-weight:600; font-size:8.5pt; border-bottom:1.2pt solid #A9B6B1; }
tbody tr:nth-child(even) td{ background:#FBFCFC; }

code{
  font-family:Consolas,"Cascadia Mono","Courier New",monospace;
  font-size:8.5pt; background:#EDF1F0; border:0.4pt solid #D3DAD8;
  border-radius:2pt; padding:0.5pt 2.2pt; color:#1B3A2A;
  word-break:break-word;
}
pre.code{
  background:#F7F9F9; border:0.5pt solid var(--rule);
  border-left:2.5pt solid var(--accent); border-radius:2pt;
  padding:8pt 10pt; margin:10pt 0 13pt;
  page-break-inside:avoid; break-inside:avoid;
}
pre.code code{
  background:none; border:none; padding:0; font-size:8pt;
  line-height:1.4; color:#1D2B25;
  white-space:pre-wrap; word-break:break-word;
}

blockquote{
  margin:10pt 0 13pt; padding:8pt 12pt;
  background:#F2F7FD; border-left:2.5pt solid var(--accent); color:#23343D;
}
blockquote p:last-child{ margin-bottom:0; }
hr{ border:none; border-top:0.6pt solid var(--rule); margin:15pt 0; }

ul,ol{ margin:0 0 9pt; padding-left:17pt; }
li{ margin:0 0 3.2pt; }
li > ul, li > ol{ margin:3.2pt 0 1.5pt; }
li > p{ margin-bottom:4pt; }
ul{ list-style-type:disc; }
ul ul{ list-style-type:circle; }
ol{ list-style-type:decimal; }

strong{ font-weight:700; }
em{ font-style:italic; }
a{ color:#14509C; text-decoration:none; }

.toc-title{ border-bottom:2.5pt solid var(--accent); margin-bottom:11pt; }
.toc-1{ font-weight:600; margin:7pt 0 2pt; font-size:10pt; }
.toc-2{ margin:0 0 1.5pt 12pt; font-size:8.9pt; color:var(--muted); }
.toc-1 a{ color:#0E2A4A; }
.toc-2 a{ color:var(--muted); }

/* Running footer. Chromium ignores margin boxes in @page, so the page number is
   supplied by the print engine instead (see print-pdf.ps1 header/footer args). */
`;

const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Addis Ababa Transport Bureau — Digital Public Transport Modernisation Programme</title>
<style>${CSS}</style>
</head>
<body>
${body}
</body>
</html>
`;

writeFileSync(outArg, html, 'utf8');
console.log(`wrote ${outArg} (${html.length} bytes, ${headings.length} headings)`);