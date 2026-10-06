/**
 * Verifies the generated HTML still holds the box-drawing / arrow / Ethiopic
 * characters used by the architecture and procedure diagrams.
 *
 * Reads as UTF-8 explicitly. An earlier check extracted a sample through
 * PowerShell Get-Content/Set-Content, which round-tripped the file as the ANSI
 * code page and produced mojibake in the SAMPLE — not in the converter output.
 * Reading the real artefact in Node is the only trustworthy way to settle it.
 */
import { readFileSync, writeFileSync } from 'node:fs';

const html = readFileSync(process.argv[2], 'utf8');

const checks = [
  ['box vertical U+2502', '\u2502'],
  ['box horizontal U+2500', '\u2500'],
  ['box tee U+251C', '\u251C'],
  ['box corner U+2514', '\u2514'],
  ['arrow right U+2192', '\u2192'],
  ['arrow down U+2193', '\u2193'],
  ['black square U+25A0', '\u25A0'],
  ['em dash U+2014', '\u2014'],
  ['left arrow U+2190', '\u2190'],
  ['Ethiopic (Piazza)', '\u12A8'],
  ['mojibake marker "â"', '\u00E2'],
  ['mojibake marker "€"', '\u20AC'],
  ['replacement char U+FFFD', '\uFFFD'],
];

const rows = checks.map(([label, ch]) => {
  const n = html.split(ch).length - 1;
  return `${n === 0 ? 'MISSING' : 'present'}  ${label}  (${n})`;
});

const mojibake = html.match(/[\u00C2-\u00C3][\u0080-\u00BF]|â[\u0080-\u009F]|Ã[\u0080-\u009F]/g);
rows.push('');
rows.push(mojibake ? `MOJIBAKE_SEQUENCES=${mojibake.length}` : 'MOJIBAKE_SEQUENCES=0');

writeFileSync(process.argv[3], rows.join('\n'), 'utf8');
console.log(rows.join('\n'));