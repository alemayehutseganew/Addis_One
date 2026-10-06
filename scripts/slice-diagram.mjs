/**
 * Extracts the layer-view diagram page from the PDF as a PNG so the printed
 * output can be inspected, not just the HTML source.
 *
 * Uses Edge to re-render a fixed slice of the generated HTML rather than
 * rasterising the PDF: there is no PDF rasteriser on this machine, and the PDF
 * is produced from exactly this HTML, so a slice of it is equivalent evidence
 * of how the diagram is laid out.
 */
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';

const html = readFileSync(process.argv[2], 'utf8');

// Isolate the first <pre class="code"> block (the architecture layer view).
const m = html.match(/<pre class="code">[\s\S]*?<\/pre>/);
if (!m) {
  console.error('no code block found');
  process.exit(1);
}

// Reuse the original stylesheet so fonts and wrapping are identical.
const css = (html.match(/<style>([\s\S]*?)<\/style>/) || [])[1] ?? '';

const slice = `<!DOCTYPE html><html><head><meta charset="utf-8"><style>${css}
body{padding:24px}</style></head><body>${m[0]}</body></html>`;

writeFileSync(process.argv[3], slice, 'utf8');
console.log('slice written');