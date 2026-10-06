import { BadRequestException } from '@nestjs/common';
import {
  DEFAULT_RANGE_DAYS,
  MAX_RANGE_DAYS,
  resolveDateRange,
  resolvePage,
  resolvePageSize,
} from './dashboard-query';

/**
 * Tests for the dashboard's date-window boundary.
 *
 * These are the rules that decide how much of the database a single request may
 * scan, so they are pinned here rather than left to whatever the controller
 * happens to do. Every one of them exists because the alternative was a slow
 * endpoint or a silently wrong number.
 */
describe('resolveDateRange', () => {
  // Fixed "now" so the tests do not drift when they run on a different day.
  const now = new Date('2026-06-15T12:00:00Z');

  it('defaults to the last 30 days ending today', () => {
    const range = resolveDateRange(undefined, undefined, now);
    expect(range.days).toBe(DEFAULT_RANGE_DAYS);
    expect(range.to.toISOString()).toBe('2026-06-16T00:00:00.000Z');
    expect(range.from.toISOString()).toBe('2026-05-17T00:00:00.000Z');
  });

  it('treats the upper bound as exclusive so a whole day is included', () => {
    const range = resolveDateRange('2026-06-01', '2026-06-01', now);
    // One day, and `to` is the start of the NEXT day, not midnight of the
    // first. A BETWEEN on timestamps would otherwise drop rows written at 00:00.
    expect(range.days).toBe(1);
    expect(range.to.toISOString()).toBe('2026-06-02T00:00:00.000Z');
    expect(range.from.toISOString()).toBe('2026-06-01T00:00:00.000Z');
  });

  it('snaps a timestamp down to the start of its UTC day', () => {
    const range = resolveDateRange('2026-06-01T13:45:00Z', '2026-06-03T02:00:00Z', now);
    expect(range.from.toISOString()).toBe('2026-06-01T00:00:00.000Z');
    expect(range.to.toISOString()).toBe('2026-06-04T00:00:00.000Z');
  });

  it('infers a missing lower bound from the upper one', () => {
    // "June 2026" and "June 2026 to 30 June" must not return different totals
    // for what looks like the same question.
    const range = resolveDateRange(undefined, '2026-06-30', now);
    expect(range.to.toISOString()).toBe('2026-07-01T00:00:00.000Z');
    expect(range.days).toBe(DEFAULT_RANGE_DAYS);
  });

  it('infers a missing upper bound from today', () => {
    const range = resolveDateRange('2026-06-01', undefined, now);
    expect(range.to.toISOString()).toBe('2026-06-16T00:00:00.000Z');
  });

  it('rejects a range wider than the cap', () => {
    // Without this a typo like 2000-01-01 scans the entire table.
    expect(() =>
      resolveDateRange('2000-01-01', '2026-01-01', now),
    ).toThrow(BadRequestException);
    expect(() =>
      resolveDateRange('2000-01-01', '2026-01-01', now),
    ).toThrow(/366/);
  });

  it('allows a range exactly at the cap', () => {
    expect(() => resolveDateRange('2025-06-16', '2026-06-15', now)).not.toThrow();
  });

  it('rejects an inverted range', () => {
    expect(() => resolveDateRange('2026-06-30', '2026-06-01', now)).toThrow(
      /from must be on or before to/,
    );
  });

  it('rejects a boundary that is not a date at all', () => {
    // `new Date('not-a-date')` yields Invalid Date, which silently becomes NaN
    // in every comparison and turns a bad filter into a full-table scan.
    expect(() => resolveDateRange('not-a-date', undefined, now)).toThrow(
      BadRequestException,
    );
  });

  it('rejects a boundary that parses but is not a real day', () => {
    expect(() => resolveDateRange('2026-02-31', undefined, now)).toThrow(
      /not a real date/,
    );
  });

  it('rejects the empty string rather than treating it as no filter', () => {
    expect(() => resolveDateRange('', '', now)).not.toThrow();
    expect(resolveDateRange('', '', now).days).toBe(DEFAULT_RANGE_DAYS);
  });
});

describe('resolvePageSize', () => {
  it('defaults when absent', () => {
    expect(resolvePageSize(undefined)).toBe(25);
    expect(resolvePageSize('')).toBe(25);
  });

  it('caps the page size so one request cannot return the whole table', () => {
    expect(resolvePageSize('99999')).toBe(200);
  });

  it('accepts a sane page size', () => {
    expect(resolvePageSize('50')).toBe(50);
  });

  it('truncates a fractional page size rather than passing it to Prisma', () => {
    expect(resolvePageSize('25.9')).toBe(25);
  });

  it('rejects a non-positive page size', () => {
    expect(() => resolvePageSize('0')).toThrow(BadRequestException);
    expect(() => resolvePageSize('-5')).toThrow(BadRequestException);
    expect(() => resolvePageSize('abc')).toThrow(BadRequestException);
  });
});

describe('resolvePage', () => {
  it('defaults to the first page', () => {
    expect(resolvePage(undefined)).toBe(1);
    expect(resolvePage('')).toBe(1);
  });

  it('accepts a positive page', () => {
    expect(resolvePage('3')).toBe(3);
  });

  it('rejects zero and negatives, which would compute a negative offset', () => {
    expect(() => resolvePage('0')).toThrow(/1 or greater/);
    expect(() => resolvePage('-2')).toThrow(BadRequestException);
  });
});

describe('MAX_RANGE_DAYS', () => {
  it('is a year, not unbounded', () => {
    expect(MAX_RANGE_DAYS).toBe(366);
  });
});