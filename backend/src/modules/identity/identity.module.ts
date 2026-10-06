/**
 * Staff identity wiring — shifts and device enrolment.
 *
 * AuthModule is imported because Nest resolves a guard's dependencies in the
 * module that provides it; naming StaffGuard on the controller is not enough on
 * its own.
 */

import { Module } from '@nestjs/common';
import { PrismaModule } from '../../prisma/prisma.module';
import { AuthModule } from '../auth/auth.module';
import { PaymentsModule } from '../payments/payments.module';
// Supplies the exported JourneyPlannerService, so an agent sale is priced by the
// same planner and the same persisted FareCalculation a passenger sale is.
import { JourneysModule } from '../journeys/journeys.module';
import { IdentityController } from './identity.controller';
import { IdentityService } from './identity.service';

@Module({
  // PaymentsModule is imported solely for the exported PaymentsService, which
  // backs the cash-sale route. Routing the sale through the same orchestrator a
  // mobile payment uses is the whole point: a ticket officer's cash must produce
  // identical core records, or it is revenue with no audit trail.
  imports: [PrismaModule, AuthModule, PaymentsModule, JourneysModule],
  controllers: [IdentityController],
  providers: [IdentityService],
  exports: [IdentityService],
})
export class IdentityModule {}