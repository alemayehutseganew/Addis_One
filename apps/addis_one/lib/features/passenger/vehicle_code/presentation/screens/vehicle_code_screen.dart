import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../app/providers.dart';
import '../../../../../app/router.dart';
import '../../../../../app/theme.dart';
import '../../../../../core/localization.dart';
import '../../../../../core/models/journey.dart';
import '../../../../../core/models/ticket.dart';
import '../../../../../core/models/vehicle.dart';
import '../../../journey_planner/domain/transport_repository.dart';
import '../../domain/vehicle_code_controller.dart';
import '../../domain/vehicle_code_state.dart';

/// The "enter a vehicle code" boarding flow — steps 1 to 9.
///
/// This screen cannot render a QR. It ends the moment
/// [VehicleTicketIssued] arrives and hands off to the ticket route; and it can
/// only arrive there after the backend confirmed a payment, because
/// `VehicleCodeController` is what produces that state. A found vehicle, a
/// completed redirect, or an optimistic "paid" flag cannot reach step 10 from
/// here — I1 is enforced by the state union rather than by this widget.
class VehicleCodeScreen extends ConsumerStatefulWidget {
  const VehicleCodeScreen({super.key});

  @override
  ConsumerState<VehicleCodeScreen> createState() => _VehicleCodeScreenState();
}

class _VehicleCodeScreenState extends ConsumerState<VehicleCodeScreen> {
  final _codeController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  VehicleCodeState _state = const VehicleCodeIdle();
  PaymentMethod _method = PaymentMethod.telebirr;

  /// How many fares this purchase covers.
  ///
  /// One passenger paying for friends or family buys N tickets in a single
  /// payment and forwards them individually. No names are collected — the QR is
  /// the whole ticket, which is what makes anonymous forwarding safe.
  int _quantity = 1;

  /// A group booking is capped so a mistyped tap cannot buy forty fares in one
  /// go. A minibus party is the realistic upper end; a Shaare-Express full of
  /// forty would be arranged differently.
  static const int _maxQuantity = 12;

  /// The vehicle resolved by the last successful lookup.
  ///
  /// Held here rather than read back out of [_state] so that a payment failure —
  /// which is a different state — can still offer Retry against the vehicle the
  /// passenger already found, without re-running the lookup.
  VehicleProfile? _vehicle;

  @override
  void initState() {
    super.initState();
    // A previous visit may have left a half-finished purchase holding an
    // idempotency key. Starting clean is what makes this a NEW purchase rather
    // than a replay of the last one.
    ref.read(vehicleCodeControllerProvider).reset();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  VehicleCodeController get _controller =>
      ref.read(vehicleCodeControllerProvider);

  /// Steps 1–3.
  Future<void> _lookup() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    // Ask for a position first, so the server can quote a distance fare rather
    // than a flat one. Never fatal: if the fix is refused or too coarse the
    // lookup still runs with a null point and prices flat, which is the correct
    // outcome for a passenger who cannot or will not share their location.
    final point = await _boardingPoint();

    final next = await _controller.lookup(
      _codeController.text,
      boardingPoint: point,
    );
    if (!mounted) return;

    setState(() {
      _state = next;
      // Keep the vehicle only when the lookup confirmed one. A not-found or a
      // failure must clear it, or a later Retry would pay for the *previous*
      // vehicle — a charge for a bus the passenger is no longer at.
      if (next is VehicleFound) _vehicle = next.vehicle;
    });
  }

  /// Best-effort position for the boarding quote.
  ///
  /// Returns null in every failure case rather than surfacing an error: the
  /// passenger is standing at a vehicle and has already typed its code, and a
  /// location prompt that blocks the purchase would be worse than a flat fare.
  Future<GeoPoint?> _boardingPoint() async {
    final result = await ref.read(locationServiceProvider).currentPosition();
    if (!result.isSuccess) return null;

    // The same threshold the "current location" field uses. A fix accurate only
    // to hundreds of metres could snap to the wrong stop, and a confidently
    // wrong distance fare is worse than an honest flat one.
    if (!result.isAccurateEnough) return null;

    return result.point;
  }

  /// Steps 5–9.
  Future<void> _pay() async {
    final vehicle = _vehicle;
    if (vehicle == null || !vehicle.isPurchasable) return;

    final next = await _controller.pay(
      vehicle: vehicle,
      method: _method,
      quantity: _quantity,
      onRedirect: _onRedirect,
    );
    if (!mounted) return;

    setState(() => _state = next);

    // Steps 10–13 hand off to the ticket screen. `push` rather than `replace`:
    // Back from the ticket should land here, where the passenger can see the
    // completed purchase rather than being dumped on an unrelated screen.
    if (next is VehicleTicketsIssued) {
      await context.pushNamed(
        Routes.vehicleTicketName,
        extra: VehicleTicketArgs(
          tickets: next.tickets,
          vehicle: vehicle,
          quantityPaid: next.quantityPaid,
        ),
      );
    }
  }

  /// Provider redirect.
  ///
  /// Resolves as soon as the passenger returns from the provider, which is NOT
  /// payment — polling decides that. Without `url_launcher` the app cannot open
  /// the provider's page itself, so the passenger is told what is happening and
  /// the flow keeps waiting on the backend.
  Future<void> _onRedirect(String url) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '${AppStringsScope.of(context).paymentPending}\n$url',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
  }

  /// Backs the flow all the way out. The idempotency key is discarded, so the
  /// next vehicle is a new purchase.
  void _reset() {
    _controller.reset();
    _codeController.clear();
    setState(() {
      _state = const VehicleCodeIdle();
      _vehicle = null;
      _quantity = 1;
    });
  }

  /// Backs out of a payment without clearing the lookup, so the passenger can
  /// pick another payment method against the same vehicle.
  void _backToVehicle() {
    final vehicle = _vehicle;
    _controller.reset();
    setState(() {
      _state = vehicle == null ? const VehicleCodeIdle() : VehicleFound(vehicle);
    });
  }
@override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.vehicleCodeTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: switch (_state) {
            // Steps 4–7: the vehicle is known. Confirm and pay.
            VehicleFound(:final vehicle) => _VehicleFoundView(
                vehicle: vehicle,
                quantity: _quantity,
                maxQuantity: _maxQuantity,
                onQuantityChanged: (value) => setState(() => _quantity = value),
                method: _method,
                state: _state,
                onMethodChanged: (m) => setState(() => _method = m),
                onConfirm: _pay,
                onCancel: _reset,
              ),

            // Step 3, NO branch. Terminal.
            VehicleNotFound(:final code) => _VehicleNotFoundView(
                code: code,
                onRetype: _reset,
              ),

            // Known vehicle, not selling tickets.
            VehicleUnavailable(:final vehicle, :final reason) =>
              _VehicleUnavailableView(
                vehicle: vehicle,
                reason: reason,
                onTryAnother: _reset,
              ),

            // Steps 8–9 in progress.
            VehiclePaying() || VehicleAwaitingTicket() => _PaymentProgressView(
                state: _state,
                onCancel: _backToVehicle,
              ),

            // Step 9, NO branch.
            VehiclePaymentFailed(
              :final failure,
              :final message,
              :final vehicle,
            ) =>
              _PaymentFailedView(
                failure: failure,
                message: message,
                vehicle: vehicle ?? _vehicle,
                onRetry: _pay,
                onCancel: _backToVehicle,
              ),

            // Step 2, request in flight.
            VehicleLookingUp(:final code) => _VehicleCodeForm(
                formKey: _formKey,
                controller: _codeController,
                s: s,
                busy: true,
                submittingCode: code,
                onSubmit: _lookup,
              ),

            // Step 2 failed.
            VehicleLookupFailure(:final failure, :final message) =>
              _VehicleCodeForm(
                formKey: _formKey,
                controller: _codeController,
                s: s,
                busy: false,
                error: _failureMessage(failure, message, s),
                onSubmit: _lookup,
              ),

            // Step 1.
            VehicleCodeIdle() => _VehicleCodeForm(
                formKey: _formKey,
                controller: _codeController,
                s: s,
                busy: false,
                onSubmit: _lookup,
              ),

            // Reached only after a confirmed payment. [_pay] normally
            // navigates away before this frame renders; the case exists so the
            // switch is total and a ticket can never fall through to the code
            // form, which would let a passenger re-search and pay a second time
            // for a ticket they already hold.
            VehicleTicketsIssued() => const SizedBox.shrink(),
          },
        ),
      ),
    );
  }

  /// Maps a failure onto advice the passenger can act on.
  ///
  /// A single "something went wrong" would leave someone at a vehicle unable to
  /// tell whether to retype the code, wait for signal, or sign in again.
  String _failureMessage(ApiFailure failure, String? message, AppStrings s) {
    return switch (failure) {
      ApiFailure.network => s.errorNetwork,
      ApiFailure.unauthorized => s.errorSession,
      ApiFailure.timeout => s.errorTimeout,
      ApiFailure.validation => message ?? s.errorGeneric,
      ApiFailure.notFound => s.vehicleNotFound,
      _ => message ?? s.errorGeneric,
    };
  }
}
/// Step 1–2: the code entry form.
class _VehicleCodeForm extends StatelessWidget {
  const _VehicleCodeForm({
    required this.formKey,
    required this.controller,
    required this.s,
    required this.busy,
    required this.onSubmit,
    this.submittingCode,
    this.error,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController controller;
  final AppStrings s;
  final bool busy;
  final VoidCallback onSubmit;

  /// The code being looked up, shown while the request is in flight.
  final String? submittingCode;

  /// Lookup error to display above the field.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(s.vehicleCodeHelp, style: theme.textTheme.bodyMedium),
          const SizedBox(height: AppSpacing.lg),
          TextFormField(
            controller: controller,
            enabled: !busy,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.search,
            // Codes carry a space and digits; the default keyboard fights both,
            // and a passenger boarding a bus should not have to hunt for a
            // symbol key to type the code printed beside them.
            keyboardType: TextInputType.visiblePassword,
            inputFormatters: [
              // Uppercased as typed, so the field always shows exactly what
              // will be searched for.
              TextInputFormatter.withFunction(
                (_, next) => next.copyWith(text: next.text.toUpperCase()),
              ),
              LengthLimitingTextInputFormatter(16),
            ],
            style: theme.textTheme.headlineSmall,
            decoration: InputDecoration(
              labelText: s.vehicleCode,
              hintText: s.vehicleCodeHint,
              prefixIcon: const Icon(Icons.directions_bus_outlined),
            ),
            validator: (value) =>
                (value == null || value.trim().isEmpty) ? s.vehicleCode : null,
            onFieldSubmitted: (_) => busy ? null : onSubmit(),
          ),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.md),
            _Banner(
              icon: Icons.error_outline,
              message: error!,
              color: AppColors.red,
            ),
          ],
          if (busy) ...[
            const SizedBox(height: AppSpacing.lg),
            const LinearProgressIndicator(),
            const SizedBox(height: AppSpacing.sm),
            Text(
              submittingCode == null
                  ? s.searchingVehicle
                  : '${s.searchingVehicle} ($submittingCode)',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          FilledButton(
            onPressed: busy ? null : onSubmit,
            child: Text(s.searchVehicle),
          ),
        ],
      ),
    );
  }
}
/// Steps 4–7: vehicle details, then the payment section.
///
/// The fare is displayed before any payment control, and the pay button repeats
/// it. A passenger authorising a charge must be able to see the amount at the
/// moment they authorise it, not one screen earlier.
class _VehicleFoundView extends StatelessWidget {
  const _VehicleFoundView({
    required this.vehicle,
    required this.quantity,
    required this.maxQuantity,
    required this.onQuantityChanged,
    required this.method,
    required this.state,
    required this.onMethodChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  final VehicleProfile vehicle;
  final int quantity;
  final int maxQuantity;
  final ValueChanged<int> onQuantityChanged;
  final PaymentMethod method;
  final VehicleCodeState state;
  final ValueChanged<PaymentMethod> onMethodChanged;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final theme = Theme.of(context);
    final amharic = s.isAmharic;
    final busy = state.isBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Step 4 — vehicle information.
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.directions_bus, color: AppColors.green),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        vehicle.routeLabelFor(amharic),
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                _DetailRow(label: s.vehicleCode, value: vehicle.code),
                const Divider(height: AppSpacing.lg),
                _DetailRow(
                  label: s.operator,
                  value: vehicle.operatorNameFor(amharic),
                ),
                if (vehicle.plateNumber != null) ...[
                  const Divider(height: AppSpacing.lg),
                  _DetailRow(label: s.plateNumber, value: vehicle.plateNumber!),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),

        // Steps 4–5 — the fare being authorised, and how many of them.
        //
        // The per-ticket fare and the TOTAL are both shown, never just the
        // total. A passenger paying for four must be able to check the
        // per-head price and the arithmetic; showing only "60.00" leaves them
        // unable to tell whether the multiplier was applied correctly.
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(s.fare, style: theme.textTheme.bodyMedium),
                    Text(
                      '${vehicle.fare.display} ${s.ticketEach}',
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ),
                // Why this fare and not the advertised flat one. A price the
                // passenger cannot account for is a price they will dispute at
                // the door, so the stop and the distance are always shown.
                if (vehicle.isDistanceBased)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.straighten_rounded,
                          size: 14,
                          color: AppColors.inkMuted,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Expanded(
                          child: Text(
                            vehicle.fareBasisFor(s.isAmharic),
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: AppColors.inkMuted),
                          ),
                        ),
                      ],
                    ),
                  ),
                const Divider(height: AppSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(s.numberOfTickets, style: theme.textTheme.bodyMedium),
                    _QuantityStepper(
                      value: quantity,
                      max: maxQuantity,
                      enabled: !busy,
                      onChanged: onQuantityChanged,
                    ),
                  ],
                ),
                const Divider(height: AppSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(s.total, style: theme.textTheme.titleMedium),
                    Text(
                      // Exact integer arithmetic — never a float, so the total
                      // on screen is the total the server will re-derive.
                      (vehicle.fare * quantity).display,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        // Says plainly that no identity is attached. Someone paying for family
        // will expect to be asked who they are; stating it up front prevents
        // the question, and makes the anonymity a feature rather than a
        // disappointment.
        Text(
          s.noNamesNeeded,
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.lg),

        // Steps 6–7 — payment section.
        Text(s.paymentFor, style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        RadioGroup<PaymentMethod>(
          groupValue: method,
          // Always returns a handler: while busy it is a no-op, which locks the
          // radio group without needing a nullable callback.
          onChanged: (value) {
            if (busy || value == null) return;
            onMethodChanged(value);
          },
          child: Column(
            children: [
              for (final option in PaymentMethod.values)
                RadioListTile<PaymentMethod>(
                  value: option,
                  title: Text(_methodLabel(option, amharic)),
                  contentPadding: EdgeInsets.zero,
                  // Locked mid-flight: switching provider after a payment has
                  // started is how a passenger ends up paying twice.
                  enabled: !busy,
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (busy) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: AppSpacing.sm),
          Text(
            s.paymentProcessing,
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        // Step 5 confirmed — steps 6–9 begin on tap.
        FilledButton(
          onPressed: busy ? null : onConfirm,
          child: Text(
            '${s.payForTickets} · ${(vehicle.fare * quantity).display}',
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton(
          onPressed: busy ? null : onCancel,
          child: Text(s.cancel),
        ),
      ],
    );
  }

  /// Provider names in the passenger's language.
  ///
  /// Telebirr, CBE Birr and USSD are brand names and are not translated; the
  /// generic providers are, so the list reads naturally in Amharic.
  static String _methodLabel(PaymentMethod method, bool amharic) {
    return switch (method) {
      PaymentMethod.telebirr => amharic ? 'ቴሌበር' : 'Telebirr',
      PaymentMethod.cbeBirr => amharic ? 'ሲቢኢ ብር' : 'CBE Birr',
      PaymentMethod.bank => amharic ? 'ባንክ / ካርድ' : 'Bank / Card',
      PaymentMethod.wallet => amharic ? 'የሌላ አገልጋጭ' : 'Other approved provider',
    };
  }
}
/// Step 3, NO branch: "Vehicle Not Found" — STOP.
///
/// Terminal for this code. The only way forward is a different one, so the
/// button returns to the form rather than re-running the identical search, which
/// would return the identical result and look like the app is stuck.
class _VehicleNotFoundView extends StatelessWidget {
  const _VehicleNotFoundView({required this.code, required this.onRetype});

  final String code;
  final VoidCallback onRetype;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);

    return _TerminalState(
      icon: Icons.search_off,
      iconColor: AppColors.red,
      title: s.vehicleNotFound,
      detail: s.vehicleNotFoundDetail,
      code: code,
      actionLabel: s.checkCodeAndRetry,
      onAction: onRetype,
    );
  }
}

/// The vehicle is registered but is not selling tickets right now.
///
/// Kept visually distinct from "Not Found": the code was correct, and telling
/// the passenger to re-check it would be sending them to fix something that is
/// not broken.
class _VehicleUnavailableView extends StatelessWidget {
  const _VehicleUnavailableView({
    required this.vehicle,
    required this.onTryAnother,
    this.reason,
  });

  final VehicleProfile vehicle;
  final String? reason;
  final VoidCallback onTryAnother;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);

    final retired = vehicle.status == VehicleStatus.retired;
    final text = retired ? s.vehicleRetired : s.vehicleUnavailable;

    return _TerminalState(
      icon: Icons.do_not_disturb_on_outlined,
      iconColor: AppColors.yellowDark,
      title: text,
      detail: reason ?? text,
      code: vehicle.code,
      actionLabel: s.tryAgain,
      onAction: onTryAnother,
    );
  }
}

/// Steps 8–9 while the payment is in flight.
///
/// Each state names what the system is doing rather than "please wait". Someone
/// standing at a vehicle who has just handed over money needs to know their fare
/// is still being processed, not lost.
class _PaymentProgressView extends StatelessWidget {
  const _PaymentProgressView({required this.state, required this.onCancel});

  final VehicleCodeState state;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final theme = Theme.of(context);

    final message = switch (state) {
      VehiclePaying(:final redirectUrl) =>
        redirectUrl == null ? s.awaitingPayment : s.paymentPending,
      VehicleAwaitingTicket() => s.issuingTicket,
      _ => s.paymentProcessing,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.xl),
        const Center(
          child: SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(message, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.sm),
        Text(
          s.doNotCloseApp,
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        if (state case VehiclePaying(:final reference)) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            'Ref: $reference',
            style: theme.textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        OutlinedButton(onPressed: onCancel, child: Text(s.cancelPayment)),
      ],
    );
  }
}
/// Step 9, NO branch: payment failed — Retry or Cancel.
///
/// "No money was taken" is stated explicitly. Without it a passenger who sees a
/// failure after a delay assumes they have been charged and either does not
/// retry or retries in a panic — and a fare is not worth that uncertainty at a
/// bus stop.
class _PaymentFailedView extends StatelessWidget {
  const _PaymentFailedView({
    required this.failure,
    required this.message,
    required this.onRetry,
    required this.onCancel,
    this.vehicle,
  });

  final ApiFailure failure;
  final String? message;
  final VehicleProfile? vehicle;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final theme = Theme.of(context);

    // Retry is offered only when a retry can plausibly succeed. A declined card
    // or a rejected validation will fail identically forever, so a Retry button
    // there would invite another attempt at a payment that was never going to
    // work — or, worse, read as though the first one might have gone through.
    final retryable = failure.isRetryable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.lg),
        const Icon(Icons.error_outline, size: 48, color: AppColors.red),
        const SizedBox(height: AppSpacing.md),
        Text(
          s.paymentDidNotSucceed,
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          message ?? _defaultMessage(failure, s),
          style: theme.textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          s.paymentFailedNoMoney,
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.green),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xl),

        // Retry reuses the SAME idempotency key, so a second attempt cannot
        // become a second charge (I2).
        if (retryable) ...[
          FilledButton(onPressed: onRetry, child: Text(s.retry)),
          const SizedBox(height: AppSpacing.sm),
        ],
        OutlinedButton(onPressed: onCancel, child: Text(s.cancel)),
      ],
    );
  }

  String _defaultMessage(ApiFailure failure, AppStrings s) => switch (failure) {
        ApiFailure.network => s.errorNetwork,
        ApiFailure.unauthorized => s.errorSession,
        ApiFailure.timeout => s.errorTimeout,
        _ => s.errorGeneric,
      };
}

/// Shared shape for a step that stops the flow.
///
/// One widget so "not found", "not taking passengers" and "retired" cannot drift
/// into looking like three unrelated screens — they are the same outcome with
/// different causes, and a passenger who sees one should immediately recognise
/// the other two.
class _TerminalState extends StatelessWidget {
  const _TerminalState({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.detail,
    required this.actionLabel,
    required this.onAction,
    this.code,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String detail;
  final String? code;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.xl),
        Center(child: Icon(icon, size: 48, color: iconColor)),
        const SizedBox(height: AppSpacing.md),
        Text(title, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
        if (code != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(code!, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
        ],
        const SizedBox(height: AppSpacing.md),
        Text(detail, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.xl),
        FilledButton(onPressed: onAction, child: Text(actionLabel)),
      ],
    );
  }
}
/// Ticket-count selector for a group booking.
///
/// Minus/plus rather than a free-text field on purpose. A keypad invites typos,
/// and a typo here multiplies a fare — "40" instead of "4" is a ten-fold error
/// committed with one mistyped digit. Buttons can only move one step at a time.
class _QuantityStepper extends StatelessWidget {
  const _QuantityStepper({
    required this.value,
    required this.max,
    required this.enabled,
    required this.onChanged,
  });

  final int value;
  final int max;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: enabled && value > 1 ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove_circle_outline),
          visualDensity: VisualDensity.compact,
          tooltip: 'Remove one ticket',
        ),
        SizedBox(
          width: 40,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        IconButton(
          onPressed: enabled && value < max ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add_circle_outline),
          visualDensity: VisualDensity.compact,
          tooltip: 'Add one ticket',
        ),
      ],
    );
  }
}

/// Label/value row for the vehicle detail card.
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            value,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}

/// Inline status strip.
class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.message,
    required this.color,
  });

  final IconData icon;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}