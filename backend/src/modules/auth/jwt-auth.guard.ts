import {
  CanActivate,
  ExecutionContext,
  Injectable,
  SetMetadata,
  UnauthorizedException,
  createParamDecorator,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { PrismaService } from '../../prisma/prisma.service';
import { TokenService } from './token.service';

export const IS_PUBLIC_KEY = 'addis:public';

/**
 * Marks a route as reachable without signing in.
 *
 * Browsing the network and seeing a fare must not require an account: a
 * passenger standing at a stop decides whether to install an app based on
 * whether it tells them the price, not on whether they register first. Only
 * payment and anything touching a passenger's own records need identity.
 */
export const Public = () => SetMetadata(IS_PUBLIC_KEY, true);

export interface AuthenticatedUser {
  id: string;
  phone: string;
  displayName: string | null;
}

/**
 * JWT guard.
 *
 * Implemented directly rather than through Passport: there is exactly one token
 * scheme, so an indirection layer would add a second code path to keep in sync
 * without buying anything.
 *
 * Beyond checking the signature it loads the current user from the database
 * rather than trusting the token body. A token stays cryptographically valid
 * for its full lifetime even if the account is suspended, so suspension has to
 * be judged against live state.
 */
@Injectable()
export class JwtAuthGuard implements CanActivate {
  constructor(
    private readonly prisma: PrismaService,
    private readonly tokens: TokenService,
    private readonly reflector: Reflector,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);

    const request = context.switchToHttp().getRequest();
    const token = this.extractToken(request);

    if (!token) {
      // On a public route an absent token is simply "not signed in". Callers read
      // `req.user` as optional, which is what lets planning work for an
      // anonymous passenger and still attach a journey to a signed-in one.
      if (isPublic) return true;
      throw new UnauthorizedException('Missing bearer token');
    }

    try {
      // verifyAccess raises a single generic message for every failure mode, so
      // an attacker cannot tell an expired token from a forged one.
      const payload = await this.tokens.verifyAccess(token);

      const user = await this.prisma.user.findUnique({
        where: { id: payload.sub },
        select: { id: true, phone: true, displayName: true, status: true },
      });

      if (!user || user.status === 'SUSPENDED' || user.status === 'CLOSED') {
        throw new UnauthorizedException('Account is not active');
      }

      request.user = {
        id: user.id,
        phone: user.phone,
        displayName: user.displayName,
      } satisfies AuthenticatedUser;
    } catch (error) {
      // A stale token must not break browsing. It only means "sign in again" if
      // the route actually needed identity; otherwise the request continues
      // anonymously, and the client can refresh or sign in when it matters.
      if (isPublic) return true;
      throw error;
    }

    return true;
  }

  private extractToken(request: {
    headers: Record<string, string | undefined>;
  }): string | null {
    const header = request.headers.authorization;
    if (!header) return null;
    const [scheme, value] = header.split(' ');
    return scheme === 'Bearer' && value ? value : null;
  }
}

/**
 * Injects the authenticated user into a handler parameter.
 *
 * Returns undefined on a public route when nobody is signed in, so handlers must
 * treat it as optional rather than dereferencing it blindly.
 */
export const CurrentUser = createParamDecorator(
  (_data: unknown, context: ExecutionContext): AuthenticatedUser | undefined => {
    return context.switchToHttp().getRequest().user;
  },
);

