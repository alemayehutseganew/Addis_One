import 'package:flutter/material.dart';

import '../../../../../core/network/api_failure.dart';

/// Full-screen message for a state that is not a list.
///
/// One widget for every screen so that "the server refused", "there is no signal"
/// and "nothing to show yet" all read the same way. An officer learns three
/// failure shapes by seeing them side by side, and a screen that invents its own
/// wording for each teaches them nothing.
class MessagePane extends StatelessWidget {
  const MessagePane({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.onRetry,
    this.retryLabel = 'Try again',
  });

  /// Builds the pane for a thrown error.
  ///
  /// A 403 is singled out because it means the server refused this specific
  /// request, which is very different from a fault: the honest message is that
  /// this account may not do this, not "something went wrong". Telling an
  /// officer to retry a refusal would be advice that cannot possibly work.
  factory MessagePane.forError(Object error, {VoidCallback? onRetry}) {
    if (error is ApiException) {
      final refused = error.failure == ApiFailure.unauthorized;
      return MessagePane(
        icon: refused
            ? Icons.block
            : error.failure == ApiFailure.network
                ? Icons.cloud_off
                : Icons.error_outline,
        title: refused
            ? 'Not permitted for your role'
            : error.failure == ApiFailure.network
                ? 'No connection'
                : 'Could not load',
        detail: error.message ??
            (refused
                ? 'The server refused this action for your account.'
                : 'Try again shortly.'),
        onRetry: refused ? null : onRetry,
      );
    }
    return MessagePane(
      icon: Icons.error_outline,
      title: 'Could not load',
      detail: 'Something went wrong. Try again shortly.',
      onRetry: onRetry,
    );
  }

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 44, color: theme.colorScheme.outline),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (detail != null) ...[
              const SizedBox(height: 6),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              OutlinedButton(onPressed: onRetry, child: Text(retryLabel)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The empty state for a list that loaded successfully but has nothing in it.
///
/// Distinct from [MessagePane] on purpose: "you have no complaints" is a normal
/// answer and should not be dressed up as a problem.
class EmptyPane extends StatelessWidget {
  const EmptyPane({super.key, required this.title, this.detail});

  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox_outlined, size: 44, color: theme.colorScheme.outline),
            const SizedBox(height: 14),
            Text(title, style: theme.textTheme.titleMedium),
            if (detail != null) ...[
              const SizedBox(height: 6),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}