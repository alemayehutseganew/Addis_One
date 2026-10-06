/**
 * Payments wiring.
 *
 * The Ed25519 signing key is loaded from disk at boot. In production it would be
 * injected from a secret manager or KMS — a private key committed to a repo or
 * baked into a container image is recoverable forever once leaked, and anyone
 * holding it can mint tickets that pass every validator.
 *
 * The provider registry currently holds the MOCK adapter only. Adding Telebirr
 * or CBE Birr is a registration, not a change to the fare or ticket flow.
 */

import { Module, Logger } from '@nestjs/common';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createPrivateKey } from 'node:crypto';
import { PrismaModule } from '../../prisma/prisma.module';
import { AuthModule } from '../auth/auth.module';
import { TicketIssuanceService } from '../ticketing/ticket-issuance.service';
import { CredentialSigner } from '../ticketing/credential-signer';
import { CashPaymentAdapter, MockPaymentAdapter } from './mock-payment-adapter';
import { PaymentOrchestratorService } from './payment-orchestrator';
import { PaymentsController, TicketsController } from './payments.controller';
import { VehiclePaymentsController } from './vehicle-payments.controller';
import { PrismaPaymentRepository } from './prisma-payment.repository';
import { PaymentsService } from './payments.service';
import { ProviderRegistry } from './payment-provider';

// Resolved from process.cwd() rather than __dirname.
//
// The compiled file lives at backend/dist/modules/payments/, so walking up from
// __dirname lands on backend/ only for some module depths and one level too high
// for others — a subtle, build-layout-dependent bug. The server is started with
// cwd = backend/ (see start-backend.ps1), so this is unambiguous.
//
// Overridable for deployments that mount the key elsewhere.
const KEY_PATH =
  process.env.TICKET_SIGNING_KEY_PATH ??
  join(process.cwd(), 'keys', 'ticket-signing-key.pem');
const KEY_ID = process.env.TICKET_SIGNING_KEY_ID ?? 'addis-one-2026-01';

@Module({
  imports: [
    PrismaModule,
    // JwtAuthGuard is exported by AuthModule. Nest resolves a guard's
    // dependencies in the module that *provides* it, so PaymentsModule must
    // import AuthModule — otherwise the guard cannot be constructed here even
    // though it appears to be a plain class reference on the controller.
    AuthModule,
  ],
  controllers: [PaymentsController, TicketsController, VehiclePaymentsController],
  providers: [
    PrismaPaymentRepository,
    PaymentsService,
    TicketIssuanceService,
    {
      provide: CredentialSigner,
      useFactory: (): CredentialSigner => {
        if (!existsSync(KEY_PATH)) {
          throw new Error(
            `Ticket signing key missing at ${KEY_PATH}. ` +
              'Run scripts/make-signing-key.ps1 before starting the server — ' +
              'issuing tickets without a signing key is not possible by design.',
          );
        }
        // Parsed here, at boot, rather than lazily on the first purchase. A
        // malformed key otherwise surfaces as an OpenSSL "DECODER routines::
        // unsupported" error in the middle of a paying passenger's checkout,
        // which looks like a payment bug and is not one.
        const pem = readFileSync(KEY_PATH, 'utf8');
        let signer: CredentialSigner;
        try {
          signer = new CredentialSigner(pem, KEY_ID);
          // Force key parsing now rather than at first use.
          createPrivateKey(pem);
        } catch (err) {
          throw new Error(
            `Ticket signing key at ${KEY_PATH} could not be parsed as an ` +
              `Ed25519 private key: ${(err as Error).message}`,
          );
        }

        new Logger('CredentialSigner').log(
          `Loaded ticket signing key ${KEY_ID} from ${KEY_PATH}`,
        );
        return signer;
      },
    },
    {
      provide: ProviderRegistry,
      useFactory: (): ProviderRegistry => {
        const registry = new ProviderRegistry();
        // MOCK ONLY. No real Telebirr/CBE credentials are configured, so every
        // payment is simulated. Responses carry providerMode: "MOCK" so a test
        // deployment can never be mistaken for a live payment system.
        registry.register(new MockPaymentAdapter());
        // CASH needs its own adapter even in development. CashPaymentAdapter has
        // existed all along in mock-payment-adapter.ts, but was never registered,
        // so every assisted sale failed with "No payment adapter registered for
        // CASH" — an agent route that typechecks, compiles and 500s on first use.
        // It settles immediately because the money is already in the officer's
        // hand; there is nothing to wait for, which is precisely why cash is a
        // provider like any other rather than a special case bypassed upstream.
        registry.register(new CashPaymentAdapter());
        return registry;
      },
    },
    {
      provide: PaymentOrchestratorService,
      // `inject` is required: Nest cannot read parameter types off an arrow
      // function (TypeScript only emits design:paramtypes for decorated
      // classes), so without this the factory silently receives undefined and
      // every payment fails with "cannot read findByIdempotencyKey of undefined".
      inject: [PrismaPaymentRepository, ProviderRegistry],
      useFactory: (
        repo: PrismaPaymentRepository,
        registry: ProviderRegistry,
      ): PaymentOrchestratorService =>
        new PaymentOrchestratorService(repo, registry),
    },
  ],
  // CredentialSigner is exported so the validation module can verify against the
  // public half of this same key. Re-deriving it there would mean two places
  // reading the signing key from disk, and the two could disagree about which key
  // is authoritative - which is how tickets get issued that no validator accepts.
  exports: [PaymentsService, TicketIssuanceService, CredentialSigner],
})
export class PaymentsModule {}
