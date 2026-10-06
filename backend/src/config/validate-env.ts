/**
 * Boot-time configuration checks.
 *
 * Run before the Nest application is created, so a misconfigured deployment
 * fails immediately with an actionable sentence instead of dying later inside
 * Prisma.
 *
 * This exists because of a real outage: a stale user-scope `DATABASE_URL`
 * pointing at an unrelated project (`bank_reviews`) took precedence over
 * `backend/.env`, and the API surfaced it as
 *
 *     P1012 The validation schema for datasource `db` specifies
 *     `provider = "postgresql"`, but the resolved URL is `mysql://…`
 *
 * That message is technically accurate and practically useless. It names Prisma
 * internals rather than the environment variable the operator actually controls,
 * so the one-minute diagnosis ("is DATABASE_URL set in the shell, and does
 * backend/.env disagree with it?") became a twenty-minute one. A boot-time check
 * can say exactly that, and can also print which source won — because "which of
 * my three sources is authoritative" is the real question.
 */

export type ConfigProblem = { variable: string; detail: string };

/**
 * Returns the problems found rather than throwing, so the caller can report all
 * of them at once. Fixing a broken deploy one restart per mistake is needlessly
 * slow.
 */
export function collectConfigProblems(
  env: NodeJS.ProcessEnv = process.env,
): ConfigProblem[] {
  const problems: ConfigProblem[] = [];
  const raw = env.DATABASE_URL;

  if (!raw) {
    problems.push({
      variable: 'DATABASE_URL',
      detail:
        'is not set. Copy backend/.env.example to backend/.env, or export the ' +
        'variable. Note that a stale value in your User/System environment ' +
        'overrides backend/.env — check with ' +
        '[Environment]::GetEnvironmentVariable("DATABASE_URL","User").',
    });
  } else {
    // Redacted before it is ever printed: a connection string carries a password,
    // and this text lands in CI output and terminal scrollback.
    const scheme = raw.slice(0, raw.indexOf(':') + 1).toLowerCase();
    if (scheme !== 'postgresql:' && scheme !== 'postgres:') {
      problems.push({
        variable: 'DATABASE_URL',
        detail:
          `must be a PostgreSQL URL but resolves to "${scheme}". ` +
          `Did an unrelated project's URL leak into your environment? ` +
          `Resolved (redacted): ${redact(raw)}`,
      });
    }
  }

  // Refuses to boot rather than quietly serving a live authentication bypass.
  // A dev flag that reaches production is the kind of mistake that is invisible
  // until someone finds the route, so it is made a hard startup failure here:
  // the operator has to delete the variable deliberately to get past it.
  if (env.NODE_ENV === 'production' && env.DEV_STAFF_LOGIN === 'true') {
    problems.push({
      variable: 'DEV_STAFF_LOGIN',
      detail:
        'is true in production. This flag exposes POST /api/v1/auth/dev-login, ' +
        'which signs in any staff phone number without a verification code. ' +
        'Remove it from the production environment.',
    });
  }

  const jwt = env.JWT_ACCESS_SECRET;
  if (!jwt) {
    problems.push({
      variable: 'JWT_ACCESS_SECRET',
      detail: 'is not set. No access token can be signed without it.',
    });
  } else if (env.NODE_ENV === 'production' && jwt.length < 32) {
    problems.push({
      variable: 'JWT_ACCESS_SECRET',
      detail:
        'is shorter than 32 characters in production. Every issued token ' +
        'becomes guessable.',
    });
  }

  return problems;
}

/**
 * Hides the password while leaving the host, port and database visible.
 *
 * Showing which database and which host is the entire diagnostic value of the
 * message; showing the password adds nothing but disclosure.
 */
export function redact(url: string): string {
  return url.replace(/:\/\/([^:]+):[^@]*@/, '://$1:***@');
}

/** Throws a single readable error listing every problem. */
export function assertValidConfig(env: NodeJS.ProcessEnv = process.env): void {
  const problems = collectConfigProblems(env);
  if (!problems.length) return;

  const detail = problems
    .map((p) => `  - ${p.variable} ${p.detail}`)
    .join('\n');

  throw new Error(
    `Refusing to start: invalid configuration.\n${detail}\n\n` +
      `See backend/.env for the expected values.`,
  );
}