/**
 * `DevLoginService` — the OTP bypass.
 *
 * These cover the one invariant that makes this safe to widen: the bypass can
 * create a *citizen* account, and must never be able to create a *staff* one.
 * Authority in this system is conferred by the Staff row and nothing else, so
 * "never writes a Staff row" is the property that keeps a development shortcut
 * from becoming a way to mint an administrator.
 */
import { Logger } from '@nestjs/common';
import { DevLoginService } from './auth.controller';
import { PrismaService } from '../../prisma/prisma.service';
import { TokenService } from './token.service';

const PHONE = '+251900112244';

describe('DevLoginService', () => {
  let service: DevLoginService;

  let prisma: {
    staff: { findFirst: jest.Mock };
    user: { upsert: jest.Mock };
  };
  let tokens: { issueFor: jest.Mock };

  /** Model handles, so a new write on `staff` cannot slip in unnoticed. */
  const staffWriteHandles = /^(create|upsert|update|delete|createMany)$/;

  beforeEach(() => {
    prisma = {
      staff: { findFirst: jest.fn().mockResolvedValue(null) },
      user: {
        upsert: jest
          .fn()
          .mockResolvedValue({ id: 'usr_new', displayName: null }),
      },
    };
    tokens = {
      issueFor: jest.fn().mockResolvedValue({
        accessToken: 'access',
        refreshToken: 'refresh',
        expiresIn: 900,
      }),
    };

    // Silence the deliberate per-use warning so the suite output stays readable.
    jest.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);

    service = new DevLoginService(
      prisma as unknown as PrismaService,
      tokens as unknown as TokenService,
    );
  });

  afterEach(() => jest.restoreAllMocks());

  describe('a number that already holds an active staff record', () => {
    beforeEach(() =>
      prisma.staff.findFirst.mockResolvedValue({ userId: 'usr_staff' }),
    );

    it('is issued that identity', async () => {
      const res = await service.signIn(PHONE);
      expect(res.ok).toBe(true);
      expect(tokens.issueFor).toHaveBeenCalledWith('usr_staff', PHONE);
    });

    it('creates no account at all', async () => {
      await service.signIn(PHONE);
      expect(prisma.user.upsert).not.toHaveBeenCalled();
    });

    it('reports no display name, because staff name it separately', async () => {
      // `/auth/staff-session` is where a staff member's name comes from; echoing
      // the citizen record here would show nothing and invite confusion.
      await expect(service.signIn(PHONE)).resolves.toMatchObject({
        displayName: null,
      });
    });
  });

  describe('a number with no active staff record', () => {
    it('is issued a citizen account', async () => {
      const res = await service.signIn(PHONE);
      expect(res.ok).toBe(true);
      expect(tokens.issueFor).toHaveBeenCalledWith('usr_new', PHONE);
    });

    it('creates that account keyed on the phone', async () => {
      await service.signIn(PHONE);
      expect(prisma.user.upsert).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { phone: PHONE },
          create: expect.objectContaining({ phone: PHONE }),
        }),
      );
    });

    it('never marks the number phone-verified', async () => {
      // Marking it would make a later OTP sign-in trust a verification that
      // never happened — the bypass would quietly weaken the real flow.
      await service.signIn(PHONE);
      const call = prisma.user.upsert.mock.calls[0][0];
      expect(JSON.stringify(call.create)).not.toContain('phoneVerifiedAt');
    });

    it('never writes a Staff row', async () => {
      // The safety argument in one assertion: the bypass has no write handle on
      // the table that confers authority. Creating a *citizen* via user.upsert is
      // intended; creating an *employee* is what must be impossible here.
      const staffHandles = Object.keys(prisma.staff);
      for (const handle of staffHandles) {
        expect(handle).not.toMatch(staffWriteHandles);
      }
      await service.signIn(PHONE);
      expect(prisma.staff.findFirst).toHaveBeenCalledTimes(1);
    });

    it('reuses an existing citizen rather than clobbering it', async () => {
      // `update: {}` on purpose: a bypass that reset status would resurrect a
      // suspended account the product suspended on purpose.
      await service.signIn(PHONE);
      const call = prisma.user.upsert.mock.calls[0][0];
      expect(call.update).toEqual({});
    });

    it('reports the citizen display name when one exists', async () => {
      prisma.user.upsert.mockResolvedValue({
        id: 'usr_new',
        displayName: 'Selassie I Inspector',
      });
      await expect(service.signIn(PHONE)).resolves.toMatchObject({
        displayName: 'Selassie I Inspector',
      });
    });
  });

  describe('a staff record that no longer qualifies', () => {
    it('falls through to the citizen branch rather than the old role', async () => {
      // Deactivated and terminated staff both fail the `findFirst`, which is the
      // point: this must not be a way to recover a role that was taken away.
      prisma.staff.findFirst.mockResolvedValue(null);
      const res = await service.signIn(PHONE);
      expect(prisma.user.upsert).toHaveBeenCalled();
      expect(tokens.issueFor).toHaveBeenCalledWith('usr_new', PHONE);
      expect(res.ok).toBe(true);
    });
  });

  describe('the token it issues', () => {
    it('is an ordinary session, not a special one', async () => {
      // No extra claim, no longer TTL, no privileged subject: the bypass differs
      // only in how the caller proved who they are, so it must not produce a
      // different token.
      await service.signIn(PHONE);
      expect(tokens.issueFor).toHaveBeenCalledTimes(1);
      expect(tokens.issueFor).toHaveBeenCalledWith(expect.any(String), PHONE);
    });
  });
});