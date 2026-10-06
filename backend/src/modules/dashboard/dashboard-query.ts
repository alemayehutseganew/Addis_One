import { BadRequestException } from '@nestjs/common';

/**
 * Dashboard date-window parsing.
 *
 * Kept as pure functions with no Prisma or Nest dependencies so the boundary
 * rules — defaults, caps, and what counts as a valid window — can be tested
 * directly. Every one of these exists to stop a single request from asking the
 * database to aggregate the entire table.
 */

/** Longest window any dashboard query will scan. */
export const MAX_RANGE_DAYS = 366;

/** Window used when the caller does not ask for one. */
export const DEFAULT_RANGE_DAYS = 30;

export interface DateRange {
  /** Inclusive lower bound. */
  from: Date;
  /** Exclusive upper bound. */
  to: Date;
  days: number;
}

/**
 * Parses a caller-supplied ISO date (`YYYY-MM-DD` or a full timestamp).
 *
 * `new Date('not-a-date')` yields an Invalid Date rather than throwing, and an
 * Invalid Date silently becomes `NaN` in every comparison downstream — which
 * turns a bad filter into a full-table scan instead of a 400. Rejecting it here
 * is the only place the mistake is still visible.
 */
function parseBoundary(raw: string, field: string): Date {
  const trimmed = raw.trim();
  if (!/^\d{4}-\d{2}-\d{2}(T[\d:.]+(Z|[+-]\d{2}:?\d{2})?)?$/.test(trimmed)) {
    throw new BadRequestException(
      `${field} must be an ISO date (YYYY-MM-DD) or timestamp`,
    );
  }
  const parsed = new Date(trimmed.length === 10 ? `${trimmed}T00:00:00.000Z` : trimmed);
  if (Number.isNaN(parsed.getTime())) {
    throw new BadRequestException(`${field} is not a real date`);
  }

  // JavaScript rolls impossible dates forward rather than rejecting them:
  // 2026-02-31 becomes 3 March. Left alone, a typo silently reports a different
  // window than the one asked for, which for a finance figure is worse than an
  // error because nothing looks wrong. A round-trip check catches it.
  if (trimmed.length === 10 && parsed.toISOString().slice(0, 10) !== trimmed) {
    throw new BadRequestException(`${field} is not a real date`);
  }

  return parsed;
}

/** Midnight UTC of the day `date` falls in. */
function startOfUtcDay(date: Date): Date {
  return new Date(
    Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()),
  );
}

function addDays(date: Date, days: number): Date {
  const next = new Date(date.getTime());
  next.setUTCDate(next.getUTCDate() + days);
  return next;
}

/**
 * Builds the window a query will actually run over.
 *
 * The upper bound is always exclusive and always snapped to a whole UTC day, so
 * "January" means January and a day with no rows is genuinely absent rather than
 * hidden behind a partial boundary. Comparing `createdAt < to` also avoids the
 * classic bug where a BETWEEN on timestamps drops every row written at exactly
 * midnight.
 *
 * With no arguments the window is the last 30 days ending today, which is the
 * question an office actually asks ("how are we doing"), as opposed to "sum
 * everything ever", which is slow and not an answer to anything.
 */
export function resolveDateRange(
  fromRaw?: string,
  toRaw?: string,
  now: Date = new Date(),
): DateRange {
  const today = startOfUtcDay(now);

  if (!fromRaw && !toRaw) {
    // Counted back from the exclusive upper bound, not from today. Backing off
    // from `today` instead yields a window one day WIDER than the `days` it
    // reports, and that disagreement quietly corrupts the previous-period
    // comparison, which is derived from the reported length.
    const to = addDays(today, 1);
    return {
      from: addDays(to, -DEFAULT_RANGE_DAYS),
      to,
      days: DEFAULT_RANGE_DAYS,
    };
  }

  // A missing bound is inferred from the other one rather than defaulting to
  // "30 days", so "June 2026" and "June 2026 to 30 June" cannot silently
  // return different totals for what looks like the same question.
  let to: Date;
  if (toRaw) {
    to = addDays(startOfUtcDay(parseBoundary(toRaw, 'to')), 1);
  } else {
    to = addDays(today, 1);
  }

  let from: Date;
  if (fromRaw) {
    from = startOfUtcDay(parseBoundary(fromRaw, 'from'));
  } else {
    from = addDays(to, -DEFAULT_RANGE_DAYS);
  }

  if (from >= to) {
    throw new BadRequestException('from must be on or before to');
  }

  const days = Math.round((to.getTime() - from.getTime()) / 86_400_000);
  if (days > MAX_RANGE_DAYS) {
    throw new BadRequestException(
      `range must not exceed ${MAX_RANGE_DAYS} days; requested ${days}`,
    );
  }

  return { from, to, days };
}

/** Clamps a caller-supplied page size so one request cannot return the whole table. */
export function resolvePageSize(raw: string | undefined, fallback = 25): number {
  if (raw === undefined || raw.trim() === '') return fallback;
  const requested = Number(raw);
  if (!Number.isFinite(requested) || requested <= 0) {
    throw new BadRequestException('pageSize must be a positive number');
  }
  return Math.min(Math.floor(requested), 200);
}

/** Clamps a caller-supplied page number to at least 1. */
export function resolvePage(raw: string | undefined): number {
  if (raw === undefined || raw.trim() === '') return 1;
  const requested = Number(raw);
  if (!Number.isFinite(requested) || requested < 1) {
    throw new BadRequestException('page must be 1 or greater');
  }
  return Math.floor(requested);
}
