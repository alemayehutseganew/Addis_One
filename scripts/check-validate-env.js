// Standalone check of the compiled config validator.
//
// Jest cannot be relied on inside this sandbox: it is killed mid-run on Windows
// (0xC0000139, worker spawn) and a second invocation produces an empty log. This
// script runs in about a second against dist/, so it is used for the live gate.
// The same assertions exist as a real Jest suite in
// backend/src/config/validate-env.spec.ts, which is what CI runs.
const v = require('../backend/dist/config/validate-env.js');

let failed = 0;
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failed++;
  console.log(
    `${ok ? 'PASS' : 'FAIL'}  ${name}` +
      (ok ? '' : `\n        expected ${JSON.stringify(expected)}\n        actual   ${JSON.stringify(actual)}`),
  );
}

const base = {
  DATABASE_URL: 'postgresql://addis:pw@localhost:5433/addis_one?schema=public',
  JWT_ACCESS_SECRET: 'x'.repeat(40),
  NODE_ENV: 'development',
};
const vars = (e) => v.collectConfigProblems(e).map((p) => p.variable);

check('accepts a correct configuration', vars(base), []);
check('rejects missing DATABASE_URL', vars({ JWT_ACCESS_SECRET: base.JWT_ACCESS_SECRET }).includes('DATABASE_URL'), true);
check('rejects mysql url (the P1012 cause)', vars({ ...base, DATABASE_URL: 'mysql://a:b@h:3306/d' }), ['DATABASE_URL']);
check('accepts postgres:// alias', vars({ ...base, DATABASE_URL: 'postgres://a:b@h:5432/d' }), []);
check('does not enforce secret length in dev', vars({ ...base, JWT_ACCESS_SECRET: 'short' }), []);
check('enforces secret length in prod', vars({ ...base, JWT_ACCESS_SECRET: 'short', NODE_ENV: 'production' }), ['JWT_ACCESS_SECRET']);
check('reports all problems at once', vars({}).sort(), ['DATABASE_URL', 'JWT_ACCESS_SECRET']);

check(
  'redacts the password',
  v.redact('postgresql://addis:hunter2@localhost:5433/addis_one'),
  'postgresql://addis:***@localhost:5433/addis_one',
);
check('leaves credential-less url alone', v.redact('postgresql://localhost:5432/d'), 'postgresql://localhost:5432/d');
check(
  'no password leaks into the problem message',
  v.collectConfigProblems({ ...base, DATABASE_URL: 'mysql://a:hunter2@h:3306/d' })[0].detail.includes('hunter2'),
  false,
);
check('assertValidConfig stays silent when valid', (() => { try { v.assertValidConfig(base); return true; } catch { return false; } })(), true);
check(
  'assertValidConfig names the variable',
  (() => { try { v.assertValidConfig({ ...base, DATABASE_URL: 'mysql://a:b@h/d' }); return 'no-throw'; } catch (e) { return e.message.includes('DATABASE_URL'); } })(),
  true,
);

console.log(`\n${failed === 0 ? 'ALL PASSED' : failed + ' FAILED'}`);
process.exit(failed === 0 ? 0 : 1);