import {
  CanActivate,
  ExecutionContext,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

/**
 * 404s the development sign-in route unless the bypass is armed.
 *
 * Applied with `@UseGuards` on the `/auth/dev-login` routes. AuthController
 * declares no class-level guards — each route attaches its own — so this guard is
 * the only thing standing between an anonymous caller and the bypass, which is the
 * intent: the route refuses unless the feature is deliberately switched on.
 *
 * Refusing with 404 rather than 403 is deliberate. A 403 would confirm the path
 * exists to anyone who guessed it, turning this into a discovery oracle on a
 * deployment that has the code but not the flag. A 404 is indistinguishable from a
 * route that was never written.
 *
 * The flag is read on every call rather than captured in the constructor. That is
 * not merely a style preference: Nest instantiates a guard named in `@UseGuards`
 * from its own class metadata, so every constructor parameter has to be an
 * injectable provider. A callback captured at construction is not injectable and
 * fails at boot with "Nest can't resolve dependencies of the DevLoginGuard". Taking
 * ConfigService — a real provider — is the only workable shape here, and reading
 * the flag per call also means the answer cannot drift from the server's live
 * configuration.
 */
@Injectable()
export class DevLoginGuard implements CanActivate {
  constructor(private readonly config: ConfigService) {}

  canActivate(_context: ExecutionContext): boolean {
    const nonProduction =
      this.config.get<string>('NODE_ENV', 'development') !== 'production';
    const armed = this.config.get<string>('DEV_STAFF_LOGIN', 'false') === 'true';

    if (!nonProduction || !armed) {
      throw new NotFoundException();
    }
    return true;
  }
}
