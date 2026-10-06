import 'package:equatable/equatable.dart';

import '../../../../core/models/ticket.dart';
import '../domain/transport_repository.dart';

/// State of a ticket purchase.
///
/// Modelled as an explicit union rather than a bag of nullable fields, so an
/// impossible combination (say, `ticket != null && payment == null`) cannot be
/// represented. The states also make the I1 boundary visible in the type system:
/// only [PurchaseSuccess] carries a ticket.
sealed class PurchaseState extends Equatable {
  const PurchaseState();

  bool get isBusy =>
      this is PurchaseCreatingPayment ||
      this is PurchaseAwaitingPayment ||
      this is PurchaseAwaitingTicket;

  @override
  List<Object?> get props => [];
}

/// Nothing started yet.
class PurchaseIdle extends PurchaseState {
  const PurchaseIdle();
}

/// Creating the payment record. No money has moved.
class PurchaseCreatingPayment extends PurchaseState {
  const PurchaseCreatingPayment();
}

/// Payment started; waiting for the provider to settle it.
///
/// This state is the whole point of I1 on the client: the passenger may have
/// been redirected to Telebirr, but nothing here may be treated as paid.
class PurchaseAwaitingPayment extends PurchaseState {
  const PurchaseAwaitingPayment({
    required this.paymentId,
    required this.reference,
    this.status = PaymentStatus.requiresAction,
    this.redirectUrl,
  });

  final String paymentId;
  final String reference;
  final PaymentStatus status;
  final String? redirectUrl;

  @override
  List<Object?> get props => [paymentId, reference, status, redirectUrl];
}

/// Payment confirmed; waiting for the backend to issue and sign the ticket.
///
/// Issuing is asynchronous on purpose — it happens in the same transaction as
/// the confirmation. Polling here is correct; assuming it succeeded is not.
class PurchaseAwaitingTicket extends PurchaseState {
  const PurchaseAwaitingTicket(this.paymentId, this.reference);

  final String paymentId;
  final String reference;

  @override
  List<Object?> get props => [paymentId, reference];
}

/// A ticket exists and is confirmed by the backend.
class PurchaseSuccess extends PurchaseState {
  const PurchaseSuccess(this.ticket);

  final IssuedTicket ticket;

  @override
  List<Object?> get props => [ticket];
}

/// The payment failed or was not completed.
class PurchaseFailure extends PurchaseState {
  const PurchaseFailure(this.failure, {this.message});

  final ApiFailure failure;
  final String? message;

  @override
  List<Object?> get props => [failure, message];
}
