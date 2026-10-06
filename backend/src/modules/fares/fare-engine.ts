/**
 * Fare engine — pure domain logic.
 *
 * Deliberately free of Prisma/Nest imports so it can be unit tested in
 * isolation. Persistence lives in FareService; this module only decides *which*
 * rule applies and *what* the fare is.
 *
 * Core requirement (architecture.md I3): the calculation must be reproducible
 * and explainable from the returned snapshot alone, long after the underlying
 * rules have been superseded.
 */

import { applyPercent, clampNonNegative } from '../../common/money';

/** Shape of a fare rule as persisted. Mirrors the `FareRule` model. */
export interface FareRuleRecord {
  id: string;
  ruleKey: string;
  version: number;
  mode: string;
  routeId: string | null;
  operatorId: string | null;
  originZone: string | null;
  destinationZone: string | null;
  distanceFromMeters: number | null;
  distanceToMeters: number | null;
  baseFareFils: number;
  perKmFils: number;
  minimumFareFils: number;
  currency: string;
  status: string;
  effectiveFrom: Date;
  effectiveUntil: Date | null;
}

export interface FareQuery {
  mode: string;
  routeId?: string | null;
  operatorId?: string | null;
  originZone?: string | null;
  destinationZone?: string | null;
  distanceMeters: number;
  /** Concession code, e.g. STUDENT. Unapproved concessions must not reach here. */
  concessionCode?: string | null;
  concessionDiscountPercent?: number | null;
  /** Optional transfer discount in fils, applied after concession. */
  transferDiscountFils?: number;
  /** Travel time, used by time-based (peak/off-peak) rules later. */
  at: Date;
}

export interface FareBreakdown {
  ruleId: string | null;
  ruleKey: string | null;
  ruleVersion: number | null;
  baseFareFils: number;
  distanceFareFils: number;
  discountFils: number;
  totalFareFils: number;
  currency: string;
  /** True when no rule matched and a safe default was applied. */
  usedFallback: boolean;
  explanation: string;
}

/**
 * Ordered most-specific first. A route+zone rule beats a citywide zone rule,
 * which beats a bare citywide mode rule.
 */
function specificityScore(rule: FareRuleRecord): number {
  let score = 0;
  if (rule.routeId) score += 8;
  if (rule.operatorId) score += 4;
  if (rule.originZone && rule.destinationZone) score += 4;
  else if (rule.originZone || rule.destinationZone) score += 2;
  if (rule.distanceFromMeters !== null && rule.distanceToMeters !== null) score += 2;
  // Later versions are preferred over earlier ones at equal specificity.
  return score * 1000 + rule.version;
}

export function isRuleInEffect(rule: FareRuleRecord, at: Date): boolean {
  if (rule.status !== 'ACTIVE') return false;
  if (rule.effectiveFrom > at) return false;
  if (rule.effectiveUntil && rule.effectiveUntil <= at) return false;
  return true;
}

export function ruleMatches(rule: FareRuleRecord, query: FareQuery): boolean {
  if (!isRuleInEffect(rule, query.at)) return false;
  if (rule.mode !== query.mode) return false;

  // Null on the rule means "applies to any"; a concrete value must match exactly.
  if (rule.routeId && rule.routeId !== query.routeId) return false;
  if (rule.operatorId && rule.operatorId !== query.operatorId) return false;
  if (rule.originZone && rule.originZone !== query.originZone) return false;
  if (rule.destinationZone && rule.destinationZone !== query.destinationZone) {
    return false;
  }

  if (
    rule.distanceFromMeters !== null &&
    query.distanceMeters < rule.distanceFromMeters
  ) {
    return false;
  }
  if (
    rule.distanceToMeters !== null &&
    query.distanceMeters > rule.distanceToMeters
  ) {
    return false;
  }

  return true;
}

export function selectFareRule(
  rules: FareRuleRecord[],
  query: FareQuery,
): FareRuleRecord | null {
  const matching = rules.filter((rule) => ruleMatches(rule, query));
  if (matching.length === 0) return null;
  return matching.sort((a, b) => specificityScore(b) - specificityScore(a))[0];
}

export function calculateFare(
  rules: FareRuleRecord[],
  query: FareQuery,
  fallbackBaseFils = 0,
): FareBreakdown {
  const rule = selectFareRule(rules, query);

  if (!rule) {
    // Failing closed is correct here: inventing a fare would be worse than
    // surfacing a zero, and it guarantees the event is visible to monitoring.
    return {
      ruleId: null,
      ruleKey: null,
      ruleVersion: null,
      baseFareFils: fallbackBaseFils,
      distanceFareFils: 0,
      discountFils: 0,
      totalFareFils: clampNonNegative(fallbackBaseFils),
      currency: rules[0]?.currency ?? 'ETB',
      usedFallback: true,
      explanation:
        'No fare rule matched the query; fallback base applied and flagged for review.',
    };
  }

  const distanceKm = query.distanceMeters / 1000;
  // Round per-km component to whole fils so no float is retained.
  const distanceFareFils = Math.round(rule.perKmFils * distanceKm);
  const subtotal = rule.baseFareFils + distanceFareFils;

  let discountFils = 0;
  if (
    query.concessionCode &&
    query.concessionDiscountPercent &&
    query.concessionDiscountPercent < 100
  ) {
    discountFils += subtotal - applyPercent(subtotal, query.concessionDiscountPercent);
  }
  if (query.transferDiscountFils && query.transferDiscountFils > 0) {
    discountFils += query.transferDiscountFils;
  }

  // Minimum fare floor applies before discounts, so a concession can never
  // drive a fare negative.
  const floored = Math.max(subtotal, rule.minimumFareFils);
  const total = clampNonNegative(floored - discountFils);

  return {
    ruleId: rule.id,
    ruleKey: rule.ruleKey,
    ruleVersion: rule.version,
    baseFareFils: rule.baseFareFils,
    distanceFareFils,
    discountFils,
    totalFareFils: total,
    currency: rule.currency,
    usedFallback: false,
    explanation:
      `Rule ${rule.ruleKey} v${rule.version} (${rule.mode}) applied: ` +
      `base ${rule.baseFareFils} + distance ${distanceFareFils} - discount ${discountFils} = ${total} fils`,
  };
}
