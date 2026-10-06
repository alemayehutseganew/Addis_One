import 'package:flutter/material.dart';

import '../../../../../app/theme.dart';
import '../../../../../core/localization.dart';
import '../../../../../core/models/ticket.dart';
import '../../../../../core/money.dart';
import '../../../journey_planner/domain/purchase_state.dart';

/// Payment sheet.
///
/// The pay button is disabled while a purchase is in flight, which prevents a
/// second concurrent attempt — the client-side half of the double-charge
/// defence. The server-side half is the idempotency key the controller carries.
class PaymentSheet extends StatefulWidget {
  const PaymentSheet({
    super.key,
    required this.amount,
    required this.onConfirm,
    required this.state,
  });

  final Money amount;

  /// Invoked with the chosen method; returns the terminal state.
  final Future<PurchaseState> Function(PaymentMethod) onConfirm;

  final PurchaseState state;

  @override
  State<PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<PaymentSheet> {
  PaymentMethod _method = PaymentMethod.telebirr;

  /// Always returns a handler. While a purchase is in flight it is a no-op,
  /// which disables the radio group without needing a nullable callback
  /// (`RadioGroup.onChanged` is non-nullable).
  ValueChanged<PaymentMethod?> _onMethodChanged(bool busy) {
    return (value) {
      if (busy || value == null) return;
      setState(() => _method = value);
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStringsScope.of(context);
    final theme = Theme.of(context);
    final busy = widget.state.isBusy;

    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        top: AppSpacing.md,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.totalFare, style: theme.textTheme.bodySmall),
          Text(widget.amount.display, style: theme.textTheme.headlineMedium),
          const SizedBox(height: AppSpacing.lg),
          RadioGroup<PaymentMethod>(
            groupValue: _method,
            // Locked mid-flight: changing provider after a payment has started
            // is how a passenger ends up paying twice.
            onChanged: _onMethodChanged(busy),
            child: IgnorePointer(
              ignoring: busy,
              child: Opacity(
                opacity: busy ? 0.5 : 1,
                child: Column(
                  children: [
                    for (final method in PaymentMethod.values)
                      RadioListTile<PaymentMethod>(
                        value: method,
                        title: Text(method.label),
                        contentPadding: EdgeInsets.zero,
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: AppSpacing.sm),
            Text(s.paymentProcessing, style: theme.textTheme.bodySmall),
            const SizedBox(height: AppSpacing.sm),
          ],
          FilledButton(
            onPressed: busy ? null : () => widget.onConfirm(_method),
            child: Text('${s.pay} ${widget.amount.plain} ETB'),
          ),
        ],
      ),
    );
  }
}
