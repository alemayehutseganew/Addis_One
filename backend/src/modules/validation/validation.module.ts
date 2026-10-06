/**
 * Ticket validation wiring.
 *
 * Imports PaymentsModule solely for the exported CredentialSigner: verification
 * needs the public half of the same key that issues tickets. This is the one
 * legitimate dependency between the two modules, and it is deliberately narrow —
 * validation depends on ticketing's key, never on its tables or its issuance
 * service.
 *
 * AuthModule is imported because Nest resolves a guard's dependencies in the
 * module that provides it; referencing StaffGuard on the controller is not
 * enough on its own.
 */

import { Module } from '@nestjs/common';
import { PrismaModule } from '../../prisma/prisma.module';
import { AuthModule } from '../auth/auth.module';
import { PaymentsModule } from '../payments/payments.module';
import { ValidationController } from './validation.controller';
import { ValidationService } from './validation.service';

@Module({
  imports: [PrismaModule, AuthModule, PaymentsModule],
  controllers: [ValidationController],
  providers: [ValidationService],
  exports: [ValidationService],
})
export class ValidationModule {}