/**
 * Payment provider abstraction.
 *
 * The orchestrator talks only to this interface. Adding Telebirr, CBE Birr, or
 * a bank means writing an adapter and registering it — never editing the fare
 * or ticket flow. Provider-specific concepts must not leak past this boundary:
 * a caller of `PaymentProvider` cannot tell which provider it is talking to.
 *
 * I2 lives here: every method takes an idempotency key, and implementations are
 * required to make repeats safe. The database unique constraint is the real
 * guarantee (see architecture.md §5); this is the contract layered on top.
 */

export type PaymentMethodCode =
  | 'TELEBIRR'
  | 'CBE_BIRR'
  | 'BANK'
  | 'CASH'
  | 'AGENT_CREDIT'
  | 'USSD'
  | 'WALLET';

/** Mirrors `PaymentStatus` in the Prisma schema. */
export type PaymentStatusCode =
  | 'CREATED'
  | 'PENDING'
  | 'REQUIRES_ACTION'
  | 'AUTHORIZED'
  | 'CONFIRMED'
  | 'FAILED'
  | 'TIMEOUT'
  | 'REVERSED'
  | 'REFUNDED'
  | 'PARTIALLY_REFUNDED';

export interface InitiateRequest {
  /** Provider's own reference for this attempt. Unique per provider. */
  providerReference: string;
  amountFils: number;
  currency: string;
  /** Payer phone in E.164, e.g. +251911234567. */
  payerPhone: string;
  description: string;
  /**
   * Where the provider sends the user to complete payment, if applicable.
   * Null for providers that complete out-of-band (cash, agent, USSD).
   */
  returnUrl?: string | null;
  /** Passed through untouched to the provider for its own correlation. */
  metadata?: Record<string, string>;
}

export interface InitiateResult {
  status: PaymentStatusCode;
  providerReference: string;
  /** Where to send the payer next, when the provider requires a redirect. */
  redirectUrl?: string | null;
  /** Opaque handle for later status checks. */
  providerHandle?: string | null;
  raw?: Record<string, unknown>;
}

export interface CaptureRequest {
  providerReference: string;
  providerHandle?: string | null;
  amountFils: number;
  idempotencyKey: string;
}

export interface RefundRequest {
  providerReference: string;
  providerHandle?: string | null;
  amountFils: number;
  reason: string;
  idempotencyKey: string;
}

export interface ProviderStatusResult {
  status: PaymentStatusCode;
  providerReference: string;
  providerHandle?: string | null;
  /** True only when the provider has settled funds, not merely been contacted. */
  settled: boolean;
  raw?: Record<string, unknown>;
}

export interface PaymentProviderAdapter {
  readonly code: PaymentMethodCode;
  readonly displayName: string;
  /** Providers that settle without an online call cannot be polled. */
  readonly supportsPolling: boolean;

  initiate(req: InitiateRequest, idempotencyKey: string): Promise<InitiateResult>;
  capture(req: CaptureRequest): Promise<ProviderStatusResult>;
  refund(req: RefundRequest): Promise<ProviderStatusResult>;
  status(providerReference: string): Promise<ProviderStatusResult>;
  /** Optional: many providers have no reverse operation. */
  reverse?(providerReference: string, idempotencyKey: string): Promise<ProviderStatusResult>;
}

export class PaymentProviderError extends Error {
  constructor(
    readonly providerCode: string,
    message: string,
    readonly retryable = false,
  ) {
    super(message);
    this.name = 'PaymentProviderError';
  }
}

/**
 * Registry mapping provider codes to adapters.
 *
 * Provider availability is configuration (the `PaymentProvider` table), so a
 * provider can be disabled without a deploy.
 */
export class ProviderRegistry {
  constructor(
    private readonly adapters: Map<PaymentMethodCode, PaymentProviderAdapter> = new Map(),
  ) {}

  register(adapter: PaymentProviderAdapter): void {
    this.adapters.set(adapter.code, adapter);
  }

  get(code: PaymentMethodCode): PaymentProviderAdapter {
    const adapter = this.adapters.get(code);
    if (!adapter) {
      throw new PaymentProviderError(
        code,
        `No payment adapter registered for provider ${code}`,
      );
    }
    return adapter;
  }

  has(code: PaymentMethodCode): boolean {
    return this.adapters.has(code);
  }

  list(): PaymentProviderAdapter[] {
    return [...this.adapters.values()];
  }
}
