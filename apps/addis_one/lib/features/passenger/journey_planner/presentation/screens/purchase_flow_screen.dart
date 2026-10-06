import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/router.dart';
import '../../../../../app/theme.dart';
import '../../../../../core/localization.dart';
import '../../../../../core/models/journey.dart';
import '../../../../../core/models/journey_plan.dart';
import '../../../../../core/models/ticket.dart';
import '../../../../../core/money.dart';
import '../../domain/purchase_state.dart';
import '../../domain/transport_repository.dart';
import '../../../ticketing/presentation/screens/payment_and_ticket.dart';
import '../../../ticketing/presentation/screens/ticket_qr_screen.dart';

/// Checkout for one chosen journey.
///
/// This is the seam where I1 is enforced on the device. The screen cannot render
/// a QR until [PurchaseController] reports `PurchaseSuccess`, which only happens
/// once the backend has confirmed payment — so no code path here shows a ticket
/// after the passenger merely "finished paying".
class PurchaseFlowScreen extends ConsumerStatefulWidget {
  const PurchaseFlowScreen({
    super.key,
    required this.journey,
    required this.origin,
    required this.destination,
  });

  final PlannedJourney journey;

  /// Carried so the screen can re-plan the same trip after sign-in. An anonymous
  /// plan is not persisted server-side, so buying it requires a fresh quote.
  final Place origin;
  final Place destination;

  @override
  ConsumerState<PurchaseFlowScreen> createState() => _PurchaseFlowScreenState();
}

class _PurchaseFlowScreenState extends ConsumerState<PurchaseFlowScreen> {
  PurchaseState _state = const PurchaseIdle();
  StreamSubscription<PurchaseState>? _sub;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    // The controller is a singleton so its idempotency key survives navigation
    // within a purchase. A *new* purchase must start from a clean key, or the
    // server would replay the previous payment and return the old ticket.
    final controller = ref.read(purchaseControllerProvider)..reset();
    _sub = controller.states.listen((next) {
      if (!mounted) return;
      setState(() => _state = next);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<PurchaseState> _pay(PaymentMethod method) async {
    final journey = widget.journey;

    // Buying requires identity, because the payment and the ticket belong to an
    // account. Rather than failing at the API, send the passenger to sign in
    // first and carry on when they return.
    final signedIn = ref.read(isPassengerSignedInProvider);
    if (!signedIn) {
      final returned = await context.pushNamed<bool>(Routes.passengerSignInName);
      if (returned != true || !mounted) {
        // Cancelled at sign-in: stay put, with no purchase attempted and no
        // idempotency key burned.
        setState(() => _state = const PurchaseFailure(
              ApiFailure.unauthorized,
              message: 'Sign in to buy a ticket',
            ));
        return _state;
      }
    }

    final buyable = journey.journeyId == null ? await _replanSignedIn() : journey;
    if (buyable == null || buyable.journeyId == null) {
      setState(() => _state = const PurchaseFailure(
            ApiFailure.validation,
            message: 'Re-plan this journey to purchase it',
          ));
      return _state;
    }

    final result = await ref.read(purchaseControllerProvider).purchase(
          amount: buyable.totalFare,
          method: method,
          journeyId: buyable.journeyId,
        );

    if (!mounted || _navigated) return result;
    if (result is PurchaseSuccess) {
      _navigated = true;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => TicketQrScreen(ticket: result.ticket),
        ),
      );
    }
    return result;
  }

  /// Re-plans the same journey now that the passenger is signed in, so the
  /// server has a stored fare to check the payment against.
  Future<PlannedJourney?> _replanSignedIn() async {
    try {
      final plan = await ref.read(transportRepositoryProvider).planJourney(
            JourneyPlanRequest(
              origin: widget.origin,
              destination: widget.destination,
              departureTime: DateTime.now(),
            ),
          );
      // The first option with a stored id is the one the server persisted and
      // will verify the payment against.
      for (final option in plan.journeys) {
        if (option.journeyId != null) return option;
      }
      return null;
    } catch (e) {
      return null;
    }
  }


  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final journey = widget.journey;

    return Scaffold(
      appBar: AppBar(title: Text(s.confirm)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          _SummaryCard(journey: journey),
          if (journey.transferDiscountFils > 0) ...[
            const SizedBox(height: AppSpacing.md),
            _DiscountNote(fils: journey.transferDiscountFils),
          ],
          const SizedBox(height: AppSpacing.md),
          _StatusPanel(state: _state),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: PaymentSheet(
            amount: journey.totalFare,
            state: _state,
            onConfirm: _pay,
          ),
        ),
      ),
    );
  }
}
/// Fare and legs recap, so the passenger confirms the same numbers they saw in
/// the results list.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.journey});

  final PlannedJourney journey;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.totalFare, style: theme.textTheme.bodySmall),
            Text(journey.totalFare.display, style: theme.textTheme.headlineMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '${journey.durationLabel} · ${journey.transferCount} ${s.transfers}',
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
            ),
            const Divider(height: AppSpacing.lg),
            for (final leg in journey.legs)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(leg.routeName ?? leg.mode.wire),
                subtitle: Text(
                  '${leg.fromLabel ?? ''} → ${leg.toLabel ?? ''}',
                  style: theme.textTheme.bodySmall,
                ),
                trailing: leg.fare.isZero ? null : Text(leg.fare.display),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the transfer rule waived part of the fare.
///
/// A silent discount reads as an error to a passenger checking their change.
/// Saying what was saved, and why, is the difference between a concession and a
/// bug report.
class _DiscountNote extends StatelessWidget {
  const _DiscountNote({required this.fils});

  final int fils;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.greenLight,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          const Icon(Icons.savings_outlined, color: AppColors.green),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Transfer discount ——— you save ${Money(fils).display}',
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.green),
            ),
          ),
        ],
      ),
    );
  }
}

/// Live status of the purchase, so a passenger is never left guessing whether
/// their money moved.
class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.state});

  final PurchaseState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = AppStringsScope.of(context);

    final parts = _describe(state, s);
    if (parts == null) return const SizedBox.shrink();
    final (icon, message, tone) = parts;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Icon(icon, color: tone),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: tone),
            ),
          ),
          if (state.isBusy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }

  /// Returns null when there is nothing to report (idle).
  ///
  /// Every failure gets a specific message: a declined card, an expired session
  /// and an unreachable network need different advice from the passenger, and
  /// "something went wrong" helps nobody retry correctly.
  (IconData, String, Color)? _describe(PurchaseState state, AppStrings s) =>
      switch (state) {
        PurchaseIdle() => null,
        PurchaseCreatingPayment() => (
            CupertinoIcons.creditcard,
            s.creatingPayment,
            AppColors.inkMuted,
          ),
        PurchaseAwaitingPayment() => (
            CupertinoIcons.clock,
            s.awaitingPayment,
            AppColors.yellowDark,
          ),
        PurchaseAwaitingTicket() => (
            CupertinoIcons.doc_text,
            s.issuingTicket,
            AppColors.yellowDark,
          ),
        // Success navigates away immediately, so this is only seen in the frame
        // before the route changes.
        PurchaseSuccess() => (
            CupertinoIcons.check_mark_circled,
            s.ticketReady,
            AppColors.green,
          ),
        PurchaseFailure(:final failure, :final message) => (
            CupertinoIcons.xmark_circle,
            message ?? _defaultMessage(failure, s),
            AppColors.red,
          ),
      };

  String _defaultMessage(ApiFailure failure, AppStrings s) => switch (failure) {
        ApiFailure.network => s.errorNetwork,
        ApiFailure.unauthorized => s.errorSession,
        ApiFailure.timeout => s.errorTimeout,
        ApiFailure.validation => s.errorReplan,
        _ => s.errorGeneric,
      };
}

/// Horizontal leg indicator: walk → bus → walk.

