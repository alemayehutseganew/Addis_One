/**
 * Payment endpoints — the wire boundary for I1 and I2.
 *
 * The fare is RE-DERIVED here rather than trusted from the client. A passenger
 * could otherwise POST `amountFils: 1` for a 44-birr ride; the provider would
 * happily charge one cent. The client-sent amount is treated as a claim to be
 * checked, never as the price.
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

class CreatePaymentDto {
  @IsUUID()
  journeyId!: string;

  @IsInt()
  @Min(1)
  amountFils!: number;

  @IsEnum(['TELEBIRR', 'CBE_BIRR', 'BANK', 'CASH', 'AGENT_CREDIT', 'USSD', 'WALLET'])
  method!: 'TELEBIRR' | 'CBE_BIRR' | 'BANK' | 'CASH' | 'AGENT_CREDIT' | 'USSD' | 'WALLET';

  /**
   * REQUIRED. Generated once by the app before the first attempt and reused on
   * every retry of the SAME purchase, so a dropped response cannot double-charge.
   * A new purchase gets a new key — reusing one across purchases would return
   * the first ticket forever.
   */
  @IsString()
  idempotencyKey!: string;

  @IsOptional()
  @IsString()
  payerPhone?: string;
}

@Controller('payments')
@UseGuards(JwtAuthGuard)
export class PaymentsController {
  constructor(
    private readonly payments: PaymentsService,
    private readonly prisma: PrismaService,
  ) {}

  /**
   * Creates (or replays) a payment, runs it through the provider, and issues a
   * ticket only if the provider CONFIRMED.
   *
   * Note the response shape: it never claims a ticket exists. The client must
   * read `ticket` from this response or follow up to `/payments/:id/ticket`.
   */
  @Post()
  async create(@Body() dto: CreatePaymentDto, @Req() req: any) {
    const result = await this.payments.purchase({
      userId: req.user.id as string,
      journeyId: dto.journeyId,
      claimedAmountFils: dto.amountFils,
      method: dto.method,
      idempotencyKey: dto.idempotencyKey,
      payerPhone: dto.payerPhone,
    });
    return result;
  }

  @Get(':id')
  async status(@Param('id', ParseUUIDPipe) id: string, @Req() req: any) {
    const payment = await this.prisma.payment.findUnique({ where: { id } });
    if (!payment) throw new HttpException('Payment not found', 404);

    // A payment belonging to someone else is reported as missing rather than
    // forbidden: confirming it exists leaks another passenger's activity.
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
    };
  }

  /**
   * The ticket for a payment, once one has been issued.
   *
   * 409 while the payment is unconfirmed and 404 before issuance — the client
   * polls this after a redirect and must be able to tell "keep waiting" from
   * "this will never arrive".
   */
  @Get(':id/ticket')
  async ticket(@Param('id', ParseUUIDPipe) id: string, @Req() req: any) {
    return this.payments.ticketForPayment(id, req.user.id as string);
  }
}

/**
 * The signed-in passenger's own tickets.
 *
 * Separate from the payments controller because this is a ticketing concern, and
 * a passenger's ticket history outlives any single payment. Scope is enforced by
 * the authenticated user id — never a query parameter — so one passenger can
 * never list another's tickets.
 */
@Controller('tickets')
@UseGuards(JwtAuthGuard)
export class TicketsController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly issuance: TicketIssuanceService,
  ) {}

  @Get('mine')
  async mine(@Req() req: any) {
    const tickets = await this.prisma.ticket.findMany({
      where: { userId: req.user.id },
      orderBy: { issuedAt: 'desc' },
      take: 50,
      include: { credential: true },
    });

    return {
      tickets: tickets.map((t) => ({
        id: t.id,
        reference: t.reference,
        status: t.status,
        mode: t.mode,
        issuedAt: t.issuedAt,
        expiresAt: t.credential?.expiresAt ?? t.expiresAt,
        fareRuleVersion: t.fareRuleVersion,
        // The QR is re-derived from stored columns, never re-signed: a fresh
        // signature would carry a new nonce, invalidating any screenshot the
        // passenger already has and looking like a replay to a validator.
        qrString: t.credential
          ? this.issuance.buildQrString(t.credential)
          : null,
      })),
    };
  }
}
