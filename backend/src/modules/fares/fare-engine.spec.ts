import {
  calculateFare,
  selectFareRule,
  ruleMatches,
  isRuleInEffect,
  FareRuleRecord,
  FareQuery,
} from './fare-engine';

const NOW = new Date('2026-01-15T08:00:00.000Z');

function rule(overrides: Partial<FareRuleRecord> = {}): FareRuleRecord {
  return {
    id: 'rule-1',
    ruleKey: 'CITY-BUS-BASE',
    version: 1,
    mode: 'BUS',
    routeId: null,
    operatorId: null,
    originZone: null,
    destinationZone: null,
    distanceFromMeters: null,
    distanceToMeters: null,
    baseFareFils: 1500,
    perKmFils: 500,
    minimumFareFils: 1500,
    currency: 'ETB',
    status: 'ACTIVE',
    effectiveFrom: new Date('2025-01-01T00:00:00.000Z'),
    effectiveUntil: null,
    ...overrides,
  };
}

function query(overrides: Partial<FareQuery> = {}): FareQuery {
  return {
    mode: 'BUS',
    distanceMeters: 5000,
    at: NOW,
    ...overrides,
  };
}

describe('fare engine', () => {
  describe('rule effectiveness', () => {
    it('accepts an active rule inside its window', () => {
      expect(isRuleInEffect(rule(), NOW)).toBe(true);
    });

    it('rejects a rule that has not started', () => {
      const future = rule({ effectiveFrom: new Date('2027-01-01T00:00:00.000Z') });
      expect(isRuleInEffect(future, NOW)).toBe(false);
    });

    it('rejects an expired rule', () => {
      const expired = rule({ effectiveUntil: new Date('2025-06-01T00:00:00.000Z') });
      expect(isRuleInEffect(expired, NOW)).toBe(false);
    });

    it('rejects a non-active rule even inside the window', () => {
      expect(isRuleInEffect(rule({ status: 'DRAFT' }), NOW)).toBe(false);
      expect(isRuleInEffect(rule({ status: 'SUPERSEDED' }), NOW)).toBe(false);
    });
  });

  describe('rule matching', () => {
    it('treats null on the rule as "any value"', () => {
      expect(ruleMatches(rule(), query())).toBe(true);
    });

    it('requires exact match when the rule pins a route', () => {
      const r = rule({ routeId: 'route-a' });
      expect(ruleMatches(r, query({ routeId: 'route-a' }))).toBe(true);
      expect(ruleMatches(r, query({ routeId: 'route-b' }))).toBe(false);
    });

    it('requires exact match when the rule pins zones', () => {
      const r = rule({ originZone: 'A', destinationZone: 'B' });
      expect(ruleMatches(r, query({ originZone: 'A', destinationZone: 'B' }))).toBe(true);
      expect(ruleMatches(r, query({ originZone: 'A', destinationZone: 'C' }))).toBe(false);
    });


  describe('rule selection', () => {
    it('prefers a route-specific rule over a citywide one', () => {
      const citywide = rule({ id: 'a', ruleKey: 'CITY', routeId: null, baseFareFils: 1000 });
      const routeSpecific = rule({ id: 'b', ruleKey: 'R12', routeId: 'route-a', baseFareFils: 2000 });
      const selected = selectFareRule([citywide, routeSpecific], query({ routeId: 'route-a' }));
      expect(selected?.id).toBe('b');
    });

    it('prefers the highest version at equal specificity', () => {
      const v1 = rule({ id: 'a', ruleKey: 'X', version: 1, baseFareFils: 1000 });
      const v2 = rule({ id: 'b', ruleKey: 'X', version: 2, baseFareFils: 2000 });
      expect(selectFareRule([v1, v2], query())?.version).toBe(2);
    });

    it('ignores superseded rules', () => {
      const old = rule({ id: 'a', ruleKey: 'X', status: 'SUPERSEDED' });
      expect(selectFareRule([old], query())).toBeNull();
    });

    it('returns null when nothing matches', () => {
      expect(selectFareRule([rule()], query({ mode: 'TRAIN' }))).toBeNull();
    });
  });

  describe('fare calculation', () => {
    it('computes base plus distance in whole fils', () => {
      const result = calculateFare([rule()], query({ distanceMeters: 5000 }));
      // 1500 base + 500/km * 5km = 1500 + 2500 = 4000
      expect(result.baseFareFils).toBe(1500);
      expect(result.distanceFareFils).toBe(2500);
      expect(result.totalFareFils).toBe(4000);
      expect(result.usedFallback).toBe(false);
    });

    it('always produces an integer', () => {
      // 3.7km * 333 fils would be 1232.1 without rounding
      const r = rule({ baseFareFils: 0, perKmFils: 333, minimumFareFils: 0 });
      const result = calculateFare([r], query({ distanceMeters: 3700 }));
      expect(Number.isInteger(result.totalFareFils)).toBe(true);
      expect(result.totalFareFils).toBe(1232);
    });

    it('applies the minimum fare floor', () => {
      const r = rule({ baseFareFils: 100, perKmFils: 0, minimumFareFils: 1500 });
      expect(calculateFare([r], query()).totalFareFils).toBe(1500);
    });

    it('applies a concession discount', () => {
      const result = calculateFare([rule()], query({
        distanceMeters: 5000,
        concessionCode: 'STUDENT',
        concessionDiscountPercent: 50,
      }));
      // 4000 * 50% = 2000 discount
      expect(result.discountFils).toBe(2000);
      expect(result.totalFareFils).toBe(2000);
    });

    it('applies a transfer discount on top of the concession', () => {
      const result = calculateFare([rule()], query({
        distanceMeters: 5000,
        concessionCode: 'STUDENT',
        concessionDiscountPercent: 50,
        transferDiscountFils: 300,
      }));
      expect(result.discountFils).toBe(2300);
      expect(result.totalFareFils).toBe(1700);
    });

    it('never returns a negative fare', () => {
      const result = calculateFare([rule()], query({
        distanceMeters: 1000,
        transferDiscountFils: 999999,
      }));
      expect(result.totalFareFils).toBe(0);
    });

    it('pins the rule version for auditability', () => {
      const r = rule({ ruleKey: 'CITY-BUS-BASE', version: 7 });
      const result = calculateFare([r], query());
      expect(result.ruleKey).toBe('CITY-BUS-BASE');
      expect(result.ruleVersion).toBe(7);
    });

    it('flags and zeroes when no rule matches', () => {
      const result = calculateFare([rule()], query({ mode: 'TRAIN' }));
      expect(result.usedFallback).toBe(true);
      expect(result.ruleId).toBeNull();
      expect(result.totalFareFils).toBe(0);
    });
  });
});

    it('enforces inclusive distance bounds', () => {
      const r = rule({ distanceFromMeters: 5000, distanceToMeters: 10000 });
      expect(ruleMatches(r, query({ distanceMeters: 5000 }))).toBe(true);
      expect(ruleMatches(r, query({ distanceMeters: 10000 }))).toBe(true);
      expect(ruleMatches(r, query({ distanceMeters: 4999 }))).toBe(false);
      expect(ruleMatches(r, query({ distanceMeters: 10001 }))).toBe(false);
    });

    it('never matches across modes', () => {
      expect(ruleMatches(rule({ mode: 'BUS' }), query({ mode: 'TRAIN' }))).toBe(false);
    });
  });
