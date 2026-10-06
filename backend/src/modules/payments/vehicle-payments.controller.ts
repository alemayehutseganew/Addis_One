/**
 * Vehicle-code payment endpoints — the wire boundary for vehicle QR tickets.
 *
 * Mirrors /payments but validates against a vehicle profile instead of a
 * planned journey. The fare is RE-DERIVED here rather than trusted from the
 * client: a passenger could otherwise POST amountFils: 1 for a 44-birr ride.
 *
 * Only CONFIRMED payments unlock issuance (I1). The client must poll
 * /vehicle-payments/:id/tickets after a redirect and must be able to tell
 * "keep waiting" from "this will never arrive".
 */

import {
  Body,
  Controller,
  Get,
  HttpException,
  Param,
  ParseUUIDPipe,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import { IsEnum, IsInt, IsOptional, IsString, IsUUID, Min } from 'class-validator';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { PrismaService } from '../../prisma/prisma.service';
import { TicketIssuanceService } from '../ticketing/ticket-issuance.service';
import { PaymentsService } from './payments.service';

class CreateVehiclePaymentDto {
  @IsUUID()
  vehicleId!: string;

  @IsInt()
  @Min(1)
  amountFils!: number;

  @IsInt()
  @Min(1)
  quantity!: number;

  @IsEnum(['TELEBIRR', 'CBE_BIRR', 'BANK', 'CASH', 'AGENT_CREDIT', 'USSD', 'WALLET'])
  method!: 'TELEBIRR' | 'CBE_BIRR' | 'BANK' | 'CASH' | 'AGENT_CREDIT' | 'USSD' | 'WALLET';

  /**
   * REQUIRED. Generated once by the app before the first attempt and reused on
   * every retry of the SAME purchase, so a dropped response cannot double-charge.
   * A new purchase gets a new key — reusing one across purchases would return
   * the first tickets forever.
   */
  @IsString()
  idempotencyKey!: string;

  @IsOptional()
  @IsString()
  payerPhone?: string;

  @IsOptional()
  @IsUUID()
  tripId?: string;
}

@Controller('vehicle-payments')
@UseGuards(JwtAuthGuard)
export class VehiclePaymentsController {
  constructor(
    private readonly payments: PaymentsService,
    private readonly prisma: PrismaService,
    private readonly issuance: TicketIssuanceService,
  ) {}

  /**
   * Creates (or replays) a vehicle payment, runs it through the provider, and
   * issues tickets only if the provider CONFIRMED.
   *
   * Note the response shape: it returns a list of tickets when issued. The
   * client must read `tickets` from this response or follow up to
   * /vehicle-payments/:id/tickets.
   */
  @Post()
  async create(@Body() dto: CreateVehiclePaymentDto, @Req() req: any) {
    const vehicle = await this.prisma.vehicle.findUnique({
      where: { id: dto.vehicleId },
      include: { operator: true },
    });
    if (!vehicle) throw new HttpException('Vehicle not found', 404);

    // Re-derive the fare server-side — the client's amount is a claim.
    if (vehicle.fareFils === undefined || vehicle.fareFils === null || vehicle.fareFils <= 0) {
      throw new HttpException('No fare published for this vehicle', 409);
    }

    const expectedTotalFils = vehicle.fareFils * dto.quantity;
    if (expectedTotalFils !== dto.amountFils) {
      throw new HttpException(
        { message: 'Amount does not match vehicle fare × quantity', code: 'FARE_MISMATCH' },
        409,
      );
    }

    const result = await this.payments.purchaseVehicle({
      userId: req.user.id as string,
      journeyId: dto.tripId ?? null,
      claimedAmountFils: dto.amountFils,
      method: dto.method,
      idempotencyKey: dto.idempotencyKey,
      payerPhone: dto.payerPhone,
      collectedByStaffId: null,
      shiftId: null,
      vehicleId: dto.vehicleId,
      quantity: dto.quantity,
    });

    return result;
  }

  @Get(':id')
  async status(@Param('id', ParseUUIDPipe) id: string, @Req() req: any) {
    const payment = await this.prisma.payment.findUnique({ where: { id } });
    if (!payment) throw new HttpException('Payment not found', 404);

    if (payment.userId !== req.user.id) {
      throw new HttpException('Payment not found', 404);
    }

    return {
      id: payment.id,
      reference: payment.reference,
      status: payment.status,
      amountFils: payment.amountFils,
      currency: payment.currency,
      method: payment.method,
      providerMode: 'MOCK',
      confirmedAt: payment.confirmedAt,
      vehicleId: payment.vehicleId ?? null,
      tripId: payment.tripId ?? null,
      quantity: payment.quantity ?? 1,
    };
  }

  /**
   * The tickets for a vehicle payment, once they have been issued.
   *
   * 409 while the payment is unconfirmed and 404 before issuance — the client
   * polls this after a redirect and must be able to tell "keep waiting" from
   * "this will never arrive".
   */
  @Get(':id/tickets')
  async tickets(@Param('id', ParseUUIDPipe) id: string, @Req() req: any) {
    const payment = await this.prisma.payment.findUnique({ where: { id } });
    if (!payment || payment.userId !== req.user.id) {
      throw new HttpException('Payment not found', 404);
    }
    if (payment.status !== 'CONFIRMED') {
      throw new HttpException('Payment is not confirmed', 409);
    }

    const tickets = await this.prisma.ticket.findMany({
      where: { paymentId: payment.id },
      include: { credential: true },
    });
    if (tickets.length === 0) throw new HttpException('Tickets not issued yet', 404);

    return {
      tickets: tickets.map((t) => ({
        ticketId: t.id,
        reference: t.reference,
        status: t.status,
        mode: t.mode,
        qrString: t.credential ? this.issuance.buildQrString(t.credential) : null,
        issuedAt: t.issuedAt,
        expiresAt: t.credential?.expiresAt ?? t.expiresAt,
        fareRuleVersion: t.fareRuleVersion,
      })),
    };
  }
}