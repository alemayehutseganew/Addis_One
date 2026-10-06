import { INestApplication, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Test } from '@nestjs/testing';
import { StaffRole } from '@prisma/client';
import request from 'supertest';

import { PrismaService } from '../../prisma/prisma.service';
import { AuthController, DevLoginService } from './auth.controller';
import { JwtAuthGuard } from './jwt-auth.guard';
import { StaffGuard } from './staff.guard';
import { OtpService } from './otp.service';
import { DASHBOARD_ROLES, SCAN_ROLES } from './policy';
import { TokenService } from './token.service';

/**
 * `GET /auth/staff-session` — the endpoint the inspector's handheld calls right
 * after sign-in to learn who it is and whether it may open the scanner.
 *
 * These tests drive the real guards over real HTTP rather than calling the
 * handler directly. The handler is a five-line projection of `request.staff`;
 * almost everything worth protecting here lives in the guards, and a test that
 * calls the handler proves only that the arithmetic in the body is correct.
 * The bugs that matter on this route are all wiring bugs — a route mounted
 * without `StaffGuard`, a role list that stopped matching the one the app trusts
 * — and wiring bugs are invisible to a unit test of the handler.
 */

const BEARER = 'test-access-token';
const INSPECTOR_PHONE = '+251911000009';
const DRIVER_PHONE = '+251911000007';

/** Exactly the shape StaffGuard's `select` returns. */
interface StaffRow {
  id: string;
  userId: string;
  role: StaffRole;
  operatorId: string | null;
  employeeCode: string | null;
  isActive: boolean;
  terminatedAt: Date | null;
  user: { displayName: string | null; phone: string };
}

function staffRowFor(
  role: StaffRole,
  phone: string,
  overrides: Partial<StaffRow> = {},
): StaffRow {
  return {
    id: `stf_${role}`,
    userId: 'usr_1',
    role,
    operatorId: 'opt_1',
    employeeCode: `EMP-${role}`,
    isActive: true,
    terminatedAt: null,
    user: { displayName: `${role} Tester`, phone },
    ...overrides,
  };
}

describe('GET /auth/staff-session', () => {
  let app: INestApplication;
  let db: { user: { findUnique: jest.Mock }; staff: { findUnique: jest.Mock } };
  let tokens: { verifyAccess: jest.Mock };

  const ACTIVE_USER = {
    id: 'usr_1',
    phone: INSPECTOR_PHONE,
    displayName: 'Selassie I Inspector',
    status: 'ACTIVE',
  };

  beforeEach(async () => {
    db = {
      user: { findUnique: jest.fn().mockResolvedValue({ ...ACTIVE_USER }) },
      staff: {
        findUnique: jest
          .fn()
          .mockResolvedValue(staffRowFor(StaffRole.INSPECTOR, INSPECTOR_PHONE)),
      },
    };
    tokens = {
      verifyAccess: jest
        .fn()
        .mockResolvedValue({ sub: 'usr_1', phone: INSPECTOR_PHONE }),
    };

    const moduleRef = await Test.createTestingModule({
      controllers: [AuthController],
      providers: [
        { provide: PrismaService, useValue: db },
        { provide: TokenService, useValue: tokens },
        // Neither OTP nor the dev shortcut is reachable from this route; they are
        // stubbed only because AuthController takes them as constructor
        // dependencies and the Nest injector requires a provider for each.
        { provide: OtpService, useValue: { issue: jest.fn(), verify: jest.fn() } },
        { provide: DevLoginService, useValue: { signIn: jest.fn() } },
        // DevLoginGuard is attached to the dev sign-in routes on this same
        // controller, so Nest constructs it even though this suite never calls
        // those routes, and its constructor takes ConfigService. Stubbed as
        // "not armed" so the bypass stays shut for these tests: a test module
        // that silently enabled it would be a test module that could pass
        // without the real guards ever being reached.
        { provide: ConfigService, useValue: { get: (_k: string, d?: string) => d } },
        // The two guards this route depends on. Nest resolves a class named in
        // `@UseGuards` from its own injectables, so it builds these regardless
        // of what the providers array says — which is why the ConfigService
        // above is needed even though no test here exercises the dev route.
        // Declaring them makes their dependencies a compile-time obligation
        // here: if a guard grew a new constructor parameter, this suite fails to
        // build rather than failing at runtime inside an unrelated test.
        JwtAuthGuard,
        StaffGuard,
      ],
    }).compile();

    app = moduleRef.createNestApplication();
    await app.init();
  });

  afterEach(async () => {
    // Guarded because a failure in beforeEach leaves `app` unset, and an
    // unguarded teardown would replace the real cause with a TypeError.
    await app?.close();
  });

  /** Signs in as `role` and calls the route. Defaults to a plain INSPECTOR. */
  function call(
    role: StaffRole = StaffRole.INSPECTOR,
    overrides: Partial<StaffRow> = {},
  ) {
    db.staff.findUnique.mockResolvedValue(
      staffRowFor(role, INSPECTOR_PHONE, overrides),
    );
    return request(app.getHttpServer())
      .get('/auth/staff-session')
      .set('Authorization', `Bearer ${BEARER}`);
  }

  /**
   * Signs in with a valid citizen token that holds no staff record.
   *
   * Separate from `call()` rather than an argument to it: `call` installs an
   * INSPECTOR row of its own, so expressing "no row at all" through its
   * overrides would mean overwriting the stub it just set — which reads as if
   * the guard were ignoring the database.
   */
  function passenger() {
    db.staff.findUnique.mockResolvedValue(null);
    return request(app.getHttpServer())
      .get('/auth/staff-session')
      .set('Authorization', `Bearer ${BEARER}`);
  }

  describe('refuses callers with no usable staff identity', () => {
    it('answers 401 with no bearer token', async () => {
      await request(app.getHttpServer()).get('/auth/staff-session').expect(401);
      // Nothing about the account should have been read on the way to the 401.
      expect(db.staff.findUnique).not.toHaveBeenCalled();
    });

    it('answers 401 when the token fails verification', async () => {
      tokens.verifyAccess.mockRejectedValue(
        new UnauthorizedException('Invalid access token'),
      );
      await call().expect(401);
    });

    it('answers 401 when the account has been suspended', async () => {
      // The token is still cryptographically valid; only live state can catch
      // this, which is precisely why JwtAuthGuard reloads the user.
      db.user.findUnique.mockResolvedValue({ ...ACTIVE_USER, status: 'SUSPENDED' });
      await call().expect(401);
    });

    it('answers 401 when the token names an account that no longer exists', async () => {
      db.user.findUnique.mockResolvedValue(null);
      await call().expect(401);
    });

    it('answers 403 for a signed-in passenger who holds no staff record', async () => {
      // A valid citizen token is not a staff identity. Without StaffGuard here
      // every registered passenger could enumerate their own role.
      await passenger().expect(403);
    });

    it('answers 403 when the staff record is deactivated', async () => {
      await call(StaffRole.INSPECTOR, { isActive: false }).expect(403);
    });

    it('answers 403 when the staff record is terminated', async () => {
      await call(StaffRole.INSPECTOR, { terminatedAt: new Date() }).expect(403);
    });

    it('never leaks the role of a rejected caller', async () => {
      // The refusal is uniform on purpose: a message naming the role would turn
      // this route into a probe for who holds which one.
      const passengerRes = await passenger().expect(403);
      expect(JSON.stringify(passengerRes.body)).not.toContain('INSPECTOR');
      expect(JSON.stringify(passengerRes.body)).not.toContain('DRIVER');
    });
  });

  describe('an INSPECTOR', () => {
    it('is told it may validate', async () => {
      const res = await call(StaffRole.INSPECTOR).expect(200);
      expect(res.body.permissions.canValidate).toBe(true);
    });

    it('is not handed dashboard powers by the route it was given', async () => {
      const res = await call(StaffRole.INSPECTOR).expect(200);
      expect(res.body.permissions.canManage).toBe(false);
      expect(res.body.permissions.cityWide).toBe(false);
    });

    it('is named on the session so the scanner can label itself', async () => {
      const res = await call(StaffRole.INSPECTOR).expect(200);
      expect(res.body.staff).toEqual({
        displayName: 'INSPECTOR Tester',
        employeeCode: 'EMP-INSPECTOR',
        role: StaffRole.INSPECTOR,
        operatorId: 'opt_1',
        display: 'INSPECTOR Tester',
      });
    });

    it('falls back to the employee code when the account has no display name', async () => {
      // A handset left face-up on a desk should still say who is holding it.
      const res = await call(StaffRole.INSPECTOR, {
        user: { displayName: null, phone: INSPECTOR_PHONE },
      }).expect(200);
      expect(res.body.staff.display).toBe('EMP-INSPECTOR');
    });

    it('falls back to the phone number when it has neither', async () => {
      const res = await call(StaffRole.INSPECTOR, {
        employeeCode: null,
        user: { displayName: null, phone: INSPECTOR_PHONE },
      }).expect(200);
      expect(res.body.staff.display).toBe(INSPECTOR_PHONE);
    });

    it('keeps the operator it is posted to rather than widening it', async () => {
      const res = await call(StaffRole.INSPECTOR, { operatorId: 'opt_9' }).expect(
        200,
      );
      expect(res.body.staff.operatorId).toBe('opt_9');
      expect(res.body.permissions.cityWide).toBe(false);
    });
  });

  describe('roles the scanner must refuse', () => {
    it('tells a DRIVER it may not validate', async () => {
      db.staff.findUnique.mockResolvedValue(
        staffRowFor(StaffRole.DRIVER, DRIVER_PHONE),
      );
      const res = await call(StaffRole.DRIVER).expect(200);
      expect(res.body.permissions.canValidate).toBe(false);
    });

    it('still lets a DRIVER ask who they are', async () => {
      // Refusing the scanner is not the same as refusing the app. A driver with
      // no scanner is a real situation and must not be locked out of sign-in.
      const res = await call(StaffRole.DRIVER).expect(200);
      expect(res.body.staff.role).toBe(StaffRole.DRIVER);
      expect(res.body.staff.display).toBe('DRIVER Tester');
    });

    it('grants every role on the shared scan list', async () => {
      for (const role of SCAN_ROLES) {
        const res = await call(role).expect(200);
        expect(res.body.permissions.canValidate).toBe(true);
      }
    });

    it('excludes DRIVER from the scan list', async () => {
      // Asserted against the list itself, not just the response, so the
      // invariant is recorded where a future edit to SCAN_ROLES will trip it.
      expect(SCAN_ROLES).not.toContain(StaffRole.DRIVER);
    });

    it('agrees with the response for every role in the enum', async () => {
      // The app trusts `canValidate` and keeps no list of its own. This is the
      // test that makes that trust safe: response and policy cannot disagree.
      for (const role of Object.values(StaffRole)) {
        const res = await call(role).expect(200);
        expect(res.body.permissions.canValidate).toBe(SCAN_ROLES.includes(role));
      }
    });
  });

  describe('administrative roles keep both capabilities', () => {
    it('tells a SUPER_ADMIN it may validate and manage', async () => {
      const res = await call(StaffRole.SUPER_ADMIN).expect(200);
      expect(res.body.permissions.canValidate).toBe(true);
      expect(res.body.permissions.canManage).toBe(true);
      expect(res.body.permissions.cityWide).toBe(true);
    });

    it('scopes an OPERATOR_ADMIN to its own operator', async () => {
      const res = await call(StaffRole.OPERATOR_ADMIN, { operatorId: 'opt_3' }).expect(
        200,
      );
      expect(res.body.permissions.canManage).toBe(true);
      expect(res.body.permissions.cityWide).toBe(false);
      expect(res.body.staff.operatorId).toBe('opt_3');
    });

    it('gives a FINANCE officer no scanner, since they never stand at a door', async () => {
      const res = await call(StaffRole.FINANCE).expect(200);
      expect(res.body.permissions.canValidate).toBe(false);
      expect(res.body.permissions.cityWide).toBe(true);
    });
  });

  describe('dashboard access stays restricted', () => {
    it('keeps every field role off DASHBOARD_ROLES', () => {
      // This route exists precisely because these roles cannot use
      // `GET /dashboard/session`. Widening DASHBOARD_ROLES to fix a handheld
      // sign-in would hand every field officer the whole network's revenue.
      for (const role of [
        StaffRole.DRIVER,
        StaffRole.CONDUCTOR,
        StaffRole.INSPECTOR,
        StaffRole.TICKET_OFFICER,
        StaffRole.AGENT,
      ]) {
        expect(DASHBOARD_ROLES).not.toContain(role);
      }
    });

    it('leaves the two role lists genuinely different', () => {
      // SCAN_ROLES is a superset of the field roles and DASHBOARD_ROLES shares
      // no field role with it. If these ever converged, one of the two lists
      // would be redundant and the separation would have quietly been undone.
      expect(SCAN_ROLES).not.toEqual(DASHBOARD_ROLES);
      expect(SCAN_ROLES.length).toBeGreaterThan(DASHBOARD_ROLES.length);
    });
  });

  describe('declared capabilities', () => {
    /**
     * The capability matrix, written out longhand.
     *
     * Deliberately not generated from the role lists: a test that recomputes the
     * expected answer with the same `includes(role)` calls as the implementation
     * cannot fail when the implementation is wrong. This table is the independent
     * statement of who may do what, so a role quietly added to a list surfaces as
     * a failure here instead of passing unnoticed.
     */
    const MATRIX: Array<[StaffRole, string[]]> = [
      [StaffRole.INSPECTOR, ['canScan']],
      [StaffRole.DRIVER, ['canOperateTrips', 'canManageShift']],
      [
        StaffRole.CONDUCTOR,
        ['canScan', 'canOperateTrips', 'canManageShift'],
      ],
      [StaffRole.AGENT, ['canScan', 'canManageShift']],
      [StaffRole.TICKET_OFFICER, ['canScan', 'canManageShift']],
      [
        StaffRole.SUPERVISOR,
        [
          'canScan',
          'canOperateTrips',
          'canManageShift',
          'canReconcile',
          'canHandleComplaints',
          'canViewReports',
        ],
      ],
      [
        StaffRole.OPERATOR_ADMIN,
        [
          'canScan',
          'canOperateTrips',
          'canManageShift',
          'canReconcile',
          'canHandleComplaints',
          'canViewReports',
          'canManageNetwork',
          // Deliberately neither canAuthorFares nor canApproveFares. Fare drafting
          // belongs to the bureau and finance, and sign-off to the bureau, finance
          // and auditor. An operator administers their own fleet — stops, vehicles,
          // routes — and does not set the price of the network's travel.
        ],
      ],
      [
        StaffRole.FINANCE,
        [
          'canReconcile',
          // Deliberately NOT canHandleComplaints: ASSURANCE_ROLES is the supervisory
          // and audit chain. Finance reconciles the money, and the complaint queue
          // is where passenger-facing disputes are argued — a different job.
          'canViewReports',
          'canViewFinance',
          'canAuthorFares',
          'canApproveFares',
          'cityWide',
        ],
      ],
      [
        StaffRole.AUDITOR,
        [
          'canHandleComplaints',
          'canViewReports',
          'canViewFinance',
          'canApproveFares',
          'cityWide',
        ],
      ],
      [
        StaffRole.TRANSPORT_BUREAU_ADMIN,
        [
          'canScan',
          'canOperateTrips',
          'canManageShift',
          'canReconcile',
          'canHandleComplaints',
          'canViewReports',
          'canViewFinance',
          'canViewDatabase',
          'canManageNetwork',
          'canAuthorFares',
          'canApproveFares',
          'canManageStaff',
          'cityWide',
        ],
      ],
      [
        StaffRole.SUPER_ADMIN,
        [
          'canScan',
          'canOperateTrips',
          'canManageShift',
          'canReconcile',
          'canHandleComplaints',
          'canViewReports',
          'canViewFinance',
          'canViewDatabase',
          'canManageNetwork',
          'canAuthorFares',
          'canApproveFares',
          'canManageStaff',
          'cityWide',
        ],
      ],
    ];

    /** Every key `capabilitiesFor` always emits, whether granted or not. */
    const ALL_CAPABILITIES = [
      'canApproveFares',
      'canAuthorFares',
      'canHandleComplaints',
      'canManageNetwork',
      'canManageShift',
      'canManageStaff',
      'canOperateTrips',
      'canReconcile',
      'canScan',
      'canViewDatabase',
      'canViewFinance',
      'canViewReports',
      'cityWide',
    ];

    it('covers every role the schema defines', () => {
      // If a new role is added and nobody decides what it may do, it silently
      // inherits "nothing". Better to fail here.
      expect(MATRIX.map(([role]) => role).sort()).toEqual(
        Object.values(StaffRole).sort(),
      );
    });

    it.each(MATRIX)(
      'declares exactly the expected capabilities for %s',
      async (role, granted) => {
        const res = await call(role).expect(200);
        const caps = res.body.capabilities as Record<string, boolean>;

        // Every capability is always present, true or false. The client must never
        // have to distinguish "not permitted" from "this server did not tell me",
        // because the first thing it does with a missing key is decide whether to
        // show a button — and a silently absent capability reads as a bug report
        // rather than as a denial.
        expect(Object.keys(caps).sort()).toEqual(ALL_CAPABILITIES);

        const expected = new Set(granted);
        for (const key of ALL_CAPABILITIES) {
          expect([role, key, caps[key]]).toEqual([
            role,
            key,
            expected.has(key),
          ]);
        }
      },
    );

    it('agrees with the legacy permissions block', async () => {
      // The handheld previously read only `permissions`. The two answers must not
      // disagree, or a client still on the old field would offer a scan the new
      // field refuses.
      for (const role of Object.values(StaffRole)) {
        const res = await call(role).expect(200);
        expect([role, res.body.capabilities.canScan]).toEqual([
          role,
          res.body.permissions.canValidate,
        ]);
        expect([role, res.body.capabilities.canManageNetwork]).toEqual([
          role,
          res.body.permissions.canManage,
        ]);
        expect([role, res.body.capabilities.cityWide]).toEqual([
          role,
          res.body.permissions.cityWide,
        ]);
      }
    });

    it('reports city-wide scope for the bureau and finance roles', async () => {
      // Annotated as StaffRole[] because a plain literal infers a narrow union,
      // and `Object.values(StaffRole)` is wider than any of them.
      const cityWide: StaffRole[] = [
        StaffRole.SUPER_ADMIN,
        StaffRole.TRANSPORT_BUREAU_ADMIN,
        StaffRole.FINANCE,
        StaffRole.AUDITOR,
      ];
      for (const role of Object.values(StaffRole)) {
        const res = await call(role).expect(200);
        expect([role, res.body.capabilities.cityWide]).toEqual([
          role,
          cityWide.includes(role),
        ]);
      }
    });

    it('lets an auditor approve fares without being able to author them', async () => {
      // The asymmetry is deliberate, and is the reason these are two flags rather
      // than a single `canManageFares`.
      const res = await call(StaffRole.AUDITOR).expect(200);
      expect(res.body.capabilities.canApproveFares).toBe(true);
      expect(res.body.capabilities.canAuthorFares).toBe(false);
    });

    it('keeps a driver off reporting entirely', async () => {
      const res = await call(StaffRole.DRIVER).expect(200);
      expect(res.body.capabilities.canViewReports).toBe(false);
      expect(res.body.capabilities.canViewFinance).toBe(false);
      expect(res.body.capabilities.canHandleComplaints).toBe(false);
    });

    it('keeps staff management narrower than network administration', async () => {
      // An operator admin edits stops and vehicles but cannot mint a supervisor.
      const res = await call(StaffRole.OPERATOR_ADMIN).expect(200);
      expect(res.body.capabilities.canManageNetwork).toBe(true);
      expect(res.body.capabilities.canManageStaff).toBe(false);
    });
  });
});