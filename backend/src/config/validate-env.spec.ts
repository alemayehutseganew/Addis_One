import {
  assertValidConfig,
  collectConfigProblems,
  redact,
} from './validate-env';

const valid = (extra: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv => ({
  DATABASE_URL: 'postgresql://addis:pw@localhost:5433/addis_one?schema=public',
  JWT_ACCESS_SECRET: 'x'.repeat(40),
  NODE_ENV: 'development',
  ...extra,
});

/**
 * These exist because a real deployment failed with Prisma's
 * "the validation schema for datasource `db` specifies provider = postgresql"
 * message, which blames schema.prisma rather than the environment variable the
 * operator set. The tests pin the behaviour that makes the next occurrence a
 * one-line diagnosis.
 */
describe('collectConfigProblems', () => {
  it('accepts a correct configuration', () => {
    expect(collectConfigProblems(valid())).toEqual([]);
  });

  it('reports a missing DATABASE_URL rather than letting Prisma fail', () => {
    const problems = collectConfigProblems({ JWT_ACCESS_SECRET: 'y'.repeat(40) });
    expect(problems.map((p) => p.variable)).toContain('DATABASE_URL');
    expect(problems[0].detail).toMatch(/User\/System environment/);
  });

  it('rejects a non-PostgreSQL URL, the exact cause of P1012', () => {
    const problems = collectConfigProblems(
      valid({ DATABASE_URL: 'mysql://someone:pw@localhost:3306/other' }),
    );
    expect(problems).toHaveLength(1);
    expect(problems[0].variable).toBe('DATABASE_URL');
    expect(problems[0].detail).toContain('mysql:');
  });

  it('accepts the postgres:// alias as well as postgresql://', () => {
    expect(
      collectConfigProblems(valid({ DATABASE_URL: 'postgres://a:b@h:5432/d' })),
    ).toEqual([]);
  });

  it('never echoes a password back into the message', () => {
    const problems = collectConfigProblems(
      valid({ DATABASE_URL: 'mysql://someone:hunter2@localhost:3306/other' }),
    );
    expect(problems[0].detail).not.toContain('hunter2');
  });

  it('reports every problem at once rather than one restart per mistake', () => {
    const problems = collectConfigProblems({});
    expect(problems.map((p) => p.variable).sort()).toEqual([
      'DATABASE_URL',
      'JWT_ACCESS_SECRET',
    ]);
  });

  it('only enforces secret length in production', () => {
    expect(collectConfigProblems(valid({ JWT_ACCESS_SECRET: 'short' }))).toEqual([]);
    expect(
      collectConfigProblems(
        valid({ JWT_ACCESS_SECRET: 'short', NODE_ENV: 'production' }),
      ).map((p) => p.variable),
    ).toEqual(['JWT_ACCESS_SECRET']);
  });
});

describe('redact', () => {
  it('hides the password but keeps host and database', () => {
    expect(redact('postgresql://addis:hunter2@localhost:5433/addis_one')).toBe(
      'postgresql://addis:***@localhost:5433/addis_one',
    );
  });

  it('leaves a URL with no credentials untouched', () => {
    expect(redact('postgresql://localhost:5432/d')).toBe(
      'postgresql://localhost:5432/d',
    );
  });
});

describe('assertValidConfig', () => {
  it('stays silent on a good configuration', () => {
    expect(() => assertValidConfig(valid())).not.toThrow();
  });

  it('names the variable in the thrown error', () => {
    expect(() =>
      assertValidConfig({ DATABASE_URL: 'mysql://a:b@h/d', JWT_ACCESS_SECRET: 'z' }),
    ).toThrow(/DATABASE_URL/);
  });
});