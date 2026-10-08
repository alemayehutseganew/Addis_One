import {
  CanActivate,
  ExecutionContext,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

/**
 * Gates the temporary fixed-credential test login (`POST /auth/password-login`).
 *
 * This route exists ONLY until the telecom operator approves SMS delivery.
 * It answers 404 unless `TEST_LOGIN_ENABLED=true`, so a deployment with the
 * flag off is indistinguishable from one where the route was never written —
 * same hiding strategy as {@link DevLoginGuard}.
 *
 * Unlike DEV_STAFF_LOGIN this flag is ALLOWED in production: that is the whole
 * point (field-test the production build without SMS). The flag, the fixed
 * usernames, and this guard must all be deleted once OTP delivery is live.
 */
@Injectable()
export class TestLoginGuard implements CanActivate {
  constructor(private readonly config: ConfigService) {}

  canActivate(_context: ExecutionContext): boolean {
    const enabled =
      this.config.get<string>('TEST_LOGIN_ENABLED', 'false') === 'true';
    if (!enabled) {
      throw new NotFoundException();
    }
    return true;
  }
}
