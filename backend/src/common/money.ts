/**
 * Money helpers.
 *
 * Everything in this system is integer minor units (fils).
 * 1 ETB = 100 fils. Never use floats for money anywhere in the codebase —
 * floating point money is a reconciliation bug waiting to happen.
 */

export const FILS_PER_ETB = 100;
export const DEFAULT_CURRENCY = 'ETB';

export interface Money {
  /** Signed integer amount in minor units. */
  readonly fils: number;
  readonly currency: string;
}

export function money(fils: number, currency: string = DEFAULT_CURRENCY): Money {
  if (!Number.isInteger(fils)) {
    // Catching this at the boundary is far cheaper than discovering it in a
    // settlement report months later.
    throw new Error(
      `Money must be an integer number of fils, received: ${fils}`,
    );
  }
  return { fils, currency };
}

export function etb(fils: number): Money {
  return money(fils, DEFAULT_CURRENCY);
}

export function zero(currency: string = DEFAULT_CURRENCY): Money {
  return { fils: 0, currency };
}

export function addFils(a: number, b: number): number {
  assertInteger(a);
  assertInteger(b);
  return a + b;
}

/**
 * Proportional percentage applied to an integer amount, rounding half-up.
 *
 * Math.round on a float intermediate is acceptable *inside* this function
 * because the result is immediately rounded back to an integer — the rounding
 * error cannot escape. Doing `amount * 0.9` and storing the float does not
 * have that property.
 */
export function applyPercent(fils: number, percent: number): number {
  assertInteger(fils);
  return Math.round((fils * percent) / 100);
}

export function clampNonNegative(fils: number): number {
  return Math.max(0, fils);
}

/** Render for display only. Never parse this back. */
export function formatMoney(m: Money, locale = 'en'): string {
  const major = (m.fils / FILS_PER_ETB).toFixed(2);
  const formatted = new Intl.NumberFormat(
    locale === 'am' ? 'am-ET' : 'en-ET',
    { minimumFractionDigits: 2, maximumFractionDigits: 2 },
  ).format(Number(major));
  return `${formatted} ${m.currency}`;
}

/** Metres -> kilometres rounded to 2dp, for display. */
export function metersToKm(meters: number): number {
  return Math.round((meters / 1000) * 100) / 100;
}

function assertInteger(value: number): void {
  if (!Number.isInteger(value)) {
    throw new Error(`Expected integer fils, received: ${value}`);
  }
}
