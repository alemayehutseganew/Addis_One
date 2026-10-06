import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { HealthController } from './health.controller';
import { AdminModule } from './modules/admin/admin.module';
import { AssuranceModule } from './modules/assurance/assurance.module';
import { AuthModule } from './modules/auth/auth.module';
import { DashboardModule } from './modules/dashboard/dashboard.module';
import { IdentityModule } from './modules/identity/identity.module';
import { JourneysModule } from './modules/journeys/journeys.module';
import { MobilityModule } from './modules/mobility/mobility.module';
import { PaymentsModule } from './modules/payments/payments.module';
import { ValidationModule } from './modules/validation/validation.module';
import { VehiclesModule } from './modules/vehicles/vehicles.module';
import { PrismaModule } from './prisma/prisma.module';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      // .env holds DATABASE_URL, which Prisma CLI also reads directly.
      envFilePath: ['.env'],
    }),
    PrismaModule,
    AuthModule,
    AdminModule,
    AssuranceModule,
    DashboardModule,
    IdentityModule,
    JourneysModule,
    MobilityModule,
    PaymentsModule,
    ValidationModule,
    VehiclesModule,
  ],
  controllers: [HealthController],
})
export class AppModule {}
